# polaris = 一台完整的 Linux 手机 ✅ 最终报告（2026-10-07 05:3x）

## 一、结论

**polaris（小米 MIX 2S / SDM845 / LOS 22.2 / Android 15）已经成为一台可通过 SSH 登录的完整 Linux 机器，
里面装好了各种 AI agent CLI。全程零物理按键、纯远程完成，每一步都有命令输出或截图佐证。**

```
硬件:      MIX 2S, 6 核, 7.6 GB RAM, /data 224G(用 5.2G)
内核:      Linux 4.9.337-perf-gaa8adfe9bf21-dirty #3 SMP PREEMPT Wed Oct 7 04:56:48 HKT 2026 aarch64
           （自编，PID/UTS/IPC/Mount/Net/Cgroup 六种 namespace 全开）
宿主:      LineageOS 22.2 (Android 15) + Magisk root, WiFi 192.168.1.189, 电池 Charging/100%/Good
容器:      Ubuntu 24.04.5 LTS (droidspaces 6.6.0), systemd 255 已接管, 开机自动启动
系统内:    Python 3.12.3 · Node v22.23.3 · npm 10.9.9 · git 2.43.0 · systemd 255 · sshd
AI agent:  claude 2.1.292 (Claude Code) · gemini 0.63.0 · codex-cli 0.160.1
```

## 二、怎么用（从局域网任意机器）

```bash
ssh -i <私钥> root@192.168.1.189            # 直接进容器(Ubuntu)，systemd 环境
```

在手机本机（Android 侧）操作容器：

```bash
DS=/data/local/tmp/droidspaces
su -c "$DS --name=ubuntu enter"                       # 交互式进入
su -c "$DS --name=ubuntu run <cmd> [args]"            # 跑单条命令
su -c "$DS show"                                      # 列出容器
su -c "$DS --name=ubuntu stop"                        # 停止
su -c "$DS --name=ubuntu --rootfs=/data/droidspaces/ubuntu \
        --hostname=ubuntu --net=host --init=/sbin/init start"   # 手动启动
```

- **开机自启**：`/data/adb/service.d/50-droidspaces-ubuntu.sh`（等 `sys.boot_completed` 后 20s 拉起，日志在 `/data/local/tmp/ds-boot.log`）
- **WiFi adb**：`/data/adb/post-fs-data.d/99-adb-5555.sh` → `192.168.1.189:5555`
- **网络模式**是 `--net=host`（共享手机 WiFi）。想要隔离/端口转发需重编 v4 加 `CONFIG_VETH=y`+`CONFIG_BRIDGE=y`

## 三、内核血缘与可复现配方

base = **设备自己的 `/proc/config.gz`**（这就是 WiFi/触屏/电源链全部完好的原因），只做加法：

| 版本 | 构建 | 增量 | 结果 |
|---|---|---|---|
| v1 | `#1 04:16:38` | `PID_NS` | 刷入✓ |
| v2 | `#2 04:26:46` | `+ UTS_NS` | 刷入✓ `ns` 出现 `uts` |
| **v3** | `#3 04:56:48` | `+ POSIX_MQUEUE + IPC_NS` | **已固化 ✓ 重启后复验 ✓** |

编译（149 上）：

```bash
cd ~/polaris-kernel-build/android_kernel_xiaomi_sdm845
export PATH=$HOME/arm32wrap:$HOME/aosp-clang/bin:$PATH
./scripts/config --file out/.config -e POSIX_MQUEUE -e IPC_NS -e UTS_NS -e PID_NS
make O=out ARCH=arm64 CC=clang CLANG_TRIPLE=aarch64-linux-gnu- \
     CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- olddefconfig
make O=out ARCH=arm64 CC=clang CLANG_TRIPLE=aarch64-linux-gnu- \
     CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- -j4 Image.gz
# 硬断言：从编好的 Image 里抽内嵌 config
scripts/extract-ikconfig out/arch/arm64/boot/Image | grep -E 'CONFIG_(UTS_NS|IPC_NS|POSIX_MQUEUE|SYSVIPC)'
```

打包（手机上，`magiskboot` 在 `/data/adb/magisk/magiskboot`）：

```sh
cp /data/local/tmp/boot-backup-magisk.img boot.img   # 64MB 底板, md5 56485f0bafa7608be53841bb82d45fea
magiskboot unpack boot.img
cp /data/local/tmp/Image-v3 kernel                   # 裸 Image.gz，不带 DTB
magiskboot repack boot.img                           # → new-boot.img
# KERNEL_DTB_SZ 必须仍是 11391708
```

刷写（**推荐先 RAM 试启动**）：

```bash
pkill -f polaris-fastboot-watch      # ★必须先杀，否则它一见 fastboot 就刷回原厂
adb reboot bootloader
fastboot boot /tmp/polaris-v3-boot.img    # RAM 试启动，不写 flash，零风险
fastboot flash boot /tmp/polaris-v3-boot.img   # 确认没问题再固化
fastboot reboot
```

## 四、五个坑的根因（这是本次真正花时间的地方）

