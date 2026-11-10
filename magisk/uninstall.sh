#!/system/bin/sh
# uninstall.sh - 卸载模块：停止服务并清除全部落盘痕迹（0 残留）
MODDIR=${0%/*}
. "$MODDIR/bin/common.sh"

PKG="com.gopeed.gopeed"

# 1) 停止守护与主进程
stop_watchdog
stop_gopeed

# 2) 强制停止应用，避免被拉活后重建数据
command -v am >/dev/null 2>&1 && am force-stop "$PKG" 2>/dev/null

# 3) 结束一切相关残留进程
for c in /proc/[0-9]*/cmdline; do
  pid=${c#/proc/}; pid=${pid%/cmdline}
  [ "$pid" = "$$" ] && continue
  cmd=$(tr '\0' ' ' < "$c" 2>/dev/null)
  case "$cmd" in
    *gopeed*|*hlsdl*|*gopeedctl*) kill -9 "$pid" 2>/dev/null ;;
  esac
done

# 4) 删除命令软链
for f in gopeed gopeed-cli hlsdl gopeed-hls gopeedctl; do
  for d in /system/bin /system/xbin /system/sbin /vendor/bin /data/adb/ksu/bin /data/adb/ap/bin; do
    [ -L "$d/$f" ] && rm -f "$d/$f" 2>/dev/null
  done
done

# 5) 解除 resolv.conf 绑定挂载
if mount 2>/dev/null | grep -q "/system/etc/resolv.conf"; then
  umount /system/etc/resolv.conf 2>/dev/null || umount -l /system/etc/resolv.conf 2>/dev/null
fi

# 6) 模块运行数据
rm -rf /data/adb/gopeed 2>/dev/null
rm -rf /data/local/tmp/gopeed-* /data/local/tmp/hlsdl-* 2>/dev/null

# 7) 应用私有数据（CE / DE / 外部存储 / 缓存统计）
for p in \
  "/data/data/$PKG" \
  "/data/user/0/$PKG" \
  "/data/user_de/0/$PKG" \
  "/data/media/0/Android/data/$PKG" \
  "/data/media/0/Android/media/$PKG" \
  "/storage/emulated/0/Android/data/$PKG" \
  "/storage/emulated/0/Android/media/$PKG" \
  "/storage/emulated/0/Android/obb/$PKG" \
  "/data/misc/profiles/cur/0/$PKG" \
  "/data/misc/profiles/ref/$PKG" \
  "/data/system_ce/0/shortcut_service/backups/$PKG" \
  "/data/system_ce/0/shortcut_service/packages/$PKG"
do
  [ -e "$p" ] && rm -rf "$p" 2>/dev/null
done
rm -rf /data/dalvik-cache/*"$PKG"* 2>/dev/null

# 8) 系统应用解压副本与残留 APK
rm -rf /data/app/~~*/"$PKG"-* 2>/dev/null
rm -rf /data/app/"$PKG"-* 2>/dev/null
rm -f /sdcard/Download/Gopeed-arm64.apk /storage/emulated/0/Download/Gopeed-arm64.apk 2>/dev/null

# 9) 模块更新暂存目录
rm -rf /data/adb/modules_update/gopeed_ksu 2>/dev/null
rm -rf /data/adb/modules/gopeed_ksu 2>/dev/null

# 10) 两轮复查，被延迟重建的目录再删一次
i=0
while [ $i -lt 2 ]; do
  RES=""
  for p in /data/adb/gopeed "/data/data/$PKG" "/data/user_de/0/$PKG" \
           "/storage/emulated/0/Android/data/$PKG" \
           "/data/adb/modules/gopeed_ksu" "/data/adb/modules_update/gopeed_ksu"; do
    [ -e "$p" ] && RES="$RES $p"
  done
  [ -z "$RES" ] && break
  sleep 1
  for p in $RES; do rm -rf "$p" 2>/dev/null; done
  i=$((i+1))
done

RES=""
for p in /data/adb/gopeed "/data/data/$PKG" "/data/user_de/0/$PKG" \
         "/storage/emulated/0/Android/data/$PKG" \
         "/data/adb/modules/gopeed_ksu" "/data/adb/modules_update/gopeed_ksu"; do
  [ -e "$p" ] && RES="$RES $p"
done
if [ -n "$RES" ]; then
  log "卸载完成，仍残留：$RES"
else
  log "卸载完成，已 0 残留"
fi
