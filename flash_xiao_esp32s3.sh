#!/bin/bash
#
# flash_xiao_esp32s3.sh — Build, flash, and provision XIAO ESP32-S3 + Wio-SX1262
#
# Flashes via esptool (USB), then provisions ROM and configures radio via rnodeconf.
#
# Boot sequence for entering bootloader:
#   - If our firmware is already running: esptool usb_reset works automatically
#   - If MicroPython is running: sends machine.bootloader() via REPL
#   - Last resort: manual BOOT+RESET button combo
#
# Usage:
#   ./flash_xiao_esp32s3.sh [OPTIONS]
#
# Options:
#   --freq <Hz>       Frequency in Hz (default: 868800000)
#   --bw <Hz>         Bandwidth in Hz (default: 125000)
#   --sf <SF>         Spreading factor (default: 8)
#   --cr <CR>         Coding rate (default: 5)
#   --txp <dBm>       TX power in dBm (default: 14)
#   --product <hex>   Product code (default: 11)
#   --model <hex>     Model code (default: 13)
#   --skip-build      Skip the build step (use existing firmware)
#   --help            Show this help
#
# Examples:
#   ./flash_xiao_esp32s3.sh
#   ./flash_xiao_esp32s3.sh --freq 869525000 --bw 250000 --sf 7
#   ./flash_xiao_esp32s3.sh --skip-build
#

set -euo pipefail

# ─── Colors ──────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC} $*" >&2; }
step()  { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}"; }

# ─── Defaults ────────────────────────────────────────
FREQ="868800000"
BW="125000"
SF="8"
CR="5"
TXP="14"
PRODUCT="12"
MODEL="13"
SKIP_BUILD=false

PIO_ENV="xiao_esp32s3"
BUILD_DIR=".pio/build/$PIO_ENV"
FW_BIN="rnode_firmware_xiao_esp32s3.bin"

# ─── Parse args ──────────────────────────────────────
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
        --help|-h)    head -35 "$0" | grep '^#' | sed 's/^# \?//'; exit 0 ;;
        *)            err "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Activate venv if available ──────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.venv/bin/activate" ]]; then
    source "$SCRIPT_DIR/.venv/bin/activate"
fi

# ─── Prerequisites ───────────────────────────────────
step "Checking prerequisites"

MISSING=()
$SKIP_BUILD || command -v pio &>/dev/null || MISSING+=("platformio (pip install platformio)")
command -v rnodeconf &>/dev/null || MISSING+=("rnodeconf (pip install rns)")

