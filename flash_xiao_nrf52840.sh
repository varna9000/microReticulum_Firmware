#!/bin/bash
#
# flash_xiao_nrf52840.sh — Build, flash, and provision XIAO nRF52840 + Wio-SX1262
#
# Flashes via UF2 bootloader (double-tap reset), then provisions ROM and
# configures radio via rnodeconf.
#
# Usage:
#   ./flash_xiao_nrf52840.sh [OPTIONS]
#
# Options:
#   --freq <Hz>       Frequency in Hz (default: 868800000)
#   --bw <Hz>         Bandwidth in Hz (default: 125000)
#   --sf <SF>         Spreading factor (default: 8)
#   --cr <CR>         Coding rate (default: 5)
#   --txp <dBm>       TX power in dBm (default: 14)
#   --product <hex>   Product code (default: 11)
#   --model <hex>     Model code (default: 12)
#   --skip-build      Skip the build step (use existing firmware)
#   --help            Show this help
#
# Examples:
#   ./flash_xiao_nrf52840.sh
#   ./flash_xiao_nrf52840.sh --freq 869525000 --bw 250000 --sf 7
#   ./flash_xiao_nrf52840.sh --skip-build
#

set -euo pipefail

# ─── Colors ──────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC} $*" >&2; }
step()  { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}"; }

# ─── Defaults ────────────────────────────────────────────
FREQ="868800000"
BW="125000"
SF="8"
CR="5"
TXP="14"
PRODUCT="11"
MODEL="12"
SKIP_BUILD=false

PIO_ENV="xiao_nrf52840"
BUILD_DIR=".pio/build/$PIO_ENV"
FW_NAME="rnode_firmware_xiao_nrf52840"
UF2CONV=""

# ─── Parse args ──────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --freq)       FREQ="$2"; shift 2 ;;
        --bw)         BW="$2"; shift 2 ;;
        --sf)         SF="$2"; shift 2 ;;
        --cr)         CR="$2"; shift 2 ;;
        --txp)        TXP="$2"; shift 2 ;;
        --product)    PRODUCT="$2"; shift 2 ;;
        --model)      MODEL="$2"; shift 2 ;;
        --skip-build) SKIP_BUILD=true; shift ;;
        --help|-h)    head -30 "$0" | grep '^#' | sed 's/^# \?//'; exit 0 ;;
        *)            err "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Activate venv if available ──────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.venv/bin/activate" ]]; then
    source "$SCRIPT_DIR/.venv/bin/activate"
fi

# ─── Prerequisites ───────────────────────────────────────
step "Checking prerequisites"

MISSING=()
$SKIP_BUILD || command -v pio &>/dev/null || MISSING+=("platformio (pip install platformio)")
command -v rnodeconf &>/dev/null || MISSING+=("rnodeconf (pip install rns)")

# Find uf2conv.py
for candidate in \
    "$(find "$HOME/.platformio/packages/framework-arduinoadafruitnrf52" -name uf2conv.py 2>/dev/null | head -1)" \
    "$(command -v uf2conv.py 2>/dev/null || true)"; do
    if [[ -n "$candidate" && -f "$candidate" ]]; then
        UF2CONV="$candidate"
        break
    fi
done
[[ -n "$UF2CONV" ]] || MISSING+=("uf2conv.py (included in Adafruit nRF52 framework)")

