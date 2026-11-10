#!/system/bin/sh
# common.sh - 共享函数（被 service.sh / gopeedctl / action.sh 引用）

MODDIR="${MODDIR:-/data/adb/modules/gopeed_ksu}"
STATE_DIR=/data/adb/gopeed
LOG_DIR="$STATE_DIR/logs"
LOG_FILE="$LOG_DIR/gopeed.log"
RUN_DIR="$STATE_DIR/run"
PIDFILE="$RUN_DIR/gopeed.pid"
WATCHDOG_PID="$RUN_DIR/watchdog.pid"
CONF="$STATE_DIR/config.json"
# 端口启停开关：存在即启用（默认启用）
ENABLED_FLAG="$STATE_DIR/port_enabled"
ENABLED_FILE="$STATE_DIR/port_disabled"

# 监听地址/端口（如需局域网访问改成 0.0.0.0）
BIND_ADDR="${GOPEED_BIND:-127.0.0.1}"
# 端口持久化文件：用户可在 App/Web 面板改端口，重启后沿用
PORT_FILE="$STATE_DIR/port"
if [ -z "$GOPEED_PORT" ] && [ -f "$PORT_FILE" ]; then
  _pf=$(cat "$PORT_FILE" 2>/dev/null | tr -dc '0-9')
  [ -n "$_pf" ] && GOPEED_PORT="$_pf"
fi
BIND_PORT="${GOPEED_PORT:-9999}"

# 写入端口（校验 1..65535），并同步到 App 可读的位置
set_bind_port() {
  _np=$(echo "$1" | tr -dc '0-9')
  [ -n "$_np" ] || return 1
  [ "$_np" -ge 1 ] && [ "$_np" -le 65535 ] || return 1
  mkdir -p "$STATE_DIR" 2>/dev/null
  echo "$_np" > "$PORT_FILE"
  BIND_PORT="$_np"
  return 0
}

# 默认下载目录：通过 HOME 决定 => /storage/emulated/0/Downloads
export GOPEED_HOME="${GOPEED_HOME:-/storage/emulated/0}"

log() {
  mkdir -p "$LOG_DIR" 2>/dev/null
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

gopeed_bin() {
  if [ -x "$MODDIR/bin/gopeed" ]; then echo "$MODDIR/bin/gopeed"; else echo "gopeed"; fi
}

# 用户是否允许端口运行（关闭后开机不自动拉起）
port_enabled() {
  [ -f "$ENABLED_FILE" ] && return 1
  return 0
}

set_port_enabled() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  if [ "$1" = "0" ]; then
    : > "$ENABLED_FILE"
    rm -f "$ENABLED_FLAG" 2>/dev/null
  else
    rm -f "$ENABLED_FILE" 2>/dev/null
    : > "$ENABLED_FLAG"
  fi
}

prepare_env() {
  mkdir -p "$STATE_DIR/storage" "$LOG_DIR" "$RUN_DIR" "$STATE_DIR/tmp" 2>/dev/null
  chmod 0755 "$STATE_DIR" "$STATE_DIR/storage" "$LOG_DIR" "$RUN_DIR" "$STATE_DIR/tmp" 2>/dev/null
  # 让 Go 二进制能解析域名（Android 无 /etc/resolv.conf）
  if [ ! -s /system/etc/resolv.conf ] && [ -s "$MODDIR/system/etc/resolv.conf" ]; then
    mount --bind "$MODDIR/system/etc/resolv.conf" /system/etc/resolv.conf 2>/dev/null
  fi
  export HOME="$GOPEED_HOME"
  export TMPDIR="$STATE_DIR/tmp"
  export PATH="$MODDIR/bin:$PATH"
}

# 开机阶段 /storage/emulated/0 可能尚未挂载完成，等它就绪再启动，
# 否则 gopeed 会在不可写的 HOME 下启动失败 —— 这正是「开机不自动起端口」的根因。
wait_storage() {
  i=0
  while [ $i -lt 60 ]; do
    if [ -d /storage/emulated/0 ] && [ -w /storage/emulated/0 ]; then
      return 0
    fi
    sleep 2
    i=$((i+1))
  done
  # 仍未就绪：退回模块内部可写目录，保证端口一定能起来
  GOPEED_HOME="$STATE_DIR/storage"
  export GOPEED_HOME
  log "外部存储未就绪，HOME 回退到 $GOPEED_HOME"
  return 0
}

