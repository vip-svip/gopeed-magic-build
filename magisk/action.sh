#!/system/bin/sh
# action.sh - 模块卡片「操作」按钮：显示运行状态
MODDIR=${0%/*}
. "$MODDIR/bin/common.sh"

clear 2>/dev/null
echo "=========================================="
echo "  Gopeed 魔改版（系统级）"
echo "=========================================="

if is_running; then
  echo "服务状态: 运行中"
  echo "PID: $(cat "$PID_FILE" 2>/dev/null)"
  echo "Web 面板: http://127.0.0.1:$(grep -o 'BIND_PORT="[0-9]*"' "$MODDIR/bin/common.sh" | grep -o '[0-9]*' | head -1)"
else
  echo "服务状态: 未运行"
fi

if pm list packages 2>/dev/null | grep -qx "package:com.gopeed.gopeed"; then
  echo "应用状态: 已安装"
else
  echo "应用状态: 未安装"
fi

SYS_APK="$MODDIR/system/app/Gopeed/Gopeed.apk"
if [ -f "$SYS_APK" ]; then
  echo "系统应用: 已内置 ($(du -k "$SYS_APK" | cut -f1)KB)"
else
  echo "系统应用: 未内置"
fi

echo "------------------------------------------"
echo "协议支持（内核内置）:"
echo "  HTTP/HTTPS  FTP/FTPS/FTPES  BitTorrent"
echo "  Magnet      ed2k             HLS(.m3u8)"
echo "  DASH(.mpd)"
echo "=========================================="
sleep 3 2>/dev/null