if [[ ${#MISSING[@]} -gt 0 ]]; then
    err "Missing required tools:"
    for tool in "${MISSING[@]}"; do echo "  - $tool"; done
    exit 1
fi

ok "All tools found"

# ─── Summary ─────────────────────────────────────────
echo ""
echo -e "${BOLD}┌──────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│    XIAO ESP32-S3 + Wio-SX1262 Flash Script       │${NC}"
echo -e "${BOLD}└──────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "  Frequency:   $(echo "scale=3; $FREQ/1000000" | bc) MHz"
echo -e "  Bandwidth:   $(echo "scale=1; $BW/1000" | bc) kHz"
echo -e "  SF: $SF  CR: $CR  TXP: ${TXP} dBm"
echo -e "  Product: 0x$PRODUCT  Model: 0x$MODEL"
echo ""

# ═════════════════════════════════════════════════════
# STEP 1: Build firmware + filesystem
# ═════════════════════════════════════════════════════

if [[ "$SKIP_BUILD" == true ]]; then
    step "Step 1: Build (skipped)"
    if [[ ! -f "$BUILD_DIR/$FW_BIN" ]]; then
        err "No firmware found at $BUILD_DIR/$FW_BIN"
        err "Run without --skip-build first"
        exit 1
    fi
    ok "Using existing firmware"
else
    step "Step 1: Building firmware"
    pio run -e "$PIO_ENV"
    pio run -e "$PIO_ENV" -t buildfs
    ok "Build complete"
fi

# ═════════════════════════════════════════════════════
# STEP 2: Flash via esptool
# ═════════════════════════════════════════════════════

step "Step 2: Flash firmware"

# Find esptool
ESPTOOL="$(find "$HOME/.platformio/packages" -name "esptool.py" -path "*/tool-esptoolpy/*" 2>/dev/null | sort -r | head -1)"
if [[ -z "$ESPTOOL" ]]; then
    err "esptool.py not found in PlatformIO packages"
    exit 1
fi

# Detect port
UPLOAD_PORT=""
for p in /dev/cu.usbmodem* /dev/ttyACM*; do
    if [[ -e "$p" ]]; then
        UPLOAD_PORT="$p"
        break
    fi
done

if [[ -z "$UPLOAD_PORT" ]]; then
    err "No serial port detected. Make sure the board is connected."
    exit 1
fi

ok "Port: $UPLOAD_PORT"

# Enter bootloader mode. Try multiple strategies:
info "Entering bootloader mode..."
BEFORE_MODE="usb_reset"

# Try 1: usb_reset (works when our firmware or USB-Serial-JTAG firmware is running)
if python3 "$ESPTOOL" --chip esp32s3 --port "$UPLOAD_PORT" --before usb_reset chip_id 2>/dev/null; then
    ok "Connected (usb_reset)"
else
    # Try 2: MicroPython bootloader command (fresh boards with MicroPython)
    info "Trying MicroPython bootloader entry..."
    python3 -c "
import serial, time
try:
    s = serial.Serial('$UPLOAD_PORT', 115200, timeout=1)
    s.write(b'\x03\x03')
    time.sleep(0.3)
    s.write(b'\r\nimport machine; machine.bootloader()\r\n')
    time.sleep(0.5)
    s.close()
except: pass
" 2>/dev/null
    sleep 2

    # Re-detect port after USB re-enumeration
    UPLOAD_PORT=""
    for i in {1..10}; do
        for p in /dev/cu.usbmodem* /dev/ttyACM*; do
            if [[ -e "$p" ]]; then
                UPLOAD_PORT="$p"
                break 2
            fi
        done
        sleep 1
    done

    if [[ -n "$UPLOAD_PORT" ]] && python3 "$ESPTOOL" --chip esp32s3 --port "$UPLOAD_PORT" --before no_reset chip_id 2>/dev/null; then
        BEFORE_MODE="no_reset"
        ok "Connected (MicroPython bootloader)"
    else
        # Try 3: manual
        echo ""
        echo -e "  ${YELLOW}Auto-reset failed. Enter bootloader manually:${NC}"
        echo -e "  ${YELLOW}  Hold BOOT (B), press RESET (R), release BOOT${NC}"
        echo ""
        read -rp "  Press Enter when done..."

        UPLOAD_PORT=""
        for i in {1..10}; do
            for p in /dev/cu.usbmodem* /dev/ttyACM*; do
                if [[ -e "$p" ]]; then
                    UPLOAD_PORT="$p"
                    break 2
                fi
            done
            sleep 1
        done

        if [[ -z "$UPLOAD_PORT" ]]; then
            err "No port found."
            exit 1
        fi
        BEFORE_MODE="no_reset"
        ok "Port: $UPLOAD_PORT"
    fi
fi

# Erase flash first for clean slate
info "Erasing flash..."
python3 "$ESPTOOL" \
    --chip esp32s3 \
    --port "$UPLOAD_PORT" \
    --before "$BEFORE_MODE" \
    erase_flash

sleep 2

# Re-detect port after erase (board reboots)
UPLOAD_PORT=""
for i in {1..10}; do
    for p in /dev/cu.usbmodem* /dev/ttyACM*; do
        if [[ -e "$p" ]]; then
            UPLOAD_PORT="$p"
            break 2
        fi
    done
    sleep 1
done

if [[ -z "$UPLOAD_PORT" ]]; then
    err "Port lost after erase."
    exit 1
fi

# Flash bootloader + partitions + firmware + filesystem
info "Flashing firmware..."
python3 "$ESPTOOL" \
    --chip esp32s3 \
    --port "$UPLOAD_PORT" \
    --baud 460800 \
    --before usb_reset \
    --after hard_reset \
    write_flash -z \
    --flash_mode dio \
    --flash_freq 80m \
    --flash_size 8MB \
    0x0000 "$BUILD_DIR/bootloader.bin" \
    0x8000 "$BUILD_DIR/partitions.bin" \
    0x10000 "$BUILD_DIR/$FW_BIN" \
    0x670000 "$BUILD_DIR/littlefs.bin"

ok "Flash complete"

# Wait for board to reboot
info "Waiting for board to reboot..."
sleep 5

# ═════════════════════════════════════════════════════
# STEP 3: Wait for serial port
# ═════════════════════════════════════════════════════

step "Step 3: Waiting for device"

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
    exit 1
fi

ok "Device found: $SERIAL_PORT"

# Wait for firmware to boot
sleep 5

# ═════════════════════════════════════════════════════
# STEP 4: Provision ROM
# ═════════════════════════════════════════════════════

step "Step 4: Provision ROM"

info "Writing product=0x$PRODUCT model=0x$MODEL hwrev=1"
rnodeconf "$SERIAL_PORT" --rom --product "$PRODUCT" --model "$MODEL" --hwrev 1

ok "ROM provisioned"
sleep 3

# ═════════════════════════════════════════════════════
# STEP 5: Set firmware hash
# ═════════════════════════════════════════════════════

step "Step 5: Setting firmware hash"

if [[ -f "$BUILD_DIR/$FW_BIN" ]]; then
    HASH=$(shasum -a 256 "$BUILD_DIR/$FW_BIN" 2>/dev/null \
        || sha256sum "$BUILD_DIR/$FW_BIN" 2>/dev/null | cut -d' ' -f1)
    HASH=$(echo "$HASH" | cut -d' ' -f1)
    info "Hash: $HASH"
    rnodeconf --firmware-hash "$HASH" "$SERIAL_PORT"
    ok "Firmware hash set"
else
    warn "Firmware binary not found, skipping hash"
fi

sleep 3

# ═════════════════════════════════════════════════════
# STEP 6: Configure TNC mode
# ═════════════════════════════════════════════════════

step "Step 6: Enable TNC mode"

info "Configuring: freq=$FREQ bw=$BW sf=$SF cr=$CR txp=$TXP"
rnodeconf "$SERIAL_PORT" --tnc --freq "$FREQ" --bw "$BW" --sf "$SF" --cr "$CR" --txp "$TXP"
ok "TNC mode enabled (transport active)"

# ═════════════════════════════════════════════════════
# Done
# ═════════════════════════════════════════════════════

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
