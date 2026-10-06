#!/bin/sh
set -x
export DEBIAN_FRONTEND=noninteractive
date -u
echo "=== apt update ==="
apt-get update 2>&1 | tail -4
echo "=== NodeSource Node 22 (arm64) ==="
if curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/ns.sh && sh /tmp/ns.sh 2>&1 | tail -6 && apt-get install -y nodejs 2>&1 | tail -5; then
  echo "NODESOURCE_OK"
else
  echo "NODESOURCE_FAIL -> 退回发行版 nodejs"
  apt-get install -y nodejs npm 2>&1 | tail -5
fi
node -v; npm -v
echo "=== 装 AI agent CLI ==="
npm install -g --no-fund --no-audit @anthropic-ai/claude-code 2>&1 | tail -4
npm install -g --no-fund --no-audit @google/gemini-cli 2>&1 | tail -4
npm install -g --no-fund --no-audit @openai/codex 2>&1 | tail -4
echo "=== 版本实证 ==="
(command -v claude && claude --version) 2>&1 | tail -1
(command -v gemini && gemini --version) 2>&1 | tail -1
(command -v codex  && codex --version)  2>&1 | tail -1
echo "AGENTS2_DONE"
