#!/usr/bin/env bash
# =============================================================================
#  verify-polaris.sh —— 一条命令跑完 polaris 的验收清单
#  用法: verify-polaris.sh [adb序列号]
# =============================================================================
set -uo pipefail
export ANDROID_ADB_SERVER_PORT="${ADB_PORT:-5037}"
export ADB_VENDOR_KEYS="${ADB_VENDOR_KEYS:-$HOME/.android/adbkey}"
SERIAL="${1:-${SERIAL:-}}"
A(){ if [ -n "$SERIAL" ]; then adb -s "$SERIAL" "$@"; else adb "$@"; fi; }
DS=/data/local/tmp/droidspaces

pass(){ echo "  ✓ $1"; }
fail(){ echo "  ✗ $1"; }

echo "══ 0. 设备身份(必须是 polaris) ══"
DEV=$(A shell getprop ro.product.device 2>/dev/null | tr -d '\r')
MODEL=$(A shell getprop ro.product.model 2>/dev/null | tr -d '\r')
REL=$(A shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')
echo "  device=$DEV model=$MODEL android=$REL"
[ "$DEV" = polaris ] || { fail "不是 polaris,拒绝继续"; exit 2; }

echo "══ 1. 内核身份 ══"
A shell 'cat /proc/version' | tr -d '\r' | sed 's/^/  /'

echo "══ 2. 命名空间(期望 cgroup ipc mnt net pid uts 六项) ══"
NS=$(A shell 'su -c "ls /proc/self/ns/"' 2>/dev/null | tr -d '\r' | tr '\n' ' ')
echo "  $NS"
for n in cgroup ipc mnt net pid uts; do
  case "$NS" in *"$n"*) pass "ns: $n";; *) fail "ns 缺 $n";; esac
done

echo "══ 3. 电源 / 温度 ══"
A shell 'su -c "for f in /sys/class/power_supply/*/; do n=\$(basename \$f); echo \"  \$n type=\$(cat \$f/type 2>/dev/null) cap=\$(cat \$f/capacity 2>/dev/null) status=\$(cat \$f/status 2>/dev/null)\"; done"' 2>/dev/null | tr -d '\r'

echo "══ 4. WiFi / 触屏 ══"
echo "  wlan0: $(A shell 'ip -4 addr show wlan0 2>/dev/null | grep -o "inet [0-9.]*"' | tr -d '\r')"
echo "  输入设备:"; A shell 'su -c "grep -E \"^N: Name\" /proc/bus/input/devices"' 2>/dev/null | tr -d '\r' | sed 's/^/    /'

echo "══ 5. 模块(kABI 观测点:本机应为纯内建,真模块数=0) ══"
echo "  /proc/modules 行数 = $(A shell 'wc -l < /proc/modules' 2>/dev/null | tr -d '\r')"
echo "  可卸载模块数      = $(A shell 'su -c "N=0; for m in /sys/module/*/; do [ -f \"\$m/refcnt\" ] && N=\$((N+1)); done; echo \$N"' 2>/dev/null | tr -d '\r')"

echo "══ 6. droidspaces ══"
if A shell "test -x $DS" 2>/dev/null; then
  A shell "su -c '$DS check 2>&1'" 2>/dev/null | tr -d '\r' | grep -E '\[.\]' | sed 's/^/  /'
  echo "  --- 容器 ---"
  A shell "su -c '$DS show 2>&1'" 2>/dev/null | tr -d '\r' | sed 's/^/  /'
else
  fail "$DS 不存在(droidspaces 未安装)"
fi

echo "══ 7. 容器内系统 ══"
if [ -f /dev/null ]; then :; fi
A shell "su -c '$DS --name=ubuntu run /bin/sh /root/verify.sh 2>&1'" 2>/dev/null | tr -d '\r' | tail -18

echo "══ 8. 截图 ══"
A exec-out screencap -p > /tmp/verify-polaris.png 2>/dev/null \
  && echo "  已保存 /tmp/verify-polaris.png ($(stat -c %s /tmp/verify-polaris.png) B)" \
  || fail "截图失败"
