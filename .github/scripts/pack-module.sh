#!/usr/bin/env bash
# 组装 KernelSU / Magisk 模块包
#
# 关键点：模块随包内容一项都不能少（上一轮就是被 .gitignore 吞掉了 bin/*）。
# 因此在打包前后都做清单校验，缺项直接失败，绝不产出半残包。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

APK_IN="${1:-}"
OUT_DIR="${2:-out}"

SRC="magisk"
WORK="build/module"
rm -rf "$WORK"
mkdir -p "$WORK" "$OUT_DIR"

# ---------- 1) 复制模块脚本本体 ----------
if [ ! -d "$SRC/bin" ]; then
  echo "FATAL: 源码缺少 $SRC/bin（.gitignore 的 bin/ 规则会吞掉它，检查 !/magisk/bin/ 例外）" >&2
  exit 1
fi
cp -a "$SRC/." "$WORK/"
# 只在匹配到真实文件时才 chmod，避免通配符无匹配时 set -e 直接退出
for f in "$WORK"/*.sh; do [ -f "$f" ] && chmod 0755 "$f"; done
for f in "$WORK"/bin/*; do [ -f "$f" ] && chmod 0755 "$f"; done

# ---------- 2) 交叉编译 Android arm64 二进制 ----------
# 关键：start_gopeed 传的是 -A/-P/-d/-c/-white-download-dirs，
# 这些参数只存在于 cmd/web（web 版服务端）。之前打包的是 cmd/gopeed（命令行下载器），
# 它的 flag 里没有这些参数，进程一启动就因未知参数退出，
# 于是表现为「开机不自启端口」「模块未联动」「Web 打不开/极慢」。
# 因此 bin/gopeed 必须是 cmd/web；CLI 版另存为 gopeed-cli。
echo "== 交叉编译 linux/arm64 二进制 =="
mkdir -p "$WORK/bin"
export CGO_ENABLED=0 GOOS=linux GOARCH=arm64

go build -tags "nosqlite web" -trimpath -ldflags="-w -s" \
  -o "$WORK/bin/gopeed" ./cmd/web

go build -tags nosqlite -trimpath -ldflags="-w -s" \
  -o "$WORK/bin/gopeed-cli" ./cmd/gopeed

chmod 0755 "$WORK/bin/gopeed" "$WORK/bin/gopeed-cli"

# 自检：bin/gopeed 必须是 web 版，否则 start_gopeed 传的 -A/-P/-d/-c 会让进程立刻退出。
# 注意 runner 是 x86_64，不能执行 arm64 二进制，因此用字符串静态校验 flag 定义。
for flag_name in "white-download-dirs" "mcp-enable" "--A" "--P"; do
  if ! grep -a -q -- "$flag_name" "$WORK/bin/gopeed"; then
    echo "FATAL: bin/gopeed 缺少 '$flag_name'，它不是 cmd/web 产物，模块必然启动失败" >&2
    exit 1
  fi
done
if grep -a -q -- "white-download-dirs" "$WORK/bin/gopeed-cli"; then
  echo "FATAL: gopeed-cli 意外包含 web 参数，检查 build tag" >&2
  exit 1
fi
echo "  self-check OK: bin/gopeed 为 web 版（含 -A/-P/-d/-c/-white-download-dirs）"

file "$WORK/bin/gopeed" || true
ls -lh "$WORK/bin"

# ---------- 3) 放入内置 APK ----------
# 放在 /system/priv-app 才是真正的「系统级」特权应用；
# /system/app 只是系统应用，拿不到 privileged 权限。
if [ -n "$APK_IN" ] && [ -f "$APK_IN" ]; then
  mkdir -p "$WORK/system/priv-app/Gopeed" "$WORK/system/etc/permissions"
  cp -f "$APK_IN" "$WORK/system/priv-app/Gopeed/Gopeed.apk"
  chmod 0644 "$WORK/system/priv-app/Gopeed/Gopeed.apk"
  chmod 0755 "$WORK/system/priv-app/Gopeed"
  # 权限白名单：priv-app 必须声明 privileged 权限，否则部分 ROM 拒绝注册
  cat > "$WORK/system/etc/permissions/privapp-permissions-gopeed.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<permissions>
    <privapp-permissions package="com.gopeed.gopeed">
        <permission name="android.permission.WRITE_SECURE_SETTINGS" />
        <permission name="android.permission.MANAGE_EXTERNAL_STORAGE" />
        <permission name="android.permission.READ_EXTERNAL_STORAGE" />
        <permission name="android.permission.WRITE_EXTERNAL_STORAGE" />
        <permission name="android.permission.FOREGROUND_SERVICE" />
        <permission name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />
        <permission name="android.permission.POST_NOTIFICATIONS" />
        <permission name="android.permission.RECEIVE_BOOT_COMPLETED" />
        <permission name="android.permission.REQUEST_INSTALL_PACKAGES" />
    </privapp-permissions>
</permissions>
XML
  chmod 0644 "$WORK/system/etc/permissions/privapp-permissions-gopeed.xml"
  echo "内置 APK: $(du -h "$WORK/system/priv-app/Gopeed/Gopeed.apk" | cut -f1) -> /system/priv-app"
else
  echo "错误：没有提供 APK，模块将不含应用" >&2
  exit 1
fi

# ---------- 4) 打包前清单校验 ----------
echo "== 打包前校验 =="
NEED="module.prop customize.sh service.sh post-fs-data.sh uninstall.sh action.sh \
webroot/index.html bin/common.sh bin/gopeed bin/gopeed-cli bin/hlsdl bin/gopeed-hls bin/gopeedctl \
system/etc/resolv.conf system/priv-app/Gopeed/Gopeed.apk system/etc/permissions/privapp-permissions-gopeed.xml"
MISS=""
for f in $NEED; do
  if [ -s "$WORK/$f" ]; then
    echo "  OK   $f"
  else
    echo "  MISS $f"
    MISS="$MISS $f"
  fi
done
[ -n "$MISS" ] && { echo "FATAL: 模块缺失:$MISS" >&2; exit 1; }

# ---------- 5) 语法校验（编译前的静态测试） ----------
echo "== 脚本语法校验 =="
for f in "$WORK"/*.sh "$WORK"/bin/*; do
  case "$f" in
    */gopeed|*/gopeed-cli) continue ;;  # 二进制
  esac
  if head -c 2 "$f" | grep -q '#!'; then
    sh -n "$f" || { echo "FATAL: 语法错误 $f" >&2; exit 1; }
    echo "  syntax OK  $(basename "$f")"
  fi
done

# ---------- 6) 打包 ----------
VER=$(grep '^version=' "$WORK/module.prop" | cut -d= -f2)
VER="${VER#v}"
ZIP="$OUT_DIR/Gopeed-ksu-system-v${VER}.zip"
rm -f "$ZIP"
( cd "$WORK" && zip -r -q -9 "$OLDPWD/$ZIP" . -x '.*' )
echo "== 产出 =="
ls -lh "$ZIP"

echo "== 包内清单 =="
unzip -l "$ZIP" | tail -30
