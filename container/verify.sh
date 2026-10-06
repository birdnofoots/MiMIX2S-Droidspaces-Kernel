#!/bin/sh
echo "--- uname ---"; uname -a
echo "--- hostname ---"; hostname
echo "--- os ---"; head -2 /etc/os-release
echo "--- python ---"; python3 -V 2>&1
echo "--- node ---"; node -v 2>&1
echo "--- agents ---"
claude --version 2>&1 | tail -1
gemini --version 2>&1 | tail -1
codex  --version 2>&1 | tail -1
echo "--- systemd ---"; systemctl --version 2>&1 | head -1
echo "--- 网络 ---"; curl -sI --max-time 20 https://registry.npmjs.org/ 2>&1 | head -1
echo "--- ns ---"; ls /proc/self/ns/ | tr '\n' ' '; echo
echo "AGENTS_OK"
