# 踩坑与排错手册（polaris / Droidspaces / 老内核）

本文记录本项目**实际踩过并解决**的坑。每条都给出：症状 → 根因 → 修法 → 证据。
适用于「在 Linux 4.9 这类老内核的 Android 设备上跑新版发行版容器」这个场景。

---

## 1. ★ Linux 4.9 跑不了新版 systemd（Kali 261 / Debian 13+）

### 症状

`apt upgrade` 在配置 `systemd` 时炸掉：

```
dpkg: error processing package systemd (--configure):
 old systemd package postinst maintainer script subprocess failed with exit status 1
dpkg: dependency problems prevent configuration of systemd-sysv
```

而且**消息本身自相矛盾** —— 文件明明存在却说打不开：

```
Failed to enable units: Protocol driver not attached.
Cannot open '/etc/machine-id': Protocol driver not attached      ← 该文件存在且可读!
Failed to chase and open directory '/usr/lib/systemd/catalog', ignoring: Protocol driver not attached
```

容器直接拿系统d 当 PID 1 启动时会**立刻退出**（exit 255）。

### 根因

`Protocol driver not attached` = **ENXIO**；配合容器 console 里的真话：

```
Failed to determine whether /proc is a mount point: Invalid argument
Failed to determine whether /sys is a mount point: Invalid argument
[!!!!!!] Failed to mount API filesystems.
Exiting PID 1...
```

新版 systemd（**256+ 起强制**）用 `statx(..., STATX_MNT_ID)` 判断挂载点，
该字段需要 **Linux ≥ 5.8**。内核 4.9 上这个调用失败 ⇒ systemd 连 `/proc`、`/sys`
都判断不了 ⇒ 拒绝启动；它的辅助工具（`systemd-sysusers` 等）也因此找不到自己的配置目录。

> Ubuntu 24.04 的 systemd **255** 能跑，是因为它还保留旧回退路径。
> **换发行版版本比改配置更实际。**

### 修法（让包能配完，不指望 systemd 能跑）

三步，全部可逆：

```sh
# ① 让 systemctl 变成"空操作且成功"
export SYSTEMD_OFFLINE=1
echo 'SYSTEMD_OFFLINE=1' >> /etc/environment
printf 'export SYSTEMD_OFFLINE=1\n' > /etc/profile.d/00-systemd-offline.sh

# ② 阻止服务被自动启动(容器标准做法)
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod 755 /usr/sbin/policy-rc.d

# ③ ★用 dpkg-divert 换掉会失败的 systemd 辅助工具(不改包内脚本,抗升级)
for t in systemd-machine-id-setup systemd-sysusers systemd-tmpfiles systemd-hwdb; do
  p=/usr/bin/$t; [ -e "$p" ] || continue
  [ -e "$p.distrib" ] || dpkg-divert --local --rename --add "$p"
  printf '#!/bin/sh\nexit 0\n' > "$p"; chmod 755 "$p"
done
# machine-id 要保证存在(其余工具在无 systemd 的容器里本就是 no-op)
[ -s /etc/machine-id ] || head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' > /etc/machine-id

dpkg --configure -a     # 一次通过
```

### 顺手消掉 apt 刷屏的红字（可选但强烈建议）

`SYSTEMD_OFFLINE=1` 只在交互式 shell 生效；从 App/非登录 shell 里跑 apt 时，
`systemctl` 仍是真身 ⇒ 每次装包都刷一屏红色：

```
Failed to disable unit: Cannot resolve specifiers in unit /etc/systemd/system/multi-user.target.wants/remote-fs.target
（× 几十条，看着像灾难，实际 dpkg 完全没失败）
```

把 `systemctl` 也 shim 掉，并对子命令给出**诚实且不报错**的回答：

```sh
dpkg-divert --local --rename --add /usr/bin/systemctl
cat > /usr/bin/systemctl <<'SHIM'
#!/bin/sh
cmd="$1"; shift 2>/dev/null
case "$cmd" in
  --version|-v)      echo "systemd 261 (droidspaces container shim)"; exit 0 ;;
  is-system-running) echo "offline";  exit 1 ;;   # 真的没在跑
  is-enabled)        echo "disabled"; exit 1 ;;
  is-active)         echo "inactive"; exit 3 ;;
  is-failed)         echo "inactive"; exit 1 ;;
  status|show)       echo "Unit not loaded (no systemd in container)."; exit 4 ;;
  *)                 exit 0 ;;                    # enable/disable/daemon-reload … 静默成功
esac
SHIM
chmod 755 /usr/bin/systemctl
```

另外 `locale: Cannot set LC_CTYPE to default locale` 是纯装饰性问题（镜像没生成 locale）：