| # | 症状 | 根因 | 解法 |
|---|---|---|---|
| 1 | v2「刷了没生效」，跑的仍是 v1 | `pack2.sh` 里**硬编码** `cp Image.gz-new kernel`（v1 的文件名）；v2 被推成 `Image-v2` 从未打包 | 改成显式传参 + 每次核对 `#N` 与构建时间 |
| 2 | `droidspaces check` exit=0 但 `start` 硬拒 `Missing 1 required feature(s)` | `check` 只警告，`start` 才强制；缺 IPC namespace | 开 `IPC_NS`（依赖 `SYSVIPC∥POSIX_MQUEUE`） |
| 3 | 开 `SYSVIPC` 会不会破 kABI？ | 源码：`mq_bytes` 在 `struct user_struct`(sched.h:938-955)；`sysvsem/sysvshm` 才在 `struct task_struct`(1681+, 1907) | **只开 `POSIX_MQUEUE`，坚决不开 `SYSVIPC`** ⇒ `task_struct` 零变化；且 polaris 无任何可加载 `.ko`(refcnt=0)，kABI 物理上无从生效 |
| 4 | `--net=nat` → `[FATAL] CONFIG_VETH not enabled` | 内核无 VETH/BRIDGE | 改 `--net=host`（对 agent 反而更好：无 NAT 开销，SSH 直接可达） |
| 5 | 容器内 apt 三连败：`Temporary failure resolving` → `Could not resolve` → `certificate NOT trusted` | ① 只拿到 AAAA/IPv6，手机无 IPv6 出口；② `_apt`(uid 42) 被 **Android per-UID 路由**拦（root 通）；③ 缺 ca-certificates 却用 https；④ 手机时钟慢 5.5 天致 Release 文件"尚未生效" | `gai.conf` 偏好 IPv4 + `Acquire::ForceIPv4`；`APT::Sandbox::User "root"`；换 http 阿里云 `ubuntu-ports` 源；`Acquire::Check-Date "false"` + 用 toybox 格式 `MMDDhhmmCCYY` 设时钟 |

## 五、归档位置（三处 md5 已核对一致）

| 文件 | 大小 | md5 |
|---|---|---|
| `polaris-v3-boot.img` | 67,108,864 | `86c8d35e7f7f8b248106dc60510431d1` |
| `polaris-v3-Image.gz` | 13,742,128 | `c7a5e9ee6efa5449039b9d1f14151e72` |
| `polaris-v3.config` | 139,207 | `b5bc83ecafda6ad6224e7aa5a6f7f6e7` |

存放于：**81** `~/mars/polaris/` · **149** `/tmp/` · **手机** `/data/local/tmp/pb3/` 与 `/sdcard/`

回滚镜像（手机上）：
- v2 `/data/local/tmp/pb2/new-boot.img` md5 `05da865e630981661e48f79a515d8663`
- v1 `/data/local/tmp/boot-before-uts.img` md5 `5b0060fd9716ef309935a829616501f6`

## 六、踩过的操作坑（避免重犯）

- **adb server 端口会漂**（149 上有 5037/5038/5039/5043…），设备可能落在任意一个；且 149 上**必须** `ADB_VENDOR_KEYS=$HOME/.android/adbkey`，否则 `unauthorized`
- **`su -c "内层带单引号"` 一定被吃**（本会话犯了 3 次）⇒ 一律**推脚本文件**再 `sh /path/x.sh`
- **`pkill -f` 会自杀**（`rec-tight`/`polaris-fastboot-watch`）⇒ 按 PID 杀或脚本文件内执行
- 跨主机拷贝：**必须用工作机中转**（149 对 81 没有免密）；每跳都核对大小+md5（本会话有一次中转副本被截断成 28.8MB）
- 截图命令：`adb -s 99704755 exec-out screencap -p > x.png`

## 七、mars 状态：**卡住，等你回家物理操作**

| 检查 | 结果 |
|---|---|
| 81 的 USB 总线 | 只有两个 root hub ⇒ mars 完全没枚举 ✗ |
| `fastboot devices` / 局域网 `:5555` / 旧 WiFi IP `192.168.1.145` | 全空 / 只有 polaris / `No route to host` ✗ |
| xHCI `0000:00:15.0` unbind-bind | 无效 ✗ |
| `rec-tight-81.sh` 救援守望 | 在跑但什么都没抓到 |

推断：mars 现在刷的是 F39 血统镜像 —— ADSP 未起 → 无充电 PD → `power_supply` 缺失 → framework 永不完成
→ hw watchdog ~55s 复位；`configfs-gadget: failed to start g1: -19` / `UDC: No such device`
⇒ USB 设备控制器未注册 ⇒ 总线上永远看不到它，连 adb 的机会都没有。

**你回家后**：① 先试拔插 USB；② 不行就**按住 音量下 + 电源 ~10 秒进 FASTBOOT**，81 上 `rec-tight-81.sh` 会自动刷 `golden-80m` 救机，然后我接手续刷 F42。

⚠️ mars 镜像命名有坑：记录里"F42 md5 `fd528e55…`"实际对应 `/tmp/f40-boot.img`(02:56)；真正的 `/tmp/f42-boot.img`(03:55) 是 `f9de81d7f0b8002c75802e303bf5bee4`。刷前重新核验。
⚠️ 绝不动一加手机（`172.28.0.1:5555` 是宿主机）。

