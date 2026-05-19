# Claude Code Plugins Sync

在任意机器上一键同步 Claude Code 插件环境。

## 使用

```bash
git clone <本仓库> && cd claude-plugins-sync && ./sync-plugins.sh
```

执行完毕后在 Claude Code 中运行 `/reload-plugins`。

## 更新插件列表

在已配置好的机器上运行：

```bash
cd claude-plugins-sync && ./sync-plugins.sh export && git add -A && git commit -m "update plugins" && git push
```
