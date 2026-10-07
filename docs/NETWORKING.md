# Droidspaces 容器网络模式详解

`--net=` 有四种模式：**host / nat / none / gateway**。它们的区别只有一个根源问题：

> **容器是和宿主共用网络命名空间，还是自己开一个？**

答案不同，随之而来的是「容器能不能看到真实网卡」「有没有独立 IP」「要不要做端口映射」「两个容器会不会抢端口」全都不同。

---

## 一、一张表看懂

| 模式 | 网络命名空间 | 容器里看到的网卡 | 容器 IP | 能出网 | 宿主访问容器 | 局域网/Tailscale 访问容器 | 隔离性 | 需要的内核开关 |
|---|---|---|---|---|---|---|---|---|
| **`host`** | **与宿主共享同一个** | 手机所有真实网卡（`wlan0`、`rmnet*`…）| 就是手机的 IP | ✅ | ✅ 直接 | ✅ 直接 | 最弱 | 无 |
| **`nat`** | 独立 | 一个 `veth`（容器内叫 `eth0`）| `172.28.x.x` | ✅（宿主做 NAT）| 需 `--port` 转发 | 需 `--port` 转发 | 中 | **`CONFIG_VETH` + `CONFIG_BRIDGE`** |
| **`none`** | 独立 | 只有 `lo` | 无 | ❌ | ❌ | ❌ | 最强 | 无 |
| **`gateway`** | 独立 | 接到另一个容器的 LAN | 由网关容器分配 | 经网关容器 | 由网关容器决定 | 由网关容器决定 | 中 | 同 nat |

---

## 二、逐个详解

### 1. `--net=host` —— 主机共享

容器**不新建**网络命名空间，直接用手机的那一个。

实测证据（本机 polaris）：容器内 `readlink /proc/self/ns/net` 与宿主完全相同 —— 都是 `net:[4026531907]`。

**表现**

```sh
# 容器里
$ ip -4 addr show
2: wlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> ...
    inet 192.168.1.189/24          # ← 直接看到手机的 WiFi IP
```

**优点**

- 零开销、零配置，不会成为瓶颈
- 容器里的 `127.0.0.1` **就是手机的 loopback** ⇒ `adb connect 127.0.0.1:5555` 能直接连到手机自己的 adbd
- 容器里**监听端口 = 手机在监听** ⇒ 局域网、Tailscale 都能直接连进来
  （本项目就是靠这个：`ssh root@192.168.1.189` 直接进容器）
- **能用到真实网卡** ⇒ Kali 的 `nmap`、`aircrack-ng`、抓包/中间人这类工具才真正有意义

**缺点**

- **端口冲突**：两个 host 容器同时开 sshd 会抢 22 端口
- 容器能改手机的网络设置（比如动 `iptables`、改路由）
- 没有隔离：容器里 `ps`/网络视角就是手机的

**适合**：AI agent、需要最小延迟、需要在局域网上暴露服务、Kali 做网络测试。

---

### 2. `--net=nat` —— 独立命名空间 + 宿主做 NAT（**软件默认**）

容器有**自己的网络命名空间**，通过一对 **veth** 接到宿主上的 **bridge**，由宿主做地址转换出网。

```
容器 eth0(172.28.x.x) ── veth pair ── 宿主 bridge ── NAT ──> wlan0 ──> 互联网
```

**优点**

- 容器之间、容器与宿主之间**网络隔离**，互不抢端口
- 可精确控制出口与端口暴露
- 容器崩溃/被入侵时不容易波及手机网络

**NAT 专属子选项**

| 选项 | 作用 | 例子 |
|---|---|---|
| `--upstream=IFACE` | **绑定出口网卡**（禁用自动探测）。逗号分隔、支持通配、优先级有序 | `--upstream=wlan0` 只用 WiFi<br>`--upstream=wlan0,rmnet*` 优先 WiFi 回退流量<br>`--upstream=tun0` 只走 VPN（**killswitch**）<br>`--upstream=rmnet*` 手机用 WiFi 但容器走流量 |
| `--port [H:]C[/P]` | **端口转发**（宿主→容器），支持区间与协议 | `--port 22`、`--port 8080:80`、`--port 1000-2000:1000-2000`、`--port 8080:80/udp` |
| `--nat-ip=IP` | 固定容器 IP（须在 `172.28.*.*` 段）| `--nat-ip=172.28.5.10` |
| `--dns=IP,...` | 自定义 DNS | `--dns=223.5.5.5,1.1.1.1` |
| `--disable-ipv6` | 关掉容器内 IPv6 | 手机没有 IPv6 出口时有用 |

> 用法小贴士：手机上网卡会漂（WiFi ↔ 流量），NAT 模式会**自动跟随**；要锁死就用 `--upstream`。
> 流量上网卡名**不稳定**，务必用通配 `rmnet*` 而不是 `rmnet_data0`。

**缺点**

- 多一层 NAT ⇒ 对 P2P、反向连接、某些游戏/语音协议不友好
- 容器里**看不到 `wlan0`** ⇒ 嗅探/抓包类工具基本没用
- **需要内核 `CONFIG_VETH` + `CONFIG_BRIDGE`**

---

### 3. `--net=none` —— 完全断网（air-gapped）

独立命名空间，里面只有 `lo`。

**适合**：分析不可信样本（Kali 逆向恶意软件）、纯本地计算、跑不需要网的任务。
**特点**：最安全，但容器里 `apt`/`pip` 全都不能用。

---

### 4. `--net=gateway` —— 把网络交给另一个容器当网关

容器自己不做 NAT，而是把流量交给**另一个容器**（典型是一个 OpenWRT / 软路由容器）来管 DHCP、DNS、防火墙、路由。

```sh
# 先起网关容器（它自己用 nat 出网）
droidspaces --name=openwrt --rootfs=/data/openwrt --net=nat start
# 再起客户端，挂到网关的 LAN 上
droidspaces --name=kali --rootfs=/data/kali --net=gateway --gateway=openwrt start
```

| 选项 | 作用 | 默认 |
|---|---|---|
| `--gateway=NAME` | 网关容器名（**必填**）| — |
| `--gateway-net=NAME` | LAN 段 / 网桥后缀 | `lan` |
| `--gateway-iface=IFACE` | 网关容器内的接口名 | `eth1` |
| `--gateway-bridge=BR` | 覆盖宿主网桥名 | `ds-<名字>` |

**适合**：想给容器一套独立 LAN、做旁路由/网络实验、统一流量审计。

---

## 三、切换到别的模式

模式是**启动参数，会持久化到容器配置**里，之后 `droidspaces --name=X start` 就沿用：

```sh
su -c '/data/local/tmp/droidspaces --name=ubuntu stop'
su -c '/data/local/tmp/droidspaces --name=ubuntu --rootfs=/data/droidspaces/ubuntu \
        --net=nat --port 2222:22 start'
su -c '/data/local/tmp/droidspaces --name=ubuntu --net=host start'   # 想改回来
```

查看当前模式：`droidspaces --name=<名字> info` → `Networking:` 一行。

---

## 四、polaris 的实际情况（重要）

本机内核（从 LineageOS 的 `/proc/config.gz` 出发的 v3）网络配置实测：

```
✅ CONFIG_BRIDGE=y            ✅ CONFIG_NETFILTER=y        ✅ CONFIG_NF_NAT=y
✅ CONFIG_NF_CONNTRACK=y      ✅ CONFIG_IP_NF_IPTABLES=y   ✅ CONFIG_IP_NF_NAT=y
✅ CONFIG_IP_NF_FILTER=y      ✅ CONFIG_TUN=y              ✅ CONFIG_NET_NS=y
✅ CONFIG_IPV6=y              ✅ CONFIG_DUMMY=y            ✅ ip_forward=1
❌ CONFIG_VETH is not set      ← 只差这一个
```

⇒ 现在用 `--net=nat` 会得到：

```
[ FATAL: NAT NETWORKING UNSUPPORTED ]
  CONFIG_VETH not enabled (kernel returned EOPNOTSUPP)
  Tip: Use --net=host …, or rebuild your kernel with CONFIG_BRIDGE=y and CONFIG_VETH=y
```