```sh
sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen && locale-gen
printf 'LANG=en_US.UTF-8\n' > /etc/default/locale
```

### 修完之后，**哪些输出仍会（也应该）出现**

| 输出 | 判定 |
|---|---|
| `invoke-rc.d: policy-rc.d denied execution of start.` | ✅ **正常且必要** —— 这正是 `policy-rc.d` 在阻止容器里自动启服务 |
| `invoke-rc.d: could not determine current runlevel` | ⚪ 正常，容器没有 runlevel 概念 |
| `update-rc.d: … It looks like a network service, we disable it.` | ⚪ 正常，sysvinit 的处理 |

**验证手法**：不要只看有没有红字，要看**系统健康**：

```sh
dpkg --audit                    # 空 ⇒ 无破损包
apt-get check                   # 无错误 ⇒ 依赖一致
dpkg -l | awk '$1!~/^ii/ && $1~/^i/'   # 空 ⇒ 无"已解包未配置"
dpkg -l <刚装的包>               # 状态须为 ii
```

**为什么用 `dpkg-divert` 而不是改 `/var/lib/dpkg/info/systemd.postinst`**：
divert 让 dpkg 知道该文件被本地接管 ⇒ **systemd 以后升级也不会覆盖 shim**，而且完全可撤销；
改 postinst 则会在下次升级时被覆盖回去。

### 定位手法（值得复用）

1. **读 errno，不读包名** —— ENXIO/EINVAL 这类罕见错误码几乎总指向 syscall 层
2. **找矛盾点** —— "文件存在却说打不开"能一步砍掉 90% 可能性
3. **程序静默退出时去读它留的日志** —— droidspaces 会在
   `/data/local/Droidspaces/Logs/<容器名>/console` 留档
4. **读 postinst 找"唯一没有 `|| true`"的那一行**：
   ```sh
   systemctl ... enable remote-fs.target || true     # 失败无所谓
   systemd-machine-id-setup                          # ★ 没有 || true ⇒ 一失败全挂
   ```
5. **用 `sh -x /var/lib/dpkg/info/<pkg>.postinst configure <旧版本>` 看它死在哪一行**

---

## 2. `magiskboot` 的输出走 **stderr**

```sh
magiskboot unpack boot.img | tee log     # ✗ log 是 0 字节(终端却能看到输出)
magiskboot unpack boot.img 2>&1 | tee log  # ✓
```

后果：打包脚本从空日志里 grep `KERNEL_DTB_SZ` 得到空值，**把一次完全正确的编译误报成
"DTB 段被破坏，拒绝产出"**。

另外：`KERNEL_DTB_SZ` **只在 unpack 输出里出现**，repack 输出里没有 ⇒ 两个日志都要看。
更稳的是**结构校验**：把产出镜像再解包一次，`cmp kernel_dtb` 必须与原厂逐字节相同。

---

## 3. droidspaces 容器名会串号（rootfs 共用父目录时）

### 症状

```
Container name 'kali' is already in use by PID 4385.      ← 4385 其实是 ubuntu 的
droidspaces show    →  ubuntu 4385 / kali 4385           ← 两个都指向同一个 PID
droidspaces --name=kali run ...                          ← 命令实际跑进了 ubuntu ✗
```

### 根因

`/data/droidspaces/kali` 与 `/data/droidspaces/ubuntu` **共用父目录** `/data/droidspaces`。

### 修法

**每个容器的 rootfs 用各自独立的父目录**：

```
/data/kali-rootfs              父目录 = /data            ✓（但与其它 /data/* 仍可能撞）
/data/droidspaces/ubuntu       父目录 = /data/droidspaces ✓
```

⚠️ **危险**：串号状态下 `droidspaces --name=<新容器> stop` 会**杀掉已在运行的那个容器**。
执行 `stop` 前务必先比对 PID 记录：

```sh
KP=$(cat /data/local/Droidspaces/Pids/kali.pid)
UP=$(cat /data/local/Droidspaces/Pids/ubuntu.pid)
[ "$KP" = "$UP" ] && { echo "记录串号,拒绝 stop"; exit 1; }
```

注册表就是 `/data/local/Droidspaces/Pids/*.pid`；daemon 活着时**缓存在内存**，
删文件不生效 ⇒ 需要重启 daemon（或让 App 重启它）。

---

## 4. `host` 模式下两个容器抢端口

同一网络命名空间 ⇒ 端口空间共享 ⇒ 后启动的 sshd **直接失败退出**：

```
Bind to port 22 on 0.0.0.0 failed: Address already in use.
Cannot bind any address.
```

