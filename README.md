# Claude Code Plugins Sync

跨机器一键同步 Claude Code 插件环境，无需关心路径差异。

## 首次安装（目标机器）

```bash
git clone <本仓库地址> ~/claude-plugins-sync
~/claude-plugins-sync/sync-plugins.sh
```

然后在 Claude Code 中运行 `/reload-plugins`。

## 同步新插件

在已配置好的机器上，安装新插件后：

```bash
cd ~/claude-plugins-sync
./sync-plugins.sh export
git add -A && git commit -m "update plugins" && git push
```

## 其他机器拉取更新

```bash
cd ~/claude-plugins-sync && git pull && ./sync-plugins.sh
```

然后在 Claude Code 中运行 `/reload-plugins`。
