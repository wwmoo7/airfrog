#!/usr/bin/env bash
# build.sh - 编译 airfrog 固件并生成可烧录的 airfrog.bin
#
# 用法:
#   ./build.sh                         默认凭据 test/test1234
#   AF_SSID=xxx AF_PASS=yyy ./build.sh 自定义 WiFi 凭据
#
# 一次性环境搭建（如已装可跳过）:
#   # 1. Rust + rustup
#   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
#   source "$HOME/.cargo/env"
#
#   # 2. ESP Rust 工具链（项目 rust-toolchain.toml 会自动应用）
#   rustup toolchain install nightly --component rust-src
#   rustup target add riscv32imc-unknown-none-elf
#
#   # 3. 烧录/镜像生成 CLI（生成 airfrog.bin 用）
#   cargo install espflash --locked
#
#   # 4. 串口访问（Linux，需要重新登录）
#   sudo apt install -y libudev-dev libusb-1.0-0-dev
#   sudo usermod -aG dialout $USER
#
# 已安装的工具:
#   cargo / rustc / rustup            Rust 工具链（rustup 自带）
#   espflash                          生成/烧录 ESP 镜像（cargo install）

set -euo pipefail

: "${AF_SSID:=test}"
: "${AF_PASS:=test1234}"

export PATH="$HOME/.cargo/bin:$PATH"
cd "$(dirname "$0")"

echo "==> build: AF_SSID=$AF_SSID  AF_PASS=$AF_PASS"
AF_STA_SSID="$AF_SSID" AF_STA_PASSWORD="$AF_PASS" \
    cargo build --release -p airfrog

OUT=airfrog.bin
echo "==> generate $OUT"
espflash save-image --chip esp32c3 \
    --merge target/riscv32imc-unknown-none-elf/release/airfrog \
    "$OUT"

echo "==> done: $(pwd)/$OUT ($(du -h "$OUT" | cut -f1))"