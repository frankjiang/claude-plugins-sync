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
  python3 -c "
import json, os, sys

plugins_dir = os.path.expanduser('~/.claude/plugins')
known_path = os.path.join(plugins_dir, 'known_marketplaces.json')
installed_path = os.path.join(plugins_dir, 'installed_plugins.json')

for p in [known_path, installed_path]:
    if not os.path.isfile(p):
        print(f'错误: 未找到 {p}', file=sys.stderr)
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
out = sys.argv[1]
with open(out, 'w') as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
print(f'✓ 已导出 {len(plugins)} 个插件到 {out}')
" "$MANIFEST"
}

do_install() {
  if [ ! -f "$MANIFEST" ]; then
    echo "错误: 未找到 plugin-manifest.json" >&2
    exit 1
  fi

  mkdir -p "$MARKETPLACES_DIR" "$CACHE_DIR"

  python3 -c "
import json, os, subprocess, sys
from datetime import datetime, timezone

with open(sys.argv[1]) as f:
    manifest = json.load(f)

home = os.path.expanduser('~')
plugins_dir = os.path.join(home, '.claude/plugins')
marketplaces_dir = os.path.join(plugins_dir, 'marketplaces')
cache_dir = os.path.join(plugins_dir, 'cache')
now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')

marketplaces = manifest['marketplaces']
plugins = manifest['plugins']

print('=== 1. 同步 Marketplaces ===')
for name, repo in marketplaces.items():
    dest = os.path.join(marketplaces_dir, name)
    if os.path.isdir(dest):
        print(f'  ✓ {name} 已存在，拉取更新...')
        subprocess.run(['git', '-C', dest, 'pull', '--ff-only'], capture_output=True)
    else:
        print(f'  → 克隆 {repo} ...')
        subprocess.run(['git', 'clone', f'https://github.com/{repo}.git', dest], check=True)

print('=== 2. 生成 known_marketplaces.json ===')
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
print(f'  ✓ {len(known)} 个 marketplace')

print('=== 3. 安装插件到 cache ===')

def find_plugin_source(plugin_name, marketplace):
    mp_dir = os.path.join(marketplaces_dir, marketplace)
    pj = os.path.join(mp_dir, '.claude-plugin', 'plugin.json')
    if os.path.isfile(pj):
        with open(pj) as f:
            meta = json.load(f)
        if meta.get('name') == plugin_name:
            return mp_dir
    candidate = os.path.join(mp_dir, 'plugins', plugin_name)
    if os.path.isdir(candidate):
        return candidate
    mj = os.path.join(mp_dir, '.claude-plugin', 'marketplace.json')
    if os.path.isfile(mj):
        with open(mj) as f:
            mkt = json.load(f)
        for p in mkt.get('plugins', []):
            if p.get('name') == plugin_name:
                return os.path.join(mp_dir, p.get('path', f'plugins/{plugin_name}'))
    return None

installed_plugins = {}
for p in plugins:
    name, marketplace = p['name'], p['marketplace']
    version = p.get('version', 'unknown')

    src = find_plugin_source(name, marketplace)
    if not src:
        print(f'  ⚠ {name} ({marketplace}) 未找到源码，跳过')
        continue

    dest = os.path.join(cache_dir, marketplace, name, version)
    os.makedirs(dest, exist_ok=True)
    subprocess.run(['cp', '-R', f'{src}/.', dest], check=True)

    sha = ''
    try:
        sha = subprocess.check_output(
            ['git', 'rev-parse', 'HEAD'],
            cwd=os.path.join(marketplaces_dir, marketplace),
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
    print(f'  ✓ {name}')

print('=== 4. 生成 installed_plugins.json ===')
with open(os.path.join(plugins_dir, 'installed_plugins.json'), 'w') as f:
    json.dump({'version': 2, 'plugins': installed_plugins}, f, indent=2)
print(f'  ✓ {len(installed_plugins)} 个插件已注册')
print()
print('完成！请在 Claude Code 中运行 /reload-plugins')
" "$MANIFEST"
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
