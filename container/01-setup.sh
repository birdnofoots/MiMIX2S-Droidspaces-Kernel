#!/bin/sh
set -x
sed -i 's|https://mirrors.aliyun.com/|http://mirrors.aliyun.com/|g' /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list 2>/dev/null
grep -rn '^URIs:' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null
printf 'APT::Sandbox::User "root";\nAcquire::ForceIPv4 "true";\n' > /etc/apt/apt.conf.d/99no-sandbox
export DEBIAN_FRONTEND=noninteractive
echo "=== apt-get update ==="
apt-get update 2>&1 | tail -8
echo "=== 装 systemd + 工具链 ==="
apt-get install -y --no-install-recommends \
  ca-certificates systemd systemd-sysv dbus curl wget git \
  python3 python3-pip python3-venv sudo less nano procps \
  iproute2 iputils-ping kmod locales tzdata 2>&1 | tail -16
echo "=== 实证 ==="
ip -4 addr show 2>&1 | grep inet
curl -sI --max-time 25 https://mirrors.aliyun.com/ 2>&1 | head -1
python3 -V 2>&1; git --version 2>&1; systemctl --version 2>&1 | head -1
echo "SETUP4_DONE"
