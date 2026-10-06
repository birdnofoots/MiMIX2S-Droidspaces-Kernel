#!/usr/bin/env bash
# =============================================================================
#  build-kernel.sh —— polaris 内核编译(与 CI 完全同一套命令,可本地跑)
#
#  用法:
#    build-kernel.sh [配置文件] [输出目录] [源码目录]
#  环境:
#    CC_BIN=clang-11            编译器(clang-11 或 AOSP clang 的 clang 绝对路径)
#    JOBS=$(nproc)              并行度
#    UPSTREAM=<git url>         源码仓库
#    UPSTREAM_REF=<ref>         分支/commit
# =============================================================================
set -euo pipefail

CFG=${1:-configs/polaris-v3.config}
OUT=${2:-out}
SRC=${3:-kernel}
CC_BIN=${CC_BIN:-clang-11}
JOBS=${JOBS:-$(nproc)}
UPSTREAM=${UPSTREAM:-https://github.com/LineageOS/android_kernel_xiaomi_sdm845.git}
UPSTREAM_REF=${UPSTREAM_REF:-aa8adfe9bf212c6e93238a86980b4024da4f819a}

MAKE_ARGS=(
  ARCH=arm64
  CC="$CC_BIN"
  CLANG_TRIPLE=aarch64-linux-gnu-
  CROSS_COMPILE=aarch64-linux-gnu-
  CROSS_COMPILE_ARM32=arm-linux-gnueabi-
)

if [ ! -d "$SRC" ]; then
  echo "══ 拉取源码 $UPSTREAM @ $UPSTREAM_REF ══"
  git clone --filter=blob:none "$UPSTREAM" "$SRC"
fi
git -C "$SRC" fetch --all --tags --quiet || true
git -C "$SRC" checkout "$UPSTREAM_REF"
echo "  commit = $(git -C "$SRC" rev-parse HEAD)"

[ -f "$CFG" ] || { echo "✗ 找不到配置 $CFG" >&2; exit 2; }
cp -f "$CFG" "$SRC/arch/arm64/configs/polaris_ds_defconfig"

mkdir -p "$OUT"
echo "══ 配置 + 硬断言 ══"
make -C "$SRC" O="$PWD/$OUT" "${MAKE_ARGS[@]}" polaris_ds_defconfig
make -C "$SRC" O="$PWD/$OUT" "${MAKE_ARGS[@]}" olddefconfig

for k in NAMESPACES PID_NS UTS_NS IPC_NS POSIX_MQUEUE MODVERSIONS; do
  grep -q "^CONFIG_$k=y" "$OUT/.config" || { echo "✗ 缺少 CONFIG_$k=y" >&2; exit 1; }
  echo "  ✓ CONFIG_$k=y"
done
if grep -q '^CONFIG_SYSVIPC=y' "$OUT/.config"; then
  echo "✗ CONFIG_SYSVIPC 被打开 —— 它会往 struct task_struct 插字段 ⇒ kABI 破坏" >&2
  exit 1
fi
echo "  ✓ CONFIG_SYSVIPC 未开(kABI 红线守住)"
if awk 'NR>1681 && /CONFIG_POSIX_MQUEUE/ {f=1} END{exit !f}' "$SRC/include/linux/sched.h"; then
  echo "✗ POSIX_MQUEUE 影响 task_struct" >&2; exit 1
fi
echo "  ✓ POSIX_MQUEUE 只影响 struct user_struct"

echo "══ 编译 ($JOBS 并行, CC=$CC_BIN) ══"
make -C "$SRC" O="$PWD/$OUT" "${MAKE_ARGS[@]}" -j"$JOBS" Image.gz

echo "══ 内嵌 config 复核 ══"
"$SRC/scripts/extract-ikconfig" "$OUT/arch/arm64/boot/Image" \
  | grep -E '^CONFIG_(UTS_NS|PID_NS|IPC_NS|POSIX_MQUEUE|SYSVIPC|MODVERSIONS)='

echo "══ 产物 ══"
ls -la "$OUT/arch/arm64/boot/Image.gz"
md5sum "$OUT/arch/arm64/boot/Image.gz"