**好消息**：`CONFIG_BRIDGE` 已经是 `=y` 了，所以**只要再加 `CONFIG_VETH=y` 一个配置项**，NAT 就可用。
编一个 v4 即可（流程见 `docs/RECIPE.md`，CI 上是 `configs/` 换一份配置 + 重跑 workflow）。

所以在 polaris 上**目前两个容器都是 `host`**：

```
droidspaces --name=ubuntu info  →  Networking: host
droidspaces --name=kali   info  →  Networking: host
```

### host 模式下的端口冲突（**实测**）

两个 host 容器共享网络命名空间 ⇒ **端口空间也是共享的**。实测（polaris，2026-10-07）：

```
宿主   ns/net = net:[4026531907]
ubuntu ns/net = net:[4026531907]
kali   ns/net = net:[4026531907]
```

于是当 ubuntu 的 sshd 已占 22 时，在 kali 里启动 sshd 会**直接失败退出**：

```
Bind to port 22 on 0.0.0.0 failed: Address already in use.
Bind to port 22 on :: failed: Address already in use.
Cannot bind any address.        ← 打印完就退出,服务根本没起来
```

用 Python 单独绑端口验证，结论一致（排除 sshd 的特异性）：

```
kali 绑定 22   → ✗ [Errno 98] Address already in use
kali 绑定 2222 → ✓ 成功
```

**要点**

- **不是「起来了但连不上」，而是「根本起不来」** ⇒ 不存在「随机连上某一个」这种事
- 端口空间属于**网络命名空间**，不是容器 ⇒ 同一 ns 内端口全局唯一
- 唯一可能出现「随机命中」的是进程用了 `SO_REUSEPORT`（内核会把新连接负载均衡给多个 socket）—— **sshd 不用**，所以不会
- `0.0.0.0:22`（IPv4）与 `[::]:22`（IPv6）是**两个**独立绑定，都会被占

**办法一：让两个 sshd 用不同端口**

```sh
# kali 里
sed -i 's/^#*Port .*/Port 2222/' /etc/ssh/sshd_config
/usr/sbin/sshd -p 2222
```

实测（同一个 IP，靠端口区分谁是谁）：

```
$ ssh 192.168.1.189          →  hostname=ubuntu   os=Ubuntu 24.04.5 LTS
$ ssh -p 2222 192.168.1.189  →  hostname=kali     os=Kali GNU/Linux Rolling
```

宿主侧 `0.0.0.0:22`(ubuntu) 与 `0.0.0.0:2222`(kali) 并存；**在 ubuntu 容器里 `ss -ltn` 也能看到 2222** —— 再次印证同一个网络栈。

> 附：Kali 的 sshd 首次启动还需两个前置，否则会以别的理由失败：
> `mkdir -p /run/sshd && chmod 755 /run/sshd`（解包出来的 `umask` 若是 000，目录会是 777，
> sshd 会拒绝：`/run/sshd must be owned by root and not group or world-writable`）
> 以及 `ssh-keygen -A` 生成 host key。

**办法二（更优，需 `CONFIG_VETH`）**：改用 `--net=nat`。每个容器有**独立的网络命名空间和独立端口空间**
⇒ **两个都能用 22**，宿主用 `--port 2222:22` 之类映射进来即可，既不冲突也不需要改容器内的配置。

---

## 五、怎么选（针对本项目的场景）

| 你的需求 | 建议 |
|---|---|
| 跑 AI agent（要联网 + 要能 SSH 进去） | **`host`**（现状，最省事） |
| Kali 做嗅探 / 抓包 / 中间人 / `aircrack` | **`host`**（NAT 下看不到 `wlan0`，这些工具没意义） |
| 同时跑多个容器且都要开 sshd/Web 服务 | **`nat`** + `--port` 映射到不同宿主端口 |
| 想指定容器走 VPN / 只走流量 | **`nat`** + `--upstream=tun0` / `--upstream=rmnet*` |
| 分析不可信样本 | **`none`** |
| 搭一套独立 LAN / 旁路由 | **`gateway`** |

**一句话**：`host` 是「容器就是手机」，`nat` 是「容器是手机后面的一台小机器」。
前者简单直接、能碰真实网卡；后者隔离干净、可控但多一层转发。
