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
  export MANIFEST_PATH="$MANIFEST"
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

# 区分真正的 marketplace 和单插件仓库
# 真正的 marketplace: 目录内含 .claude-plugin/marketplace.json
marketplaces_dir = os.path.join(plugins_dir, 'marketplaces')
real_marketplaces = {}
for name, info in known.items():
    source = info.get('source', {})
    if source.get('source') == 'github':
        mp_dir = info.get('installLocation', '')
        mj = os.path.join(mp_dir, '.claude-plugin', 'marketplace.json')
        if os.path.isfile(mj):
            real_marketplaces[name] = source['repo']

seen = set()
plugins = []
for key, entries in installed.get('plugins', {}).items():
    if key in seen:
        continue
    seen.add(key)
    plugin_name, marketplace = key.split('@', 1)
    entry = entries[0]

    # 判断插件来源: 是否来自真正的 marketplace，还是独立 git 仓库
    git_url = ''
    if marketplace not in real_marketplaces:
        # 非 marketplace 的插件 - 从 known_marketplaces 获取 git repo
        if marketplace in known:
            repo = known[marketplace].get('source', {}).get('repo', '')
            if repo:
                git_url = f'https://github.com/{repo}.git'
        # 也可能是 marketplace.json 中声明的外部 url
        if not git_url:
            for mk_name, mk_info in known.items():
                mk_dir = mk_info.get('installLocation', '')
                mk_json = os.path.join(mk_dir, '.claude-plugin', 'marketplace.json')
                if os.path.isfile(mk_json):
                    with open(mk_json) as f:
                        mk_data = json.load(f)
                    for p in mk_data.get('plugins', []):
                        if p.get('name') == plugin_name:
                            src = p.get('source', {})
                            if isinstance(src, dict) and src.get('url'):
                                git_url = src['url']
                            break

    plugins.append({
        'name': plugin_name,
        'marketplace': marketplace,
        'version': entry.get('version', 'unknown'),
        'scope': entry.get('scope', 'user'),
        'git_url': git_url,
    })

manifest = {
    'version': 2,
    'marketplaces': real_marketplaces,
    'plugins': plugins,
}
out = os.environ['MANIFEST_PATH']
with open(out, 'w') as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
print(f'\033[32m✓\033[0m 已导出 \033[1m{len(plugins)}\033[0m 个插件到 {out}')
print(f'  Marketplaces: {len(real_marketplaces)} 个')
git_plugins = [p for p in plugins if p.get("git_url")]
print(f'  独立 Git 插件: {len(git_plugins)} 个')
PYTHON
}

