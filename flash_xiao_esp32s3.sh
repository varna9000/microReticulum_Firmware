#!/bin/bash
#
# flash_xiao_esp32s3.sh — Build, flash, and provision XIAO ESP32-S3 + Wio-SX1262
#
# Flashes via esptool (USB), then provisions ROM and configures radio via rnodeconf.
#
# Boot sequence for entering bootloader:
#   1. KISS CMD_BOOTLOADER (0x5A 0xF8) — works if our firmware ≥ v1.73 is running
#   2. esptool usb_reset — works only if the firmware is hung/silent
#   3. Manual: hold tiny BOOT button on the XIAO module (under the Wio carrier)
#      while plugging in USB, then release.
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
#   --erase-flash     Erase ENTIRE 8 MB flash (LittleFS, EEPROM, identities,
#                     all caches) before writing firmware. Takes ~30-60 s.
#                     Use for first deployment or to recover from a corrupted
#                     filesystem.
#   --help            Show this help
#
# Examples:
#   ./flash_xiao_esp32s3.sh
#   ./flash_xiao_esp32s3.sh --freq 869525000 --bw 250000 --sf 7
#   ./flash_xiao_esp32s3.sh --skip-build
#   ./flash_xiao_esp32s3.sh --erase-flash   # full wipe + reflash
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
ERASE_FLASH=false

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
        --erase-flash) ERASE_FLASH=true; shift ;;
        --help|-h)    head -40 "$0" | grep '^#' | sed 's/^# \?//'; exit 0 ;;
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
if [[ "$ERASE_FLASH" == true ]]; then
    echo -e "  ${YELLOW}Mode:        FULL FLASH ERASE — LittleFS, EEPROM, identities will be wiped${NC}"
fi
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

# Enter bootloader mode. Strategy order:
#   1. KISS CMD_BOOTLOADER (works if our firmware ≥ v1.73 is already running)
#   2. esptool usb_reset (works only if firmware is hung/silent)
#   3. Manual: tiny BOOT button on XIAO module (under the Wio carrier)

info "Entering bootloader mode..."

# Try 1: KISS CMD_BOOTLOADER 0x5A 0xF8 — firmware-side download-mode trigger
info "Sending KISS CMD_BOOTLOADER..."
python3 -c "
import serial, time
try:
    s = serial.Serial('$UPLOAD_PORT', 115200, timeout=1)
    # FEND CMD_BOOTLOADER BOOTLOADER_BYTE FEND = c0 5a f8 c0
    s.write(bytes([0xC0, 0x5A, 0xF8, 0xC0]))
    s.flush()
    time.sleep(0.5)
    s.close()
except: pass
" 2>/dev/null
sleep 3

# Wait for USB re-enumeration into bootloader (PID changes 0x4001 → 0x1001)
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
    ok "In bootloader (via firmware CMD_BOOTLOADER)"
elif python3 "$ESPTOOL" --chip esp32s3 --port "$UPLOAD_PORT" --before usb_reset chip_id 2>/dev/null; then
    # Try 2: usb_reset — only works if firmware is hung and not handling USB events
    ok "In bootloader (via esptool usb_reset)"
else
    # Try 3: manual tiny BOOT button on XIAO
    echo ""
    echo -e "  ${YELLOW}Auto-entry failed. The firmware isn't responding to KISS commands"
    echo -e "  and the chip can't be reset programmatically.${NC}"
    echo ""
    echo -e "  ${YELLOW}Manual entry — use the tiny BOOT button on the XIAO module"
    echo -e "  (the one near the USB port, under the Wio carrier):${NC}"
    echo -e "  ${YELLOW}  1. Unplug USB${NC}"
    echo -e "  ${YELLOW}  2. Hold BOOT (tiny button on XIAO)${NC}"
    echo -e "  ${YELLOW}  3. Plug USB in (while holding BOOT)${NC}"
    echo -e "  ${YELLOW}  4. Release BOOT${NC}"
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
        err "No port found after manual BOOT."
        exit 1
    fi
    ok "Port: $UPLOAD_PORT"
fi

# Optional full erase (wipes LittleFS, EEPROM, identity files, RNS caches —
# everything). Useful for fresh deployment or recovering from a corrupted FS.
if [[ "$ERASE_FLASH" == true ]]; then
    info "Erasing entire 8 MB flash — this takes ~30-60 seconds..."
    python3 "$ESPTOOL" \
        --chip esp32s3 \
        --port "$UPLOAD_PORT" \
        --before no_reset \
        --after no_reset \
        erase_flash
    ok "Flash erased"
fi

# Flash bootloader + partitions + firmware (NO littlefs.bin — firmware self-formats
# the empty spiffs partition on first boot with name_max=255, avoiding the
# mklittlefs name_max=32 superblock issue).
#
# --after no_reset: chip stays in bootloader. User must unplug/replug to boot
# the new firmware. (--after hard_reset gets stuck in download mode when
# bootloader was entered manually via BOOT button on USB-Serial-JTAG.)
info "Flashing firmware..."
python3 "$ESPTOOL" \
    --chip esp32s3 \
    --port "$UPLOAD_PORT" \
    --baud 460800 \
    --before no_reset \
    --after no_reset \
    write_flash -z \
    --flash_mode dio \
    --flash_freq 80m \
    --flash_size 8MB \
    0x0000 "$BUILD_DIR/bootloader.bin" \
    0x8000 "$BUILD_DIR/partitions.bin" \
    0x10000 "$BUILD_DIR/$FW_BIN"

ok "Flash complete"

# Prompt user to power-cycle so the new firmware actually starts
echo ""
echo -e "  ${YELLOW}Now UNPLUG the USB cable, wait 3 seconds, and plug it back in${NC}"
echo -e "  ${YELLOW}(do NOT hold any button — we want it to boot the new firmware).${NC}"
echo ""
read -rp "  Press Enter once you've replugged..."
info "Waiting for board to boot..."
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
