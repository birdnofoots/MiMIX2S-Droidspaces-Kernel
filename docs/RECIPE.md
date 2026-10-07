# 完整可复现配方（polaris / MIX 2S）

本文是**逐条命令**的实录，从零到"手机上跑着完整 Linux + AI agent"。
所有 md5 都是真机实测值，可直接对账。

---

## 0. 前置

| 角色 | 说明 |
|---|---|
| 主机 | 任意 Linux x86_64（编译 + 打包 + 刷机）|
| 手机 | MIX 2S (polaris)，**必须已刷 LineageOS 22.2 (Android 15)**，已解锁 BL、已 root（Magisk v30.7）、已开 USB 调试 |
| 数据线 | 能稳定传输的线（刷机时 USB 掉线是最常见的失败原因）|

> ⚠️ **本配方与 LineageOS 绑定，不是通用配方。**
> 两处强依赖：
> - **配置基座**：§1 取的是**该机 LOS 的 `/proc/config.gz`**（驱动集合按 LOS 的 vendor 分区对齐）
> - **打包底板**：§4 用 LOS 的 `boot.img` 做底，产出的镜像**带 LOS 的 ramdisk**，
>   刷到 MIUI/其它 ROM 上必然起不来
>
> 换 ROM 时的做法：把这两处都换成新 ROM 的（新 ROM 的 `/proc/config.gz` + 新 ROM 的
> `boot.img`），其余流程一字不改。
>
> **为什么不能跨 ROM 直接用**：`boot.img` = 内核 + **那个 ROM 的 ramdisk**。
> 本配方是「保留底板 ramdisk、只换 kernel 段」，所以产物带的是底板的 ramdisk
> ⇒ 底板属于哪个 ROM，产物就只能刷在哪个 ROM 上。**内核思路通用，boot.img 不通用。**
>
> 要加的三项（`PID_NS` / `UTS_NS` / `POSIX_MQUEUE`+`IPC_NS`）与 ROM 无关，永远一样；
> 需要换的只有「配置基座」和「打包底板」两处。

确认设备当前确实在 LOS 上：

```bash
adb shell getprop ro.build.version.lineageos 2>/dev/null   # 有输出即 LOS
adb shell getprop ro.lineage.build.version
adb shell getprop ro.product.device                        # 必须是 polaris
```

```bash
export ANDROID_ADB_SERVER_PORT=5037
export ADB_VENDOR_KEYS=$HOME/.android/adbkey     # 不设会出现 unauthorized
adb devices -l                                   # 应看到 99704755 device product:lineage_polaris
```

> 若 `unauthorized`：手机屏幕上点"允许"，并勾选"一律允许使用这台计算机进行调试"。
> 若屏幕锁着点不到，可在已 root 的设备上直接操作弹窗（见 §7）。

---

## 1. 取得设备原厂配置（**整个方案的地基**）

```bash
adb shell 'su -c "zcat /proc/config.gz"' > configs/polaris-stock-device.config
wc -l configs/polaris-stock-device.config      # 5256
```

顺带记录设备事实（后面判 kABI 要用）：

```bash
adb shell 'su -c "
  echo 内核: \$(cat /proc/version)
  echo 模块数: \$(wc -l < /proc/modules)
  echo 可卸载模块数: \$(N=0; for m in /sys/module/*/; do [ -f \$m/refcnt ] && N=\$((N+1)); done; echo \$N)
  echo vendor .ko 数: \$(ls /vendor/lib/modules/*.ko 2>/dev/null | wc -l)
  ls /sys/module | grep -x wlan && echo \"wlan 是内建\"
"'
```

期望：**真模块数 = 0、vendor `.ko` 数 = 0、`wlan` 内建**
⇒ polaris 是纯内建内核 ⇒ kABI 风险在物理上无从生效。

---

## 2. 改配置：只加三样

需要的增量（`scripts/config` 比手写行安全）：

```bash
./scripts/config --file out/.config -e PID_NS -e UTS_NS -e POSIX_MQUEUE -e IPC_NS
make O=out ARCH=arm64 ... olddefconfig
```