do_install() {
  if [ ! -f "$MANIFEST" ]; then
    echo -e "\033[31m错误: 未找到 plugin-manifest.json\033[0m" >&2
    exit 1
  fi

  mkdir -p "$MARKETPLACES_DIR" "$CACHE_DIR"

  export MANIFEST_PATH="$MANIFEST"
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

def git_clone(url, dest):
    ret = subprocess.run(['git', 'clone', '--depth=1', url, dest],
                         capture_output=True, text=True)
    return ret.returncode == 0, ret.stderr.strip()

def git_pull(dest):
    subprocess.run(['git', '-C', dest, 'pull', '--ff-only'], capture_output=True)

def get_sha(path):
    try:
        return subprocess.check_output(
            ['git', 'rev-parse', 'HEAD'], cwd=path, stderr=subprocess.DEVNULL
        ).decode().strip()
    except Exception:
        return ''

def copy_plugin(src, dest):
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

# --- 加载 manifest ---
home = os.path.expanduser('~')
plugins_dir = os.path.join(home, '.claude/plugins')
marketplaces_dir = os.path.join(plugins_dir, 'marketplaces')
cache_dir = os.path.join(plugins_dir, 'cache')
manifest_path = os.environ['MANIFEST_PATH']

with open(manifest_path) as f:
    manifest = json.load(f)

now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')
marketplaces = manifest.get('marketplaces', {})
plugins = manifest.get('plugins', [])

# --- 1. 同步真正的 Marketplaces (有 marketplace.json 的仓库) ---
header('1. 同步 Marketplaces')
for name, repo in marketplaces.items():
    dest = os.path.join(marketplaces_dir, name)
    if os.path.isdir(dest):
        ok(f'{name} {DIM}(pull){RESET}')
        git_pull(dest)
    else:
        info(f'克隆 {BOLD}{repo}{RESET} ...')
        success, err = git_clone(f'https://github.com/{repo}.git', dest)
        if success:
            ok(name)
        else:
            fail(f'{name}: {err}')

# --- 2. 克隆独立 Git 插件仓库 (没有 marketplace.json 的) ---
header('2. 同步独立 Git 插件')
git_plugins = [p for p in plugins if p.get('git_url')]
git_sources = {}  # plugin_name -> clone path

if not git_plugins:
    ok('无')
else:
    for p in git_plugins:
        name = p['name']
        url = p['git_url']
        # 克隆到专门的 sources 目录，不放入 marketplaces
        src_dir = os.path.join(plugins_dir, 'sources', name)
        if os.path.isdir(src_dir):
            ok(f'{name} {DIM}(pull){RESET}')
            git_pull(src_dir)
        else:
            info(f'克隆 {BOLD}{name}{RESET} ...')
            os.makedirs(os.path.dirname(src_dir), exist_ok=True)
            success, err = git_clone(url, src_dir)
            if success:
                ok(name)
            else:
                fail(f'{name}: {err}')
                continue
        git_sources[name] = src_dir

# --- 3. 生成 known_marketplaces.json (只包含真正的 marketplace) ---
header('3. 生成 known_marketplaces.json')
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

# --- 4. 安装插件到 cache ---
header('4. 安装插件')

def find_plugin_source(plugin_name, marketplace, git_url):
    # 优先: 独立 Git 插件
    if plugin_name in git_sources:
        return git_sources[plugin_name]

    mp_dir = os.path.join(marketplaces_dir, marketplace)
    if not os.path.isdir(mp_dir):
        return None

    # 情况 A: 在常见子目录中查找
    for sub in ('plugins', 'external_plugins', 'packages'):
        candidate = os.path.join(mp_dir, sub, plugin_name)
        if os.path.isdir(candidate):
            return candidate

    # 情况 B: marketplace.json 中声明 - 本地路径或外部 git
    mj = os.path.join(mp_dir, '.claude-plugin', 'marketplace.json')
    if os.path.isfile(mj):
        with open(mj) as f:
            mkt = json.load(f)
        for p in mkt.get('plugins', []):
            if p.get('name') == plugin_name:
                # 本地路径
                src_field = p.get('source', '')
                if isinstance(src_field, str) and src_field:
                    found = os.path.join(mp_dir, src_field) if src_field != './' else mp_dir
                    if os.path.isdir(found):
                        return found
                # 外部 git url
                if isinstance(src_field, dict) and src_field.get('url'):
                    url = src_field['url']
                    sha = src_field.get('sha', '')
                    clone_dest = os.path.join(plugins_dir, 'sources', plugin_name)
                    if not os.path.isdir(clone_dest):
                        info(f'克隆外部插件 {BOLD}{plugin_name}{RESET} ...')
                        os.makedirs(os.path.dirname(clone_dest), exist_ok=True)
                        success, _ = git_clone(url, clone_dest)
                        if not success:
                            return None
                        if sha:
                            subprocess.run(['git', '-C', clone_dest, 'fetch', '--depth=1', 'origin', sha],
                                           capture_output=True)
                            subprocess.run(['git', '-C', clone_dest, 'checkout', sha],
                                           capture_output=True)
                    return clone_dest

    # 情况 C: 递归搜索 .claude-plugin/plugin.json
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

installed_plugins = {}
failed = []

for p in plugins:
    name, marketplace = p['name'], p['marketplace']
    version = p.get('version', 'unknown')
    git_url = p.get('git_url', '')

    src = find_plugin_source(name, marketplace, git_url)
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

    sha = get_sha(src) or get_sha(os.path.join(marketplaces_dir, marketplace))

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

# --- 5. 生成 installed_plugins.json ---
header('5. 生成 installed_plugins.json')
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
    do_export
    ;;
  install|"")
    do_install
    ;;
  *)
    echo "用法: $0 [install|export]"
    exit 1
    ;;
esac
