# Xiaomi MIX 2S (polaris) — Droidspaces 容器内核

给 **小米 MIX 2S / SDM845 / LineageOS 22.2 (Android 15)** 自编的、带 **Droidspaces 容器运行时**
所需完整命名空间的内核。目标：把手机变成一台**能跑完整 Linux 发行版 + AI agent** 的机器。

本仓库是 **真机验证通过** 的配方 + 全自动 CI，不是试验品。

---

## 一、最终成果（真机实测）

| 项 | 值 |
|---|---|
| 容器 | **Ubuntu 24.04.5 LTS**（droidspaces 6.6.0），systemd 255 接管，开机自启 |
| 内核 | `4.9.337-perf-gaa8adfe9bf21-dirty #3 SMP PREEMPT Wed Oct 7 04:56:48 HKT 2026` |
| 命名空间 | `cgroup ipc mnt net pid uts` —— **六项全开** |
| 系统内 | Python 3.12.3 · Node v22.23.3 · npm 10.9.9 · git 2.43.0 · sshd |
| AI agent | `claude 2.1.292` · `gemini 0.63.0` · `codex-cli 0.160.1` |
| 网络 | `--net=host`，容器直接用手机 WiFi IP；可从局域网 SSH 直连 |
| 自启 | `/data/adb/service.d/50-droidspaces-ubuntu.sh`（真实重启验证 ✓） |

> 手机侧还装着 **易控车机版 (Easycontrol_For_Car)**，配合 Tailscale 可远程镜像屏幕。

---

## 二、已验证的产物（真机刷入并截图确认）

| 文件 | 大小 | md5 |
|---|---|---|
| `polaris-v3-boot.img` | 67,108,864 | `86c8d35e7f7f8b248106dc60510431d1` |
| `polaris-v3-Image.gz` | 13,742,128 | `c7a5e9ee6efa5449039b9d1f14151e72` |
| `polaris-stock-boot-base.img`（打包底板） | 67,108,864 | `56485f0bafa7608be53841bb82d45fea` |
| `magiskboot-x86_64`（Magisk v30.7） | 943,848 | `b1d2597e73fe9b44be87600e2c041116` |

**可复现性已证明**：用 `magiskboot-x86_64` + `polaris-stock-boot-base.img` + `polaris-v3-Image.gz`
跑本仓库的 `scripts/pack-boot.sh`，产出的 `boot.img` 与真机刷入的那份 **md5 逐字节一致**
（`86c8d35e…`）。

> 这三个大文件放在本仓库的 **Release `assets-v1`** 里（仓库正文不塞二进制）。

---

## 三、快速开始

### 1) 编译（可不依赖 CI，本地跑同一条命令）

```bash
sudo apt-get install -y bc bison build-essential flex libssl-dev libelf-dev \
     cpio zip unzip python3 curl git clang-11 llvm-11 \
     gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi

# 默认:LineageOS lineage-22.2 @ aa8adfe9bf212c6e93238a86980b4024da4f819a
bash scripts/build-kernel.sh configs/polaris-v3.config out kernel
```

### 2) 打包成可刷镜像

```bash
curl -L -o magiskboot  <release>/magiskboot-x86_64
curl -L -o stock.img   <release>/polaris-stock-boot-base.img
chmod +x magiskboot
bash scripts/pack-boot.sh out/arch/arm64/boot/Image.gz stock.img boot-polaris.img ./magiskboot
```

### 3) 刷入（**先 RAM 试启动，再固化**）

```bash
bash scripts/flash-polaris.sh ram   boot-polaris.img   # fastboot boot，不写 flash，零风险
bash scripts/flash-polaris.sh flash boot-polaris.img   # 确认无误后固化
bash scripts/verify-polaris.sh                          # 一键验收
```

### 4) 用 CI 编

GitHub → Actions → **Build polaris (MIX 2S) Droidspaces kernel** → Run workflow。
可传 `upstream` / `upstream_ref` / `config` / `pack` / `toolchain`；产物里直接含
`boot-polaris.img`。

---

