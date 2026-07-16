#!/bin/bash
# 启动本地测试 sshd 容器(密码 + 密钥两种认证),用于 M0 spike 与后续集成测试。
# 用法: ./up.sh    停止: docker rm -f berth-test-sshd
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
KEY="$DIR/test_ed25519"

# 测试专用一次性密钥,已 gitignore
[ -f "$KEY" ] || ssh-keygen -t ed25519 -N "" -f "$KEY" -C berth-test -q

docker rm -f berth-test-sshd >/dev/null 2>&1 || true
docker run -d --name berth-test-sshd \
  -p 127.0.0.1:2222:2222 \
  -e PASSWORD_ACCESS=true \
  -e USER_NAME=dev \
  -e USER_PASSWORD=berth-spike \
  -e PUBLIC_KEY="$(cat "$KEY.pub")" \
  lscr.io/linuxserver/openssh-server:latest >/dev/null

echo "test sshd 已启动: 127.0.0.1:2222  user=dev  password=berth-spike"
echo "私钥: $KEY"
