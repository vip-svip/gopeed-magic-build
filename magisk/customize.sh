#!/system/bin/sh
# customize.sh - 模块安装阶段执行（KernelSU / Magisk 通用）
#
# 关键行为（上一版的问题：只写声明、不真正安装）：
#   1. 把 APK 放进 $MODPATH/system/app/Gopeed/ —— 系统扫描后即为「系统应用」
#   2. 同时在安装阶段直接 pm install，装完立刻可用，不必等重启
#   3. 校验两个动作的真实结果并输出，失败给出明确提示而不是假装成功

SKIPUNZIP=0

ui_print "******************************************"
ui_print "  Gopeed 魔改版（系统级）"
ui_print "  版本: $(grep '^version=' "$MODPATH/module.prop" | cut -d= -f2)"
ui_print "  作者: vip-svip"
ui_print "******************************************"

if [ "$ARCH" != "arm64" ]; then
  ui_print "! 当前架构 $ARCH 不受支持，本模块仅提供 arm64-v8a 二进制"
  abort "! 请使用 arm64 设备"
fi

# ---------- 1) 校验随包内容 ----------
ui_print "- 校验随包内容"
MISSING=""
for f in bin/gopeed bin/gopeed-cli bin/hlsdl bin/gopeed-hls bin/gopeedctl bin/common.sh \
         service.sh post-fs-data.sh uninstall.sh webroot/index.html system/etc/resolv.conf; do
  if [ -f "$MODPATH/$f" ]; then
    ui_print "    $f  OK"
  else
    ui_print "    $f  缺失"
    MISSING="$MISSING $f"
  fi
done
[ -n "$MISSING" ] && abort "! 模块包不完整:$MISSING"

# ---------- 2) 系统应用安装（真实落盘） ----------
APK_SRC="$MODPATH/system/priv-app/Gopeed/Gopeed.apk"
[ -f "$APK_SRC" ] || APK_SRC="$MODPATH/app/Gopeed.apk"

if [ -f "$APK_SRC" ]; then
  APK_SZ=$(du -k "$APK_SRC" 2>/dev/null | cut -f1)
  ui_print "- 内置 APK: ${APK_SZ}KB"

  # 2.1 放到 /system/app 下（重启后由 PMS 扫描注册为系统应用）
  mkdir -p "$MODPATH/system/priv-app/Gopeed"
  if [ "$APK_SRC" != "$MODPATH/system/priv-app/Gopeed/Gopeed.apk" ]; then
    cp -f "$APK_SRC" "$MODPATH/system/priv-app/Gopeed/Gopeed.apk"
  fi
  set_perm "$MODPATH/system/priv-app/Gopeed" 0 0 0755
  set_perm "$MODPATH/system/priv-app/Gopeed/Gopeed.apk" 0 0 0644
  ui_print "    已就位: /system/priv-app/Gopeed/Gopeed.apk（系统级特权应用）"

  # 2.2 安装阶段直接安装，装完即可用（不需要重启）
  ui_print "- 立即安装到系统（无需等重启）"
  if command -v pm >/dev/null 2>&1; then
    OUT=$(pm install -r -g -d "$MODPATH/system/priv-app/Gopeed/Gopeed.apk" 2>&1)
    ui_print "    pm: $OUT"
    case "$OUT" in
      *Success*)
        ui_print "    安装成功，打开即用"
        # 安装后确认包真的存在，并把系统应用形态写进模块状态
        if pm list packages 2>/dev/null | grep -q "com.gopeed.gopeed"; then
          echo "installed_at=$(date +%s)" > "$MODPATH/.install_state"
          echo "mode=pm+priv_app" >> "$MODPATH/.install_state"
        fi
        ;;
      *)
        ui_print "! pm install 未成功，重启后将由 /system/app 扫描安装"
        echo "mode=priv_app_only" > "$MODPATH/.install_state"
        ;;
    esac
  else
    ui_print "! 当前环境无 pm 命令，重启后由系统扫描 /system/app 安装"
    echo "mode=priv_app_only" > "$MODPATH/.install_state"
  fi
else
  ui_print "! 模块包内没有 APK，跳过应用安装（仅安装下载服务）"
fi

# ---------- 3) 权限 ----------
ui_print "- 设置权限"
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
for s in customize.sh post-fs-data.sh service.sh uninstall.sh action.sh; do
  [ -f "$MODPATH/$s" ] && set_perm "$MODPATH/$s" 0 0 0755
done

# ---------- 4) 运行数据目录 ----------
mkdir -p /data/adb/gopeed/storage /data/adb/gopeed/logs /data/adb/gopeed/run /data/adb/gopeed/tmp
set_perm_recursive /data/adb/gopeed 0 0 0755 0755

# ---------- 5) 命令软链（post-fs-data 会再兜底一次） ----------
for f in gopeed gopeed-cli hlsdl gopeed-hls gopeedctl; do
  [ -d /system/bin ] && ln -sf "$MODPATH/bin/$f" /system/bin/$f 2>/dev/null
done

ui_print "- 安装完成"
ui_print "  Web 面板: http://127.0.0.1:9999"
ui_print "  命令行: gopeed / gopeed-hls / hlsdl / gopeedctl"
ui_print "  卸载: 管理器移除模块，自动 0 残留"
