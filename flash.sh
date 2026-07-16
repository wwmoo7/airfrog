#!/usr/bin/env bash
set -euo pipefail

# 用法:
#   ./flash.sh                         默认凭据 test/test1234，烧 /dev/ttyUSB0
#   AF_SSID=x AF_PASS=y ./flash.sh
#   PORT=/dev/ttyACM0 ./flash.sh
#   ./flash.sh --monitor               烧完进串口监视

: "${AF_SSID:=test}"
: "${AF_PASS:=test1234}"
: "${PORT:=/dev/ttyUSB0}"
: "${BAUD:=115200}"

export PATH="$HOME/.cargo/bin:$PATH"
cd "$(dirname "$0")"

MONITOR=0
for a in "$@"; do
    [[ "$a" == "--monitor" || "$a" == "-m" ]] && MONITOR=1
done

echo "==> build: AF_SSID=$AF_SSID  AF_PASS=$AF_PASS"
AF_STA_SSID="$AF_SSID" AF_STA_PASSWORD="$AF_PASS" \
    cargo build --release -p airfrog

echo "==> flash: $PORT"
espflash flash --chip esp32c3 -p "$PORT" -b "$BAUD" \
    target/riscv32imc-unknown-none-elf/release/airfrog

if [[ "$MONITOR" == "1" ]]; then
    echo "==> monitor (Ctrl+] to exit)"
    espflash monitor -p "$PORT" -b "$BAUD"
fi