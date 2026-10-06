#!/bin/sh
set -x
echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
printf 'Acquire::ForceIPv4 "true";\n' > /etc/apt/apt.conf.d/99force-ipv4
/bin/cat /etc/apt/apt.conf.d/99force-ipv4
echo "--- 现有源 ---"
grep -rn 'ports.ubuntu.com\|archive.ubuntu.com\|^URIs:\|^deb ' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | head -12
echo "--- 换阿里云 ubuntu-ports ---"
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
  [ -f "$f" ] || continue
  sed -i 's|http://ports.ubuntu.com/ubuntu-ports|https://mirrors.aliyun.com/ubuntu-ports|g; s|http://archive.ubuntu.com/ubuntu|https://mirrors.aliyun.com/ubuntu|g; s|http://security.ubuntu.com/ubuntu|https://mirrors.aliyun.com/ubuntu|g' "$f"
done
grep -rn '^URIs:\|^deb ' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | head -8
echo "--- IPv4 解析测试 ---"
getent ahostsv4 mirrors.aliyun.com 2>&1 | head -4
echo "--- apt-get update ---"
export DEBIAN_FRONTEND=noninteractive
apt-get update 2>&1 | tail -12
echo "NETFIX_DONE"
