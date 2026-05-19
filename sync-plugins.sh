#!/usr/bin/env bash
# Claude Code 插件同步脚本
# 用法:
#   安装: ./sync-plugins.sh
#   导出: ./sync-plugins.sh export  (将当前机器的插件列表写入 plugin-manifest.json)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$SCRIPT_DIR/plugin-manifest.json"
CLAUDE_DIR="${HOME}/.claude"
PLUGINS_DIR="${CLAUDE_DIR}/plugins"
MARKETPLACES_DIR="${PLUGINS_DIR}/marketplaces"
CACHE_DIR="${PLUGINS_DIR}/cache"

do_export() {
  python3 << 'PYTHON'
import json, os, sys

plugins_dir = os.path.expanduser('~/.claude/plugins')
known_path = os.path.join(plugins_dir, 'known_marketplaces.json')
installed_path = os.path.join(plugins_dir, 'installed_plugins.json')

for p in [known_path, installed_path]:
    if not os.path.isfile(p):
        print(f'\033[31m错误: 未找到 {p}\033[0m', file=sys.stderr)
        sys.exit(1)

with open(known_path) as f:
    known = json.load(f)
with open(installed_path) as f:
    installed = json.load(f)

marketplaces = {}
for name, info in known.items():
    source = info.get('source', {})
    if source.get('source') == 'github':
        marketplaces[name] = source['repo']

seen = set()
plugins = []
for key, entries in installed.get('plugins', {}).items():
    if key in seen:
        continue
    seen.add(key)
    plugin_name, marketplace = key.split('@', 1)
    entry = entries[0]
    plugins.append({
        'name': plugin_name,
        'marketplace': marketplace,
        'version': entry.get('version', 'unknown'),
        'scope': entry.get('scope', 'user'),
    })

manifest = {'version': 1, 'marketplaces': marketplaces, 'plugins': plugins}
script_dir = os.path.dirname(os.path.abspath(sys.argv[0])) if sys.argv[0] else '.'
out = os.environ.get('MANIFEST_PATH', os.path.join(os.getcwd(), 'plugin-manifest.json'))
with open(out, 'w') as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
print(f'\033[32m✓\033[0m 已导出 \033[1m{len(plugins)}\033[0m 个插件到 {out}')
PYTHON
}