**不是"起来了连不上"，而是"根本起不来"** —— 不存在"随机连上某一个"。
（只有用了 `SO_REUSEPORT` 的进程才会有负载均衡式随机；**sshd 不用**。）

两种修法：
1. 改端口（`Port 2222`）—— 简单
2. **改用 `--net=nat`** —— 每个容器独立端口空间，**两个都能用 22**，宿主用 `--port` 映射

---

## 5. `--net=nat` 的两个前置

### 内核侧：`CONFIG_VETH=y`

缺了会直接 FATAL：

```
[ FATAL: NAT NETWORKING UNSUPPORTED ]  CONFIG_VETH not enabled (kernel returned EOPNOTSUPP)
```

`CONFIG_BRIDGE`、`CONFIG_NETFILTER`、`NF_NAT`、`NF_CONNTRACK`、`IP_NF_IPTABLES`、`IP_NF_NAT`
通常老内核也都开着；**polaris 实测只差 `CONFIG_VETH` 一个**（加一行即可，见 `configs/polaris-v4-veth.config`）。

### 容器侧：**容器自己的 init 必须去配 `eth0`**

droidspaces 只做**宿主侧**（建网桥 `ds-br0` 172.28.0.1/16、veth 对、MASQUERADE 规则、端口转发）。
容器里 `eth0` 初始是 down 且无地址的 —— 如果你的 init 不是 systemd/NetworkManager（比如自举 shell），
**必须自己配**，否则容器里只有 `lo`：

```sh
ip link set eth0 up
ip addr add 172.28.5.10/16 dev eth0     # 与 --nat-ip 一致
ip route add default via 172.28.0.1
```

见 `container/kali/ds-init`（本项目用的自举 init，含配网 + 起 sshd/cron + 保活）。

---

## 6. Kali sshd 首次启动的两个前置

```
/run/sshd must be owned by root and not group or world-writable.
sshd: no hostkeys available -- exiting.
```

`tar` 解包时若 `umask` 为 000，目录会是 777 ⇒ sshd 拒绝。修：

```sh
mkdir -p /run/sshd && chmod 755 /run/sshd && chown root:root /run/sshd
ssh-keygen -A
```

---

## 7. 容器内 apt 的四层坑（Debian/Ubuntu/Kali 通用）

| 症状 | 根因 | 修法 |
|---|---|---|
| `Temporary failure resolving` | 只解析到 AAAA/IPv6，手机无 IPv6 出口 | `/etc/gai.conf` 偏好 IPv4 + `Acquire::ForceIPv4 "true"` |
| `Could not resolve`（但 `getent` 正常）| **`_apt`(uid 42) 被 Android per-UID 路由拦**（root 通）| `APT::Sandbox::User "root";` |
| `certificate is NOT trusted` | 缺 `ca-certificates` 却用 https 源 | 先改用 http 源装完 ca-certificates |
| `Release file is not valid yet` | 手机时钟偏差（本例慢 5.5 天）| `Acquire::Check-Date "false";` + 用 toybox 格式设时钟 |

设时钟（Android toybox 是 `MMDDhhmmCCYY`，**不是** `CCYYMMDDhhmm`）：

```sh
su -c 'setenforce 0; date -u 100621052026; setenforce 1'
```

---

## 8. 不开锁屏也能通过 adb 授权

`允许 USB 调试吗？` 弹窗在锁屏下点不到，而客户端重试很快（每次重连换新 transport），
`uiautomator dump` 的 1~2 秒足够让点击落在已失效的 transport 上：

```
authorization received for deleted transport (N), ignoring
```

**有效做法：`input tap` 快速盲点循环**（布局稳定时每秒一轮，抢在存活窗口内）：

```sh
input tap 539 1127    # 勾选"一律允许"
input tap 888 1300    # 点"允许"
```

配合 `settings put global adb_allowed_connection_timeout 0`（否则授权 7 天后过期）。

---

## 9. 其它操作铁律

1. **`pkill -f` 会自杀**（远程命令里含同样字面量）⇒ 用方括号模式 `[m]ars-when-online` 或按 PID
2. **`su -c "内层带单引号"` 一定被吃** ⇒ 一律 push 脚本文件再 `sh /path/x.sh`
3. **跨主机拷贝用一台中转**，每跳核对大小 + md5（曾出现中转副本被截断成 28.8MB）
4. **`fastboot boot <img>` 是零风险验证**：RAM 启动、不写 flash，失败自然回落旧内核
5. **进 fastboot 前先杀"一见 fastboot 就刷机"的守望脚本**
6. 改正在运行的 bash 脚本会把执行搞坏（`syntax error`）⇒ 先 kill 再替换
7. `screencap` 全黑不可信；判"进系统"要 `boot_completed=1` + 核对 `/proc/version` + **看图**
