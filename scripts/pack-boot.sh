#!/usr/bin/env bash
# =============================================================================
#  pack-boot.sh —— 把新编译的 Image.gz 塞进原厂 boot.img
#
#  为什么必须这么做(而不是 mkbootimg 从头造):
#    polaris 的 boot 分区里除了 kernel/ramdisk,还跟着一块 11,391,708 字节的
#    DTB 表,以及紧随其后的 AVB0 vbmeta 结构与分区尾部的 AVBf footer。
#    从头 mkbootimg 会丢掉这些 ⇒ 起不来。正确做法是【原样保留、只换 kernel】。
#
#  配方(与真机验证过的完全一致):
#    cp 原厂boot.img boot.img
#    magiskboot unpack boot.img
#    cp Image.gz kernel          # 注意:换进去的是【裸 Image.gz】,不带 DTB
#    magiskboot repack boot.img  # magiskboot 会把 kernel_dtb 原样拼回
#
#  已验证:本脚本 + Magisk v30.7 的 x86_64 magiskboot,产出与真机刷入的
#          polaris-v3-boot.img 逐字节一致 (md5 86c8d35e7f7f8b248106dc60510431d1)
#
#  用法: pack-boot.sh <Image.gz> <原厂boot.img> <输出boot.img> [magiskboot]
# =============================================================================
set -euo pipefail

IMG=$(realpath "${1:?用法: pack-boot.sh <Image.gz> <原厂boot.img> <输出boot.img> [magiskboot]}")
BASE=$(realpath "${2:?缺少原厂 boot.img}")
OUT=$(realpath -m "${3:?缺少输出路径}")
MB=$(realpath "${4:-./magiskboot}")

EXPECT_DTB="${EXPECT_DTB:-11391708}"   # polaris 原厂 DTB 表大小,勿改
EXPECT_SIZE="${EXPECT_SIZE:-67108864}" # 64 MiB 分区

[ -x "$MB" ]   || { echo "✗ magiskboot 不可执行: $MB" >&2; exit 2; }
[ -f "$IMG" ]  || { echo "✗ 找不到 Image.gz: $IMG" >&2; exit 2; }
[ -f "$BASE" ] || { echo "✗ 找不到原厂底板: $BASE" >&2; exit 2; }
mkdir -p "$(dirname "$OUT")"

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cd "$W"

echo "══ 输入 ══"
echo "  Image.gz : $IMG  ($(stat -c %s "$IMG") B, md5 $(md5sum "$IMG" | cut -c1-32))"
echo "  底板     : $BASE  ($(stat -c %s "$BASE") B, md5 $(md5sum "$BASE" | cut -c1-32))"
echo "  magiskboot: $MB"

echo "══ 1/5 unpack ══"
cp -f "$BASE" boot.img
"$MB" unpack boot.img 2>&1 | tee unpack.log
echo "  kernel=$(stat -c %s kernel 2>/dev/null) kernel_dtb=$(stat -c %s kernel_dtb 2>/dev/null) ramdisk=$(stat -c %s ramdisk.cpio 2>/dev/null)"

echo "══ 2/5 用新内核替换(裸 Image.gz,不带 DTB) ══"
cp -f "$IMG" kernel
ls -la kernel

echo "══ 3/5 repack ══"
"$MB" repack boot.img 2>&1 | tee repack.log

echo "══ 4/5 断言 ══"
# ★ 坑:magiskboot 只在 unpack 输出里打 KERNEL_DTB_SZ,repack 输出里【没有】这一行。
#   曾经只读 repack.log ⇒ 解析出空值 ⇒ 误报 "DTB 段被破坏" 而拒绝产出(内核其实是好的)。
NEW_DTB=$(grep -h 'KERNEL_DTB_SZ' unpack.log repack.log 2>/dev/null | tail -1 | tr -dc '0-9')
NEW_KSZ=$(grep -h 'KERNEL_SZ' repack.log 2>/dev/null | tail -1 | tr -dc '0-9')
echo "  KERNEL_SZ     = $NEW_KSZ"
echo "  KERNEL_DTB_SZ = $NEW_DTB  (期望 $EXPECT_DTB)"

[ -n "$NEW_DTB" ] || { echo "✗ 解析不出 KERNEL_DTB_SZ,拒绝产出" >&2; exit 3; }
[ "$NEW_DTB" = "$EXPECT_DTB" ] || { echo "✗ KERNEL_DTB_SZ 变了!DTB 段被破坏,拒绝产出" >&2; exit 3; }
[ -n "$NEW_KSZ" ] || { echo "✗ 解析不出 KERNEL_SZ,拒绝产出" >&2; exit 3; }
EXPECT_KSZ=$(( $(stat -c %s "$IMG") + EXPECT_DTB ))
[ "$NEW_KSZ" = "$EXPECT_KSZ" ] || { echo "✗ KERNEL_SZ=$NEW_KSZ != Image.gz+DTB=$EXPECT_KSZ" >&2; exit 3; }

# ★ 与 magiskboot 输出格式无关的结构性校验:
#   把【产出镜像】再解包一次,DTB 段必须与原厂底板里的 kernel_dtb 逐字节相同。
mkdir -p chk && ( cd chk && cp -f ../new-boot.img . && "$MB" unpack new-boot.img >/dev/null 2>&1 )
if [ -f chk/kernel_dtb ] && cmp -s chk/kernel_dtb kernel_dtb; then
  echo "  ✓ 产出镜像的 DTB 段与原厂逐字节相同 ($(stat -c %s chk/kernel_dtb) B)"
else
  echo "✗ 产出镜像的 DTB 段与原厂不一致,拒绝产出" >&2; exit 3
fi

SZ=$(stat -c %s new-boot.img)
[ "$SZ" = "$EXPECT_SIZE" ] || { echo "✗ 产出大小 $SZ != $EXPECT_SIZE" >&2; exit 3; }
echo "  ✓ DTB 完好 / 大小正确"

echo "══ 5/5 产出 ══"
cp -f new-boot.img "$OUT"
ls -la "$OUT"
md5sum "$OUT" | tee "$OUT.md5"
echo "✓ 完成。刷入前请用 fastboot boot 先做 RAM 试启动(见 scripts/flash-polaris.sh)"