**注意**：`IPC_NS` 依赖 `(SYSVIPC || POSIX_MQUEUE)`。只开 `POSIX_MQUEUE` 时
`olddefconfig` 会正确地保留它；若误开 `SYSVIPC` 则触碰 `task_struct` ⇒ 必须回退。
（这也是"上一版 v2 里 IPC_NS 没生效"的原因：当时依赖没满足，被静默关掉了。）

断言：

```bash
for k in PID_NS UTS_NS IPC_NS POSIX_MQUEUE MODVERSIONS; do
  grep -q "^CONFIG_$k=y" out/.config || echo "✗ 缺 $k"; done
grep -q '^CONFIG_SYSVIPC=y' out/.config && echo '✗ SYSVIPC 开了,危险'
awk 'NR>1681 && /CONFIG_POSIX_MQUEUE/' kernel/include/linux/sched.h   # 必须无输出
```

---

## 3. 编译

```bash
export PATH=$HOME/aosp-clang/bin:$PATH      # 或 CC_BIN=clang-11
make O=out ARCH=arm64 CC=clang CLANG_TRIPLE=aarch64-linux-gnu- \
     CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
     -j$(nproc) Image.gz
```

> `CONFIG_COMPAT=y`（原厂配置里有）要求 ARM32 交叉工具链。
> 没有 `arm-linux-gnueabi-gcc` 时可以造 wrapper 壳
> （`CC=clang --target=arm-linux-gnueabi`，`as` 壳需丢掉 `-E L`/`-EB`），
> 但 CI 里直接 `apt install gcc-arm-linux-gnueabi` 更省事。

**决定性验证** —— 从编好的 `Image` 里抽内嵌 config（不是看 `.config` 文件）：

```bash
./scripts/extract-ikconfig out/arch/arm64/boot/Image \
  | grep -E '^CONFIG_(UTS_NS|PID_NS|IPC_NS|POSIX_MQUEUE|SYSVIPC)='
```

内核身份用**版本串 `#N` + 构建时间**区分，例如：
`#1 04:16:38`(PID_NS) → `#2 04:26:46`(+UTS_NS) → `#3 04:56:48`(+POSIX_MQUEUE+IPC_NS)。

---

## 4. 打包成可刷镜像

底板 = 手机上的 `/data/local/tmp/boot-backup-magisk.img`（原厂 boot 分区 dump，
md5 `56485f0bafa7608be53841bb82d45fea`）。

```bash
bash scripts/pack-boot.sh out/arch/arm64/boot/Image.gz stock-boot.img boot-polaris.img ./magiskboot
```

三条命令的本质：

```
magiskboot unpack boot.img      # 拆出 kernel / kernel_dtb / ramdisk.cpio
cp Image.gz kernel              # ★ 换的是【裸 Image.gz】,不带 DTB
magiskboot repack boot.img      # magiskboot 把 kernel_dtb 原样拼回
```

必须断言：

| 断言 | 期望 |
|---|---|
| `KERNEL_DTB_SZ` | `11391708`（原厂 DTB 表大小，一字不改）|
| `KERNEL_SZ` | `len(Image.gz) + 11391708` |
| 产出大小 | `67108864` |

实测：本配方产出 md5 `86c8d35e7f7f8b248106dc60510431d1`，与真机刷入的那份**逐字节一致**。

### ⚠ 血泪坑：打包脚本里别写死文件名

我们曾因为 `pack2.sh` 里硬编码 `cp Image.gz-new kernel`（那是 v1 的文件名），
导致 v2 的内核**从未被打包**，白刷一轮、白查半天。
⇒ **一律显式传参 + 每次核对 `#N` 与构建时间。**

---

## 5. 刷入（A-only，先 RAM 试启）

```bash
pkill -f '[p]olaris-fastboot-watch'      # ★ 先杀掉"一见 fastboot 就刷原厂"的守望
adb reboot bootloader
fastboot devices
fastboot boot  boot-polaris.img          # RAM 试启动,不写 flash ⇒ 失败自动回落旧内核
# 起来后验证:
adb shell 'cat /proc/version'            # 期望 #3 那版的构建时间
adb shell 'su -c "ls /proc/self/ns/"'    # 期望 cgroup ipc mnt net pid uts
# 确认无误再固化:
adb reboot bootloader
fastboot flash boot boot-polaris.img
fastboot reboot
```