is_running() {
  if [ -f "$PIDFILE" ]; then
    pid=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  if pidof gopeed >/dev/null 2>&1; then return 0; fi
  for p in /proc/[0-9]*/exe; do
    case "$(readlink "$p" 2>/dev/null)" in
      */bin/gopeed|*/gopeed) return 0 ;;
    esac
  done
  return 1
}

# 端口是否已经在 LISTEN。
# 注意：Android 的 sh(mksh) 不支持 bash 的 /dev/tcp，用它探测会永远失败，
# 导致 start_gopeed 每次都白等 10 秒、状态页永远显示"端口未就绪"。
# 这里直接读内核的 /proc/net/tcp，state=0A 即 LISTEN。
port_open() {
  hex=$(printf '%04X' "$BIND_PORT" 2>/dev/null)
  [ -n "$hex" ] || return 1
  for f in /proc/net/tcp /proc/net/tcp6; do
    [ -r "$f" ] || continue
    if awk -v pat=":$hex" '$4 == "0A" && index($2, pat) { hit = 1 } END { exit(hit ? 0 : 1) }' "$f" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

start_gopeed() {
  prepare_env
  if is_running; then
    log "gopeed 已在运行，跳过启动"
    return 0
  fi
  bin=$(gopeed_bin)
  if [ ! -x "$bin" ]; then
    log "错误：找不到可执行文件 $bin"
    return 1
  fi
  log "启动 gopeed (bind=$BIND_ADDR:$BIND_PORT home=$HOME)"
  HOME="$GOPEED_HOME" TMPDIR="$STATE_DIR/tmp" \
    nohup "$bin" \
      -A "$BIND_ADDR" \
      -P "$BIND_PORT" \
      -d "$STATE_DIR/storage" \
      -c "$CONF" \
      -white-download-dirs "/storage/emulated/0,/storage/emulated/0/Download,/storage/emulated/0/Downloads,/sdcard" \
      >> "$LOG_DIR/gopeed.out" 2>&1 &
  echo $! > "$PIDFILE"
  sleep 2
  # 端口需要一点时间 listen，最多再等 10 秒
  n=0
  while [ $n -lt 10 ]; do
    if is_running && port_open; then
      log "gopeed 启动成功 pid=$(cat "$PIDFILE") port=$BIND_PORT"
      return 0
    fi
    sleep 1
    n=$((n+1))
  done
  if is_running; then
    log "gopeed 进程在，但端口 $BIND_PORT 未就绪"
    return 0
  fi
  log "gopeed 启动失败，见 $LOG_DIR/gopeed.out"
  return 1
}

stop_gopeed() {
  if [ -f "$PIDFILE" ]; then
    pid=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    sleep 1
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
    rm -f "$PIDFILE"
  fi
  for p in /proc/[0-9]*/exe; do
    case "$(readlink "$p" 2>/dev/null)" in
      */bin/gopeed|*/gopeed)
        kill -9 "$(basename "$(dirname "$p")")" 2>/dev/null ;;
    esac
  done
  log "gopeed 已停止"
}

start_watchdog() {
  [ -f "$WATCHDOG_PID" ] && kill -0 "$(cat "$WATCHDOG_PID" 2>/dev/null)" 2>/dev/null && return 0
  (
    while true; do
      sleep 45
      if ! is_running; then
        log "守护进程检测到 gopeed 未运行，自动重启"
        start_gopeed
      fi
    done
  ) >/dev/null 2>&1 &
  echo $! > "$WATCHDOG_PID"
}

stop_watchdog() {
  if [ -f "$WATCHDOG_PID" ]; then
    kill "$(cat "$WATCHDOG_PID" 2>/dev/null)" 2>/dev/null
    rm -f "$WATCHDOG_PID"
  fi
}

wait_boot_complete() {
  i=0
  while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ $i -lt 120 ]; do
    sleep 3
    i=$((i+1))
  done
  sleep 3
}

ensure_symlinks() {
  for f in gopeed hlsdl gopeed-hls gopeedctl; do
    target="$MODDIR/bin/$f"
    [ -x "$target" ] || continue
    for d in /system/bin /system/xbin; do
      [ -d "$d" ] || continue
      [ -e "$d/$f" ] && [ ! -L "$d/$f" ] && continue
      ln -sf "$target" "$d/$f" 2>/dev/null
    done
  done
}