## 八、可选后续

- **agent 真正跑起来**：需 API key（`ANTHROPIC_API_KEY` / `GEMINI_API_KEY` / `OPENAI_API_KEY` 或交互式登录）
- **NAT 隔离 + 端口转发**：v4 加 `CONFIG_VETH=y` + `CONFIG_BRIDGE=y`
- **本地模型推理**：`--gpu` 需 `CONFIG_DEVTMPFS`；SDM845 的 Adreno 630 可跑小模型
- **非 root 用户**：容器内 `useradd -m -G sudo` 供 agent 使用
- **容器快照/备份**：rootfs 目前 1.9G，可 `tar` 存档

---

## 九、adb 远程授权 + 易控投屏（2026-10-07 06:0x）

### 需求
用户手机（`one@Aphone`）通过 **Tailscale** 连 polaris，用 **易控车机版 Easycontrol_For_Car**（fork: `birdnofoots/Easycontrol_For_Car`，上游 `eiyooooo`）镜像 polaris 屏幕。
App 前置：目标机 **5555 端口开** + **adb 授权**。

### 处置：不解锁手机，直接远程点掉授权弹窗

**为什么不能靠"抓 AUTH 包取公钥"**：tcpdump 能抓（容器里 `tcpdump 4.99.4` 可用，`-i any` 覆盖 lo/wlan0），但那个客户端是**快速重试**型 —— 每次重连都是新 transport，等 UI dump 完再点就已经 `authorization received for deleted transport (N), ignoring` ✗。

**有效的做法**：`uiautomator dump` 拿到弹窗层级后，**用 `input tap` 快速盲点循环**（布局稳定：勾选框 `539,1127`，允许 `888,1300`），每秒一轮抢在 transport 存活窗口内点中 ✓：
```
06:00:38.453  adb client 11 authorized     ← 后面不再跟 prompting，成功
```

**指纹核对**（弹窗 MD5 vs `adb_keys` 各行）：
```
行5 [one@Aphone] MD5 = 3A:BB:FE:AB:AD:BC:14:C1:6A:21:9C:4F:3D:6E:44:85
弹窗显示           = 3A:BB:FE:AB:AD:BC:14:C1:6A:21:9C:4F:3D:6E:44:85   ✓ 完全一致
```
算法：`awk '{print $1}' | base64 -d | md5sum | 每字节加冒号 | 大写`

### 配套加固

- **`settings put global adb_allowed_connection_timeout 0`** —— 对应 App 要求的"停用 ADB 授权超时"。原来该值是 `null`（默认 7 天过期），不设的话用户手机过几天又要重新授权 ✗
- `adb_keys` 现在 5 把：`justin@kali`(149) / `u0_a372@localhost`(polaris 本机 App) / **`one@Aphone`(用户手机)** / 2 把无注释遗留
- 5555 监听 `[::]:5555` ⇒ **全网卡**，Tailscale 的 100.x 或 MagicDNS 名字都能连 ✓（README 也支持 `域名:5555` 写法）
- 持久性：`adb_keys` 在 `/data` ✓；`service.adb.tcp.port=5555` 由 `/data/adb/post-fs-data.d/99-adb-5555.sh` 每次开机设置 ✓

### 实证：App 与 scrcpy 都跑通了

polaris 上被推入并运行中：
```
/data/local/tmp/easycontrol_for_car_server_10610.jar   (60483 B, V1.6.10)
shell 6259  app_process / top.eiyooooo.easycontrol.server.Server
shell 6273  app_process -Djava.class.path=...server_10610.jar ... Scrcpy mirrorMode=1
```
其自写日志 `/data/local/tmp/easycontrol_for_car_log`：
```
PHONE_INFO->{"Build.MODEL":"Mi MIX 2S","Build.DEVICE":"polaris","SDK_INT":35,"Build.HARDWARE":"qcom"}
onDisplayAdded invoked displayId:2 / 3
```

独立同机制验证（官方 scrcpy 4.1 走 TCP adb）：
```
adb connect 192.168.1.189:5555 → device ✓ ;  adb -s ... shell → uid=2000(shell) ✓
scrcpy -s 192.168.1.189:5555 --no-audio --time-limit=8 --record=/tmp/pol-mirror.mp4
  INFO: Texture: 1080x2160 → Recording complete   (820 KB)
```
抽帧即 polaris 的应用抽屉（见 `polaris-mirror-frame.png`）⇒ **采集/编码/控制全链路通** ✓

### 踩坑备忘

- Debian 的 `scrcpy` 包**不带服务端 jar**：需另下 `scrcpy-server-v4.1` 放到 `/usr/share/scrcpy/scrcpy-server`（且该目录需先 `mkdir -p`）
- 149 上 `sudo` 需密码（`gozilla`），用 `echo gozilla | sudo -S`
- ⚠️ **安全**：81 上 `Easycontrol_For_Car/.git/config` 的 remote URL 里**明文存了 GitHub 凭据**，建议改用 token + credential helper，并轮换该密码