---

## 6. 验收

```bash
bash scripts/verify-polaris.sh
```

期望要点：

| 项 | 期望 |
|---|---|
| `ro.product.device` | `polaris` |
| `/proc/self/ns/` | `cgroup ipc mnt net pid uts` |
| `battery` | `status=Charging`（别让手机掉电）|
| 输入设备 | 含 `synaptics_dsx`（触屏）|
| `/proc/modules` | 空（纯内建）|
| `droidspaces check` | 所有 `[MUST HAVE]` 全绿（含 IPC namespace）|

---

## 7. droidspaces + rootfs + AI agent

### 7.1 起容器

```sh
su -c 'mkdir -p /data/droidspaces/ubuntu'
su -c 'cd /data/local/tmp && curl -L -o ub.tar.gz \
   https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.5-base-arm64.tar.gz'
su -c 'tar -xzf /data/local/tmp/ub.tar.gz -C /data/droidspaces/ubuntu'      # 105M
su -c 'printf "#!/bin/sh\nwhile :; do sleep 3600; done\n" > /data/droidspaces/ubuntu/sbin/ds-init; chmod 755 /data/droidspaces/ubuntu/sbin/ds-init'
su -c '/data/local/tmp/droidspaces --name=ubuntu --rootfs=/data/droidspaces/ubuntu \
       --hostname=ubuntu --net=host --init=/sbin/ds-init start'
```

**坑**：`--net=nat` 会 `[FATAL: NAT NETWORKING UNSUPPORTED] CONFIG_VETH not enabled`。
本内核未开 VETH/BRIDGE ⇒ 用 `--net=host`（对 agent 反而更好）。

### 7.2 容器内修网络（否则 apt 全废）

```sh
# 容器内: /bin/sh /root/00-netfix.sh     （见 container/00-netfix.sh）
```
四层坑与对策：

| 症状 | 根因 | 对策 |
|---|---|---|
| `Temporary failure resolving` | 只解析到 **AAAA/IPv6**，手机无 IPv6 出口 | `gai.conf` 偏好 IPv4 + `Acquire::ForceIPv4` |
| `Could not resolve` | **`_apt`(uid 42) 被 Android per-UID 路由拦**（root 通）| `APT::Sandbox::User "root";` |
| `certificate is NOT trusted` | 缺 ca-certificates 却用 https | 源改 http（ubuntu-ports 换阿里云更快）|
| `Release file is not valid yet` | **手机时钟慢 5.5 天** | `Acquire::Check-Date "false";` + 设时钟 |

设时钟（toybox 格式是 `MMDDhhmmCCYY`，**不是** `CCYYMMDDhhmm`）：

```sh
su -c 'setenforce 0; date -u 100621052026; setenforce 1; date -u'
```

### 7.3 装 systemd 与工具链

```sh
# 容器内: /bin/sh /root/01-setup.sh
apt-get install -y --no-install-recommends \
  ca-certificates systemd systemd-sysv dbus curl wget git \
  python3 python3-pip python3-venv sudo less nano procps \
  iproute2 iputils-ping kmod locales tzdata
```
装完把 init 从自举的 `/sbin/ds-init` 切成 `/sbin/init`（systemd）：
```
su -c 'droidspaces --name=ubuntu stop'
su -c 'droidspaces --name=ubuntu --rootfs=/data/droidspaces/ubuntu --hostname=ubuntu \
       --net=host --init=/sbin/init start'
su -c 'droidspaces --name=ubuntu run /bin/systemctl is-system-running'   # 期望 running
```

### 7.4 装 AI agent

