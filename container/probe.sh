#!/bin/sh
echo "--- uname ---"; uname -a
echo "--- hostname ---"; hostname
echo "--- os ---"; head -3 /etc/os-release
echo "--- 网络 ---"; ip -4 addr show | grep inet
echo "--- resolv ---"; cat /etc/resolv.conf
echo "--- ns ---"; ls /proc/self/ns/ | tr '\n' ' '; echo
echo "--- pid1 ---"; cat /proc/1/comm