## 四、五个关键设计决策（都是踩过坑换来的）

### ① 基座必须用**设备自己的 `/proc/config.gz`**

`configs/polaris-stock-device.config` 就是它（5256 项）。
若改用 `sdm845-perf_defconfig` 之类，会引入 **690 项差异**，其中
`CONFIG_MODULE_SIG_FORCE=y`、`CONFIG_PSI=n`、`CONFIG_SYSVIPC=y`/`POSIX_MQUEUE=y`
会让内核直接起不来。**只做加法，不做减法。**

### ② `CONFIG_IPC_NS` 只能靠 `POSIX_MQUEUE`，绝不能开 `SYSVIPC`

Droidspaces 把 IPC namespace 列为 **[MUST HAVE]**，`check` 只警告但 `start` 硬拒。
而 `IPC_NS` 依赖 `(SYSVIPC || POSIX_MQUEUE)`，两者对 kABI 的影响天差地别：

```
include/linux/sched.h:938   struct user_struct {
                  :952   #ifdef CONFIG_POSIX_MQUEUE
                  :954       unsigned long mq_bytes;      ← 只动 user_struct ✓
include/linux/sched.h:1681  struct task_struct {
                  :1907  #ifdef CONFIG_SYSVIPC
                  :1909      struct sysv_sem sysvsem;     ← 会往 task_struct 插 ✗
                  :1910      struct sysv_shm sysvshm;
```

- `POSIX_MQUEUE` 加的 `mq_bytes` 落在 **`struct user_struct`**（堆分配，驱动不碰）⇒ **零 kABI 风险**
- `SYSVIPC` 会往 `struct task_struct` 插 24 字节 ⇒ 其后所有字段位移 ⇒ 破坏 kABI

⇒ 只开 `POSIX_MQUEUE`。CI 里对此有**硬断言**（`SYSVIPC is not set` + `sched.h` 行号检查）。

> 补充：polaris 是**纯内建（monolithic）内核**，`/proc/modules` 为空、可卸载模块数为 0、
> `/vendor/lib/modules/*.ko` 为 0，`wlan` 在 `/sys/module` 里内建。所以 kABI 在物理上
> 也无从生效 —— 但上面的结构分析仍然是必须守住的底线。

### ③ 打包必须**保 DTB 段**

`boot.img` 里 kernel 段 = `内核 Image` + **11,391,708 字节 DTB 表**。打包时把 `kernel`
换成**裸 `Image.gz`**，让 `magiskboot repack` 把原 `kernel_dtb` 原样拼回。
`KERNEL_DTB_SZ` 必须仍是 `11391708` —— `scripts/pack-boot.sh` 会断言这一点。

### ④ `--net=nat` 需要 `CONFIG_VETH`/`CONFIG_BRIDGE`，本内核未开 ⇒ 用 `--net=host`

对跑 AI agent 而言 host 模式反而更好：无 NAT 开销、容器直接拿手机 IP、局域网可 SSH 直连。
（想用 NAT 需另编 `CONFIG_VETH=y` + `CONFIG_BRIDGE=y`。）

### ⑤ A-only 单槽 ⇒ 刷机一律 **先 `fastboot boot` 再 `fastboot flash`**

polaris 没有 A/B 回退。`fastboot boot` 把镜像载入内存启动、**不写 flash**，
失败就自然回落到 flash 里的旧内核，是零风险验证手段。

---

## 五、容器侧：把 Ubuntu 变成能干活的完整 Linux

`container/` 下三个脚本按顺序在容器内执行（用 `droidspaces run /bin/sh /root/xx.sh`）：

| 脚本 | 作用 | 为什么需要 |
|---|---|---|
| `00-netfix.sh` | 时钟 / IPv4 偏好 / apt 源 / 关 apt 沙箱 / 关 Release 日期校验 | 见下 |
| `01-setup.sh` | 装 systemd + Python + git + curl 等工具链 | |
| `02-agents.sh` | Node 22 + `claude` / `gemini` / `codex` CLI | |

容器内 apt 有**四层坑**，`00-netfix.sh` 一次解决：