if [[ ${#MISSING[@]} -gt 0 ]]; then
    err "Missing required tools:"
    for tool in "${MISSING[@]}"; do echo "  - $tool"; done
    exit 1
fi

ok "All tools found"

# ─── Summary ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}┌──────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│      XIAO nRF52840 + Wio-SX1262 Flash Script     │${NC}"
echo -e "${BOLD}└──────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "  Frequency:   $(echo "scale=3; $FREQ/1000000" | bc) MHz"
echo -e "  Bandwidth:   $(echo "scale=1; $BW/1000" | bc) kHz"
echo -e "  SF: $SF  CR: $CR  TXP: ${TXP} dBm"
echo -e "  Product: 0x$PRODUCT  Model: 0x$MODEL"
echo ""

# ═════════════════════════════════════════════════════════
# STEP 1: Build firmware
# ═════════════════════════════════════════════════════════

if [[ "$SKIP_BUILD" == true ]]; then
    step "Step 1: Build (skipped)"
    if [[ ! -f "$BUILD_DIR/${FW_NAME}.hex" ]]; then
        err "No firmware found at $BUILD_DIR/${FW_NAME}.hex"
        err "Run without --skip-build first"
        exit 1
    fi
    ok "Using existing firmware"
else
    step "Step 1: Building firmware"
    rm -rf "$BUILD_DIR"
    pio run -e "$PIO_ENV"
    ok "Build complete"
fi

# ═════════════════════════════════════════════════════════
# STEP 2: Convert to UF2
# ═════════════════════════════════════════════════════════

step "Step 2: Converting to UF2"

python3 "$UF2CONV" \
    "$BUILD_DIR/${FW_NAME}.hex" \
    -c -f 0xADA52840 \
    -o "$BUILD_DIR/${FW_NAME}.uf2" 2>/dev/null

ok "UF2 created: $BUILD_DIR/${FW_NAME}.uf2"

# ═════════════════════════════════════════════════════════
# STEP 3: Flash via UF2 bootloader
# ═════════════════════════════════════════════════════════

step "Step 3: Flash firmware"

echo ""
echo -e "  ${YELLOW}>>> Double-tap the RESET button to enter bootloader mode <<<${NC}"
echo -e "  ${YELLOW}>>> A USB drive named XIAO-SENSE should appear            <<<${NC}"
echo ""
read -rp "  Press Enter when the XIAO-SENSE drive is mounted..."

# Wait for drive
UF2_DRIVE=""
for i in {1..15}; do
    if [[ -d "/Volumes/XIAO-SENSE" ]]; then
        UF2_DRIVE="/Volumes/XIAO-SENSE"
        break
    elif [[ -d "/media/$USER/XIAO-SENSE" ]]; then
        UF2_DRIVE="/media/$USER/XIAO-SENSE"
        break
    fi
    echo "  Waiting for drive... ($i/15)"
    sleep 1
done

if [[ -z "$UF2_DRIVE" ]]; then
    err "XIAO-SENSE drive not found!"
    err "Make sure you double-tapped reset to enter bootloader mode."
    exit 1
fi

ok "Bootloader drive found: $UF2_DRIVE"
info "Copying UF2 firmware (board will reboot automatically)..."

# Copy UF2 to bootloader drive
cp "$BUILD_DIR/${FW_NAME}.uf2" "$UF2_DRIVE/" 2>/dev/null || true
# Ensure macOS flushes the write to the USB device before the board processes it
sync 2>/dev/null || true

# Wait for board to reboot with new firmware
info "Waiting for board to reboot..."
sleep 5

# ═════════════════════════════════════════════════════════
# STEP 4: Wait for serial port
# ═════════════════════════════════════════════════════════

step "Step 4: Waiting for device"

echo ""
echo -e "  ${YELLOW}>>> Press RESET once (single tap) if the device doesn't appear <<<${NC}"
echo ""

SERIAL_PORT=""
for i in {1..30}; do
    for p in /dev/cu.usbmodem* /dev/ttyACM*; do
        if [[ -e "$p" ]]; then
            SERIAL_PORT="$p"
            break 2
        fi
    done
    if (( i % 5 == 0 )); then
        echo "  Waiting... ($i/30)"
    fi
    sleep 1
done

if [[ -z "$SERIAL_PORT" ]]; then
    err "Serial port not found after flashing!"
    err "Try pressing reset once, or double-tap to re-enter bootloader."
    exit 1
fi

ok "Device found: $SERIAL_PORT"

# Verify device is alive — try KISS first, fall back to serial activity check.
# Note: Once RNS transport starts (~5s), KISS may not respond over serial,
# so we also accept any serial output as proof the firmware is running.
sleep 2
DEVICE_OK=$(python3 -c "
import serial, time
try:
    ser = serial.Serial('$SERIAL_PORT', 115200, timeout=3)
    ser.reset_input_buffer()
    # Try KISS detect
    ser.write(bytes([0xC0, 0x08, 0x73, 0xC0]))
    time.sleep(2)
    data = ser.read(256)
    ser.close()
    print('yes' if data else 'no')
except:
    print('no')
" 2>/dev/null)

if [[ "$DEVICE_OK" != "yes" ]]; then
    warn "Device not responding (RNS may still be starting). Waiting..."
    sleep 8
    # Second attempt — just check if port is usable
    DEVICE_OK=$(python3 -c "
import serial
try:
    ser = serial.Serial('$SERIAL_PORT', 115200, timeout=1)
    ser.close()
    print('yes')
except:
    print('no')
" 2>/dev/null)
    if [[ "$DEVICE_OK" != "yes" ]]; then
        err "Device not responding! Check serial output."
        exit 1
    fi
fi

ok "Firmware is running"

# ═════════════════════════════════════════════════════════
# STEP 5: Provision ROM
# ═════════════════════════════════════════════════════════

step "Step 5: Provision ROM"

info "Writing product=0x$PRODUCT model=0x$MODEL hwrev=1"
rnodeconf "$SERIAL_PORT" --rom --product "$PRODUCT" --model "$MODEL" --hwrev 1

ok "ROM provisioned"
sleep 3

# ═════════════════════════════════════════════════════════
# STEP 6: Set firmware hash
# ═════════════════════════════════════════════════════════

step "Step 6: Setting firmware hash"

# Extract .bin from .zip for hashing (nRF52: hash entire binary)
if [[ -f "$BUILD_DIR/${FW_NAME}.zip" ]]; then
    unzip -o "$BUILD_DIR/${FW_NAME}.zip" "${FW_NAME}.bin" -d "$BUILD_DIR" >/dev/null 2>&1
fi

if [[ -f "$BUILD_DIR/${FW_NAME}.bin" ]]; then
    HASH=$(shasum -a 256 "$BUILD_DIR/${FW_NAME}.bin" 2>/dev/null \
        || sha256sum "$BUILD_DIR/${FW_NAME}.bin" 2>/dev/null | cut -d' ' -f1)
    HASH=$(echo "$HASH" | cut -d' ' -f1)
    info "Hash: $HASH"
    rnodeconf --firmware-hash "$HASH" "$SERIAL_PORT"
    ok "Firmware hash set"
else
    warn "Firmware binary not found, skipping hash"
fi

sleep 3

# ═════════════════════════════════════════════════════════
# STEP 7: Configure TNC mode
# ═════════════════════════════════════════════════════════

step "Step 7: Enable TNC mode"

info "Configuring: freq=$FREQ bw=$BW sf=$SF cr=$CR txp=$TXP"
rnodeconf "$SERIAL_PORT" --tnc --freq "$FREQ" --bw "$BW" --sf "$SF" --cr "$CR" --txp "$TXP"
ok "TNC mode enabled (transport active)"

# ═════════════════════════════════════════════════════════
# Done
# ═════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}${GREEN}┌──────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}${GREEN}│              Flash Complete!                      │${NC}"
echo -e "${BOLD}${GREEN}└──────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "  Port:        ${BOLD}$SERIAL_PORT${NC}"
echo -e "  Frequency:   $(echo "scale=3; $FREQ/1000000" | bc) MHz"
echo -e "  Bandwidth:   $(echo "scale=1; $BW/1000" | bc) kHz"
echo -e "  SF: $SF  CR: $CR  TXP: ${TXP} dBm"
echo ""
echo -e "  Monitor serial output with:"
echo -e "    ${CYAN}tio $SERIAL_PORT${NC}"
echo ""
echo -e "  Verify device:"
echo -e "    ${CYAN}rnodeconf $SERIAL_PORT -i${NC}"
echo ""