```sh
# 容器内: /bin/sh /root/02-agents.sh
curl -fsSL https://deb.nodesource.com/setup_22.x | sh -      # Node 22
apt-get install -y nodejs
npm install -g @anthropic-ai/claude-code @google/gemini-cli @openai/codex
claude --version   # 2.1.292
gemini --version   # 0.63.0
codex  --version   # codex-cli 0.160.1
```

> 实际调用各 API 还需要各自的 key（`ANTHROPIC_API_KEY` / `GEMINI_API_KEY` / `OPENAI_API_KEY`）。

### 7.5 SSH 与开机自启

```sh
# 容器内
apt-get install -y openssh-server && ssh-keygen -A
mkdir -p /root/.ssh && chmod 700 /root/.ssh
echo '<你的公钥>' >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
# 手机侧:让容器开机自启
cat > /data/adb/service.d/50-droidspaces-ubuntu.sh <<'EOF'
#!/system/bin/sh
( i=0; while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 150 ]; do sleep 4; i=$((i+1)); done
  sleep 20
  /data/local/tmp/droidspaces --name=ubuntu --rootfs=/data/droidspaces/ubuntu \
    --hostname=ubuntu --net=host --init=/sbin/init start >> /data/local/tmp/ds-boot.log 2>&1 ) &
EOF
chmod 755 /data/adb/service.d/50-droidspaces-ubuntu.sh
```
之后 `ssh root@<手机IP>` 即可（`--net=host` ⇒ 容器直接用手机 IP）。

---

## 8. 不开锁屏也能授权 adb（远程/无人值守场景）

问题：`允许 USB 调试吗？` 弹窗在锁屏下点不到，而客户端重试很快，
每次重连都产生新 transport，等 `uiautomator dump`（1~2 秒）再点就已经
`authorization received for deleted transport (N), ignoring`。

有效做法：

```sh
# 1) 用 uiautomator 拿到弹窗层级,确认坐标
su -c 'uiautomator dump /data/local/tmp/ui.xml; cat /data/local/tmp/ui.xml' | tr '>' '>\n' \
  | grep -oE 'text="[^"]*"[^>]*bounds="[^"]*"'
#    典型布局: 勾选框[110,1083][968,1171]  允许[800,1226][976,1375]
# 2) ★ 快速盲点循环(每秒一轮),抢在 transport 存活窗口内点中
su -c 'n=0; while [ $n -lt 35 ]; do
         if dumpsys window | grep -q UsbDebuggingActivity; then
           input tap 539 1127; input tap 888 1300; fi
         n=$((n+1)); sleep 1; done'
# 3) 成功标志:adbd 日志里 authorized 之后【不再紧跟 prompting】
su -c 'logcat -d -b all -v time | grep adbd | grep -iE "authorized|prompting" | tail -6'
```

指纹核对（弹窗显示的 MD5 vs `adb_keys` 各行）：

```sh
awk '{print $1}' /data/misc/adb/adb_keys | while read k; do
  echo "$k" | base64 -d | md5sum | cut -c1-32 | sed 's/\(..\)/\1:/g; s/:$//' | tr 'a-f' 'A-F'
done
```

配套加固：

```sh
su -c 'settings put global adb_allowed_connection_timeout 0'   # 对应"停用 ADB 授权超时"
```

---

## 9. 操作铁律（都踩过）

1. **`pkill -f` 会自杀**（远程命令里含同样的字面量）⇒ 用方括号模式 `[m]ars-when-online` 或按 PID
2. **`su -c "内层带单引号"` 一定被吃** ⇒ 一律 push 脚本文件再 `sh /path/x.sh`
3. **adb server 端口会漂**（5037/5038/…）⇒ 连不上先扫端口
4. **跨主机拷贝用一台中转**，且**每跳核对大小 + md5**（曾出现中转副本被截断成 28.8MB）
5. 刷机前**杀 fastboot 守望**；`fastboot boot` 先用
6. **`fastboot flash` 报 `waiting for any device` = 没刷上**，别当成功
7. 改正在运行的 bash 脚本会把执行搞坏（`syntax error`）⇒ 先 kill 再替换
8. `screencap` 全黑不可信；判"进系统"要用 `boot_completed=1` + 核对 `/proc/version` + **截图看图**