1. **只拿到 IPv6** ⇒ `Temporary failure resolving`：容器解析只有 AAAA，手机无 IPv6 出口
   ⇒ `/etc/gai.conf` 偏好 IPv4 + `Acquire::ForceIPv4`
2. **`_apt`(uid 42) 被 Android per-UID 路由拦** ⇒ `Could not resolve`
   ⇒ `APT::Sandbox::User "root";`
3. **缺 ca-certificates 却用 https** ⇒ `certificate is NOT trusted` ⇒ 改用 http 源
4. **手机时钟慢 5.5 天** ⇒ `Release file is not valid yet` ⇒ `Acquire::Check-Date "false";`
   （另可用 toybox 格式 `MMDDhhmmCCYY` 硬设时钟：`date -u 100621052026`）

---

## 六、安装 droidspaces 与 rootfs

```sh
# 手机侧(root)
su -c 'mkdir -p /data/droidspaces/ubuntu'
su -c 'cd /data/local/tmp && curl -L -o ub.tar.gz \
  https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.5-base-arm64.tar.gz'
su -c 'tar -xzf /data/local/tmp/ub.tar.gz -C /data/droidspaces/ubuntu'
# ubuntu-base 没有 /sbin/init ⇒ 先放一个自举 init,装完 systemd 再切成 /sbin/init
su -c 'printf "#!/bin/sh\nwhile :; do sleep 3600; done\n" > /data/droidspaces/ubuntu/sbin/ds-init; chmod 755 /data/droidspaces/ubuntu/sbin/ds-init'
su -c '/data/local/tmp/droidspaces --name=ubuntu --rootfs=/data/droidspaces/ubuntu \
        --hostname=ubuntu --net=host --init=/sbin/ds-init start'
```

开机自启：`/data/adb/service.d/50-droidspaces-ubuntu.sh`（等 `sys.boot_completed` 后拉起）。

---

## 七、仓库结构

```
.github/workflows/build-kernel.yml   CI:拉源码 → 配置(+硬断言) → 编译 → 打包 → 产物
configs/polaris-stock-device.config  设备原厂 /proc/config.gz(基座基线)
configs/polaris-v3.config            真机验证过的配置(基座 + PID_NS/UTS_NS/POSIX_MQUEUE/IPC_NS)
scripts/build-kernel.sh              本地/CI 通用编译
scripts/pack-boot.sh                 打包(带 DTB 断言),已证明可逐字节复现
scripts/flash-polaris.sh             fastboot boot / flash / verify
scripts/verify-polaris.sh            一键验收清单
container/00-netfix.sh               容器内 apt/网络/时钟修复
container/01-setup.sh                容器内 systemd + 工具链
container/02-agents.sh               容器内 Node 22 + AI agent CLI
container/probe.sh / verify.sh       容器内自检
docs/RECIPE.md                       完整可复现配方(含所有命令与踩坑)
docs/polaris-status-20261007.md      成功报告全文
```

---

## 八、环境备忘

- 构建机无需特殊硬件；CI 用 `ubuntu-22.04` + `clang-11`
- **本地真机验证时用的是 AOSP clang r383902b1 (clang 11.0.2)**。
  CI 默认用 apt 的 `clang-11` (11.1.0)，**产物非逐字节相同但功能等价**；
  要完全一致请把 `toolchain` 选成 `aosp-clang-r383902b`
- `adb` 侧注意：多 adb server 端口会漂（5037/5038/…），连不上时先扫端口；
  用 `ADB_VENDOR_KEYS=$HOME/.android/adbkey`，否则设备显示 `unauthorized`
- 建议 `settings put global adb_allowed_connection_timeout 0`（否则 adb 授权 7 天后过期）
- 准备进 `fastboot` 前，**先杀掉本机所有"一见 fastboot 就刷机"的守望脚本**

## 九、许可

内核源码来自 LineageOS（GPL-2.0）；本仓库的脚本与文档可自由使用。
`magiskboot` 来自 [Magisk](https://github.com/topjohnwu/Magisk)（GPL-3.0）。
