#!/usr/bin/env bash
# 发布到目标仓库 Releases（跨仓）
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN 未设置}"
: "${TARGET_REPO:?TARGET_REPO 未设置}"
: "${TAG:?TAG 未设置}"

export GH_TOKEN
echo "== 发布到 $TARGET_REPO   tag=$TAG =="
ls -lh out || true

read -r -d '' BODY <<'EOF' || true
**作者：vip-svip**

Gopeed 魔改版：iOS 风格界面 · 静默下载 · 下载弹窗样式可选 · 退出最小化 · 最近任务隐藏 · 系统级模块。

### 资产
| 文件 | 说明 |
|---|---|
| `Gopeed-magic-arm64.apk` | Android arm64 客户端 |
| `Gopeed-magic-windows-amd64-portable.zip` | Windows 便携版（解压即用） |
| `Gopeed-ksu-system-v*.zip` | KernelSU / Magisk 系统级模块（内置 APK + 下载服务 + WebUI） |
| `SHA256SUMS.txt` | 校验和 |

### 新增与修复（本轮）
- **静默下载真正生效**：提交入口直接读取配置，开启后不再弹出解析/确认窗口，直接建任务；不再是只有开关没有行为
- **下载弹窗样式**：1 浮窗 / 2 全屏 / 3 实时通知 / 4 浮窗+通知，四种真正不同：
  - 浮窗 = 应用内实时进度悬浮条（显示总进度与速度，可暂停）
  - 全屏 = 提交后进入任务页
  - 实时通知 = 仅系统通知栏进度（Android 端已接入通知渠道与授权）
  - 浮窗+通知 = 两者同时
- **装完即用**：模块安装阶段把 APK 放入 `/system/app/Gopeed` 并直接 `pm install -r -g -d`，不必等重启
- **退出时最小化**：返回键退到后台，下载不中断
- **从最近任务隐藏**：原生 `setExcludeFromRecents` 真正生效
- **Root 提权**：真实执行 `su -c id` 探测，可开关；未获得授权时明确降级提示
- **Web 面板**：改为通用下载面板，不再单独显示 m3u8 / HLS 入口

### 协议（全部由 Go 内核处理）
HTTP/HTTPS、FTP/FTPS/FTPES、BitTorrent（.torrent / Magnet）、ed2k、HLS（.m3u8，含 AES-128、fMP4、BYTERANGE、直播窗口）。

不含 DRM / 付费授权绕过能力。

### 卸载
停止进程、删软链、解绑定挂载、清 CE/DE 私有数据、外部存储、dalvik-cache、APK 副本与更新暂存目录，两轮复查，**0 残留**。你自己的下载文件不会被删除。
EOF

if ! gh release view "$TAG" --repo "$TARGET_REPO" >/dev/null 2>&1; then
  gh release create "$TAG" --repo "$TARGET_REPO" --title "Gopeed 魔改版 $TAG" --notes "$BODY"
else
  gh release edit "$TAG" --repo "$TARGET_REPO" --notes "$BODY"
fi

shopt -s nullglob
FILES=(out/*)
if [ ${#FILES[@]} -eq 0 ]; then
  echo "错误：out/ 为空，无可发布资产" >&2
  exit 1
fi
gh release upload "$TAG" --repo "$TARGET_REPO" "${FILES[@]}" --clobber

echo "== 发布结果 =="
gh release view "$TAG" --repo "$TARGET_REPO" --json tagName,assets \
  --jq '.tagName, (.assets[] | "\(.name)  \(.size) bytes")'
