#!/usr/bin/env bash
# =============================================================================
#  flash-polaris.sh —— 把内核刷进 polaris(MIX 2S),走最安全的路径
#
#  用法:
#     flash-polaris.sh ram    <boot.img>   # fastboot boot —— RAM 试启动,【不写 flash】
#     flash-polaris.sh flash  <boot.img>   # fastboot flash boot —— 固化
#     flash-polaris.sh verify              # 只看当前内核身份 / 命名空间
#
#  为什么先 ram:
#     polaris 是 A-only、只有单一 boot 分区,没有 A/B 回退。`fastboot boot` 把镜像载入
#     内存启动,失败就自然回到 flash 里的旧内核 —— 零风险验证手段。
#
#  ⚠ 进 fastboot 前会杀掉本机所有 fastboot 守望进程(默认匹配 polaris-fastboot-watch)。
#     这种守望通常"一见 fastboot 就把原厂刷回去",会覆盖你正要刷的镜像。
#     如需保留,设 KILL_WATCHERS=no
# =============================================================================
set -euo pipefail

export ANDROID_ADB_SERVER_PORT="${ADB_PORT:-5037}"
export ADB_VENDOR_KEYS="${ADB_VENDOR_KEYS:-$HOME/.android/adbkey}"
KILL_WATCHERS="${KILL_WATCHERS:-yes}"
WATCH_PATTERN="${WATCH_PATTERN:-[p]olaris-fastboot-watch}"
SERIAL="${SERIAL:-}"
A(){ if [ -n "$SERIAL" ]; then adb -s "$SERIAL" "$@"; else adb "$@"; fi; }

MODE=${1:-verify}
IMG=${2:-}

wait_android(){
  echo "══ 等 Android 上线(最多 8 分钟) ══"
  for i in $(seq 1 96); do
    BC=$(A shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)
    [ "$BC" = "1" ] && { echo "  [${i}] boot_completed=1 ✓"; return 0; }
    sleep 5
  done
  echo "  ✗ 8 分钟未起来" >&2; return 1
}

case "$MODE" in
  verify)
    echo "══ 当前内核身份 ══"
    A shell 'cat /proc/version; uname -a' | tr -d '\r'
    echo "══ 命名空间(应有 uts 与 ipc) ══"
    A shell 'su -c "ls /proc/self/ns/"' | tr -d '\r' | tr '\n' ' '; echo
    echo "══ droidspaces check ══"
    A shell 'su -c "/data/local/tmp/droidspaces check 2>&1"' | tr -d '\r' | head -22
    exit 0
    ;;
  ram|flash) ;;
  *) echo "用法: flash-polaris.sh <ram|flash|verify> [boot.img]" >&2; exit 2 ;;
esac

[ -n "$IMG" ] && [ -f "$IMG" ] || { echo "✗ 找不到镜像: $IMG" >&2; exit 2; }
echo "══ 镜像 ══"; ls -la "$IMG"; md5sum "$IMG"

if [ "$KILL_WATCHERS" = yes ]; then
  echo "══ 杀本机 fastboot 守望(避免它把原厂刷回去) ══"
  pkill -f "$WATCH_PATTERN" 2>/dev/null && echo "  已杀" || echo "  无守望在跑"
  sleep 1
fi

echo "══ 进 bootloader ══"
A reboot bootloader || true
echo "══ 等 fastboot 枚举(最多 2 分钟) ══"
FD=""
for i in $(seq 1 40); do
  FD=$(timeout 8 fastboot devices 2>/dev/null | head -1 || true)
  [ -n "$FD" ] && { echo "  [${i}] $FD"; break; }
  sleep 3
done
[ -n "$FD" ] || { echo "✗ 没等到 fastboot。设备仍在 Android,无损" >&2; exit 4; }
timeout 15 fastboot getvar product 2>&1 | head -2 || true

if [ "$MODE" = ram ]; then
  echo "══ ★ fastboot boot(RAM 试启动,不写 flash) ══"
  timeout 240 fastboot boot "$IMG" 2>&1 | tail -5
  wait_android || exit 5
  echo "══ 试启动后的内核身份 ══"
  A shell 'cat /proc/version' | tr -d '\r'
  echo "══ 命名空间 ══"
  A shell 'su -c "ls /proc/self/ns/"' | tr -d '\r' | tr '\n' ' '; echo
  echo "✓ 若上面是期望的版本/命名空间,接着跑: $0 flash $IMG"
else
  echo "══ ★ fastboot flash boot(固化) ══"
  timeout 300 fastboot flash boot "$IMG" 2>&1 | tail -5
  echo "══ 重启 ══"
  timeout 60 fastboot reboot 2>&1 | tail -2
  wait_android || exit 5
  echo "══ 固化后的内核身份 ══"
  A shell 'cat /proc/version' | tr -d '\r'
fi