do_install() {
  if [ ! -f "$MANIFEST" ]; then
    echo -e "\033[31m错误: 未找到 plugin-manifest.json\033[0m" >&2
    exit 1
  fi

  mkdir -p "$MARKETPLACES_DIR" "$CACHE_DIR"

  python3 << 'PYTHON'
import json, os, shutil, subprocess, sys
from datetime import datetime, timezone

# --- 颜色定义 ---
GREEN = '\033[32m'
RED = '\033[31m'
YELLOW = '\033[33m'
CYAN = '\033[36m'
BOLD = '\033[1m'
DIM = '\033[2m'
RESET = '\033[0m'

def ok(msg):
    print(f'  {GREEN}✓{RESET} {msg}')

def warn(msg):
    print(f'  {YELLOW}⚠{RESET} {msg}')

def fail(msg):
    print(f'  {RED}✗{RESET} {msg}')

def info(msg):
    print(f'  {CYAN}→{RESET} {msg}')

def header(msg):
    print(f'\n{BOLD}{msg}{RESET}')

# --- 加载 manifest ---
home = os.path.expanduser('~')
plugins_dir = os.path.join(home, '.claude/plugins')
marketplaces_dir = os.path.join(plugins_dir, 'marketplaces')
cache_dir = os.path.join(plugins_dir, 'cache')
manifest_path = os.path.join(os.environ.get('MANIFEST_PATH', os.path.join(os.getcwd(), 'plugin-manifest.json')))

with open(manifest_path) as f:
    manifest = json.load(f)

now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')
marketplaces = manifest['marketplaces']
plugins = manifest['plugins']

# --- 1. 克隆/更新 marketplaces ---
header('1. 同步 Marketplaces')
for name, repo in marketplaces.items():
    dest = os.path.join(marketplaces_dir, name)
    if os.path.isdir(dest):
        ok(f'{name} {DIM}(pull){RESET}')
        subprocess.run(['git', '-C', dest, 'pull', '--ff-only'], capture_output=True)
    else:
        info(f'克隆 {BOLD}{repo}{RESET} ...')
        ret = subprocess.run(['git', 'clone', '--depth=1', f'https://github.com/{repo}.git', dest],
                             capture_output=True, text=True)
        if ret.returncode == 0:
            ok(name)
        else:
            fail(f'{name}: {ret.stderr.strip()}')

# --- 1.5 确保每个 marketplace 都有 marketplace.json ---
for name in marketplaces:
    dest = os.path.join(marketplaces_dir, name)
    mj = os.path.join(dest, '.claude-plugin', 'marketplace.json')
    pj = os.path.join(dest, '.claude-plugin', 'plugin.json')
    if os.path.isdir(dest) and not os.path.isfile(mj) and os.path.isfile(pj):
        with open(pj) as f:
            meta = json.load(f)
        plugin_name = meta.get('name', name)
        mkt_data = {
            'name': name,
            'plugins': [{
                'name': plugin_name,
                'source': './',
                'description': f'Auto-generated marketplace entry for {plugin_name}'
            }]
        }
        os.makedirs(os.path.dirname(mj), exist_ok=True)
        with open(mj, 'w') as f:
            json.dump(mkt_data, f, indent=2)
        ok(f'{name} {DIM}(补充 marketplace.json){RESET}')

# --- 2. 生成 known_marketplaces.json ---
header('2. 生成 known_marketplaces.json')
known = {}
for name, repo in marketplaces.items():
    path = os.path.join(marketplaces_dir, name)
    if os.path.isdir(path):
        known[name] = {
            'source': {'source': 'github', 'repo': repo},
            'installLocation': path,
            'lastUpdated': now,
        }
with open(os.path.join(plugins_dir, 'known_marketplaces.json'), 'w') as f:
    json.dump(known, f, indent=2)
ok(f'{len(known)} 个 marketplace')

# --- 3. 安装插件到 cache ---
header('3. 安装插件')

def find_plugin_source(plugin_name, marketplace):
    """在 marketplace 目录中搜索插件源码，支持多种目录结构"""
    mp_dir = os.path.join(marketplaces_dir, marketplace)
    if not os.path.isdir(mp_dir):
        return None

    # 情况 A: marketplace 本身就是单插件仓库
    pj = os.path.join(mp_dir, '.claude-plugin', 'plugin.json')
    if os.path.isfile(pj):
        with open(pj) as f:
            meta = json.load(f)
        if meta.get('name') == plugin_name:
            return mp_dir

    # 情况 B: 在多个常见子目录中查找
    for sub in ('plugins', 'external_plugins', 'packages'):
        candidate = os.path.join(mp_dir, sub, plugin_name)
        if os.path.isdir(candidate):
            return candidate

    # 情况 C: marketplace.json 中声明 - 本地路径或外部 git 仓库
    mj = os.path.join(mp_dir, '.claude-plugin', 'marketplace.json')
    if os.path.isfile(mj):
        with open(mj) as f:
            mkt = json.load(f)
        for p in mkt.get('plugins', []):
            if p.get('name') == plugin_name:
                # 有本地 path 的情况
                if 'path' in p:
                    found = os.path.join(mp_dir, p['path'])
                    if os.path.isdir(found):
                        return found
                # 外部 git source 的情况 (如 superpowers)
                source = p.get('source', {})
                if source.get('source') == 'url' and source.get('url'):
                    url = source['url']
                    sha = source.get('sha', '')
                    clone_dest = os.path.join(cache_dir, marketplace, plugin_name, '__src')
                    if not os.path.isdir(clone_dest):
                        info(f'克隆外部插件 {BOLD}{plugin_name}{RESET} ...')
                        ret = subprocess.run(
                            ['git', 'clone', '--depth=1', url, clone_dest],
                            capture_output=True, text=True)
                        if ret.returncode != 0:
                            return None
                        if sha:
                            subprocess.run(
                                ['git', '-C', clone_dest, 'fetch', '--depth=1', 'origin', sha],
                                capture_output=True)
                            subprocess.run(
                                ['git', '-C', clone_dest, 'checkout', sha],
                                capture_output=True)
                    return clone_dest

    # 情况 D: 递归搜索 .claude-plugin/plugin.json
    for root, dirs, files in os.walk(mp_dir):
        pj_path = os.path.join(root, '.claude-plugin', 'plugin.json')
        if os.path.isfile(pj_path):
            try:
                with open(pj_path) as f:
                    meta = json.load(f)
                if meta.get('name') == plugin_name:
                    return root
            except Exception:
                pass
        dirs[:] = [d for d in dirs if d not in ('.git', 'node_modules', '__pycache__')]

    return None

def copy_plugin(src, dest):
    """复制插件目录，跳过 .git"""
    os.makedirs(dest, exist_ok=True)
    for item in os.scandir(src):
        if item.name == '.git':
            continue
        d = os.path.join(dest, item.name)
        if item.is_dir(follow_symlinks=False):
            shutil.copytree(item.path, d, dirs_exist_ok=True,
                           ignore=shutil.ignore_patterns('.git'))
        else:
            shutil.copy2(item.path, d)

installed_plugins = {}
failed = []

for p in plugins:
    name, marketplace = p['name'], p['marketplace']
    version = p.get('version', 'unknown')

    src = find_plugin_source(name, marketplace)
    if not src:
        warn(f'{name} {DIM}({marketplace}) 未找到源码{RESET}')
        failed.append(name)
        continue

    dest = os.path.join(cache_dir, marketplace, name, version)
    try:
        copy_plugin(src, dest)
    except Exception as e:
        fail(f'{name}: {e}')
        failed.append(name)
        continue

    sha = ''
    try:
        sha = subprocess.check_output(
            ['git', 'rev-parse', 'HEAD'],
            cwd=src if os.path.isdir(os.path.join(src, '.git')) else os.path.join(marketplaces_dir, marketplace),
            stderr=subprocess.DEVNULL
        ).decode().strip()
    except Exception:
        pass

    key = f'{name}@{marketplace}'
    entry = {
        'scope': p.get('scope', 'user'),
        'installPath': dest,
        'version': version,
        'installedAt': now,
        'lastUpdated': now,
    }
    if sha:
        entry['gitCommitSha'] = sha
    installed_plugins[key] = [entry]
    ok(name)

# --- 4. 生成 installed_plugins.json ---
header('4. 生成 installed_plugins.json')
with open(os.path.join(plugins_dir, 'installed_plugins.json'), 'w') as f:
    json.dump({'version': 2, 'plugins': installed_plugins}, f, indent=2)
ok(f'{len(installed_plugins)} 个插件已注册')

# --- 汇总 ---
print()
if failed:
    msg = ', '.join(failed)
    print(f'{YELLOW}⚠ {len(failed)} 个插件未能安装: {msg}{RESET}')
    print()
print(f'{GREEN}{BOLD}完成！{RESET}请在 Claude Code 中运行 {BOLD}/reload-plugins{RESET}')
PYTHON
}

case "${1:-install}" in
  export)
    export MANIFEST_PATH="$MANIFEST"
    do_export
    ;;
  install|"")
    export MANIFEST_PATH="$MANIFEST"
    do_install
    ;;
  *)
    echo "用法: $0 [install|export]"
    exit 1
    ;;
esac
