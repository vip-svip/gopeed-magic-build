#!/system/bin/sh
# post-fs-data.sh - post-fs-data 阶段：极早期执行，只做不依赖网络/包管理器的事
MODDIR=${0%/*}
. "$MODDIR/bin/common.sh"

# 运行数据目录（/data 已可用）
mkdir -p "$STATE_DIR" "$STATE_DIR/storage" "$LOG_DIR" "$RUN_DIR" "$STATE_DIR/tmp" 2>/dev/null
chmod 0755 "$STATE_DIR" "$STATE_DIR/storage" "$LOG_DIR" "$RUN_DIR" "$STATE_DIR/tmp" 2>/dev/null

# 命令软链（system 分区可能被重建，这里每次开机兜底）
ensure_symlinks 2>/dev/null

# 绑定自定义 resolv.conf（部分机型 DNS 异常时用）
if [ -f "$MODDIR/system/etc/resolv.conf" ]; then
  mount --bind "$MODDIR/system/etc/resolv.conf" /system/etc/resolv.conf 2>/dev/null
fi
