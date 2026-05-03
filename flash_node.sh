#!/bin/bash
#
# flash_node.sh — Universal flash script for microReticulum RNode firmware
#
# Supports all boards in Boards.h. Handles ESP32, ESP32-S3, and nRF52 platforms.
# Always erases flash before writing. Pauses for manual reset before provisioning.
#
# Usage:
#   ./flash_node.sh --board <BOARD> --port <PORT> [OPTIONS]
#
# Required:
#   --board <BOARD>     Target board (see --list-boards)
#   --port <PORT>       Serial port (e.g. /dev/ttyUSB0, /dev/cu.usbserial-0001)
#
# Options:
#   --band <BAND>       Frequency band: 433, 868, 915 (default: 868)
#   --gpio              Enable GPIO control via LXMF messages
#   --transport         Enable Reticulum transport mode
#   --name <NAME>     Node display name for LXMF announces (default: "RNode")
#   --txp <dBm>         TX power in dBm (default: 14)
#   --sf <SF>           Spreading factor (default: 7)
#   --cr <CR>           Coding rate (default: 5)
#   --bw <BW>           Bandwidth in Hz (default: depends on band)
#   --list-boards       Show all supported boards and exit
#   --dry-run           Show what would be done without executing
#   --help              Show this help
#
# Examples:
#   ./flash_node.sh --board lora32-v1 --port /dev/cu.usbserial-0001 --gpio --name "Garden Node"
#   ./flash_node.sh --board tbeam --port /dev/ttyUSB0 --band 915 --transport
#   ./flash_node.sh --board xiao-nrf52 --port /dev/ttyACM0 --band 868 --gpio
#   ./flash_node.sh --board heltec-v3 --port /dev/ttyUSB0 --transport --name "Relay 1"
#   ./flash_node.sh --list-boards
#

set -euo pipefail

# ─── Cleanup trap ────────────────────────────────────────────────
# Restore patched source files if script is interrupted during build
cleanup() {
    if [[ -f "RNode_Firmware.ino.flash_backup" ]]; then
        mv -f RNode_Firmware.ino.flash_backup RNode_Firmware.ino
        echo -e "\n${YELLOW}[WARN]${NC} Restored RNode_Firmware.ino from backup"
    fi
}
trap cleanup EXIT

# ─── Colors ──────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}"; }

# ─── Board Registry ─────────────────────────────────────────────
#
# Format: board_key|pio_env|mcu|product|model_433|model_868|variant|description
#
# MCU types: esp32, esp32s3, nrf52
# Product/model codes are hex values for rnodeconf --rom
#
BOARDS=(
    "lora32-v1|ttgo-lora32-v1|esp32|B2|BA|BB|lora32v10|TTGO LoRa32 V1.0"
    "lora32-v2|ttgo-lora32-v2|esp32|B0|B3|B8|lora32v20|TTGO LoRa32 V2.0"
    "lora32-v21|ttgo-lora32-v21|esp32|B1|B4|B9|lora32v21|TTGO LoRa32 V2.1"
    "tbeam|ttgo-t-beam|esp32|E0|E4|E9|tbeam|LilyGO T-Beam (SX1276)"
    "tbeam-sx1262|ttgo-t-beam-sx1262|esp32|E0|E3|E8|tbeam_sx1262|LilyGO T-Beam (SX1262)"
    "heltec-v2|heltec_wifi_lora_32_V2|esp32|C0|C4|C9|heltec32v2|Heltec LoRa32 V2"
    "heltec-v3|heltec_wifi_lora_32_V3|esp32s3|C1|C5|CA|heltec32v3|Heltec LoRa32 V3"
    "wsl-v1|heltec_wsl_v1|esp32|C5|CB|CC|heltec_wsl_v1|Heltec Wireless Stick Lite V1"
    "rnode-ng-20|rnode-ng-20|esp32|B0|B3|B8|ng20|RNode NG 2.0"
    "rnode-ng-21|rnode-ng-21|esp32|B1|B4|B9|ng21|RNode NG 2.1"
    "rnode-ng-22|rnode-ng-22|esp32s3|C1|C5|CA|ng22|RNode NG 2.2"
    "rak4631|wiscore_rak4631|nrf52|10|11|12|rak4631|RAK4631"
    "xiao-nrf52|xiao_nrf52840|nrf52|11|11|12|xiao_nrf52840|Seeed XIAO nRF52840 + Wio-SX1262"
    "huzzah32|featheresp32|esp32|F0|FF|FE|featheresp32|Adafruit Feather HUZZAH32"
    "generic-esp32|generic-esp32|esp32|F0|FF|FE|esp32_generic|Generic ESP32 + SX127x"
)

# ─── Helpers ─────────────────────────────────────────────────────

list_boards() {
    echo ""
    echo -e "${BOLD}Supported boards:${NC}"
    echo ""
    printf "  ${BOLD}%-16s %-8s %-40s${NC}\n" "BOARD KEY" "MCU" "DESCRIPTION"
    printf "  %-16s %-8s %-40s\n" "----------------" "--------" "----------------------------------------"
    for entry in "${BOARDS[@]}"; do
        IFS='|' read -r key env mcu prod m433 m868 variant desc <<< "$entry"
        printf "  %-16s %-8s %s\n" "$key" "$mcu" "$desc"
    done
    echo ""
    echo "  Usage: ./flash_node.sh --board <BOARD_KEY> --port <PORT> [OPTIONS]"
    echo ""
}

get_board_field() {
    local board_key="$1"
    local field_num="$2"
    for entry in "${BOARDS[@]}"; do
        IFS='|' read -r key rest <<< "$entry"
        if [[ "$key" == "$board_key" ]]; then
            echo "$entry" | cut -d'|' -f"$field_num"
            return 0
        fi
    done
    return 1
}

validate_board() {
    local board_key="$1"
    for entry in "${BOARDS[@]}"; do
        IFS='|' read -r key rest <<< "$entry"
        if [[ "$key" == "$board_key" ]]; then
            return 0
        fi
    done
    return 1
}

# Calculate firmware hash correctly per platform
# ESP32: SHA256 of firmware minus last 32 bytes (embedded hash)
# nRF52: SHA256 of entire .bin extracted from .zip
calc_firmware_hash() {
    local bin_path="$1"
    local mcu="$2"

    if [[ "$mcu" == "nrf52" ]]; then
        # nRF52: hash entire binary
        shasum -a 256 "$bin_path" | cut -d' ' -f1
    else
        # ESP32/ESP32-S3: hash everything except last 32 bytes (embedded hash)
        python3 -c "
import hashlib, sys
data = open('$bin_path', 'rb').read()
print(hashlib.sha256(data[:-32]).hexdigest())
"
    fi
}

prompt_reset() {
    local msg="${1:-Press RESET on the board, then press Enter to continue...}"
    echo ""
    echo -e "  ${YELLOW}>>> ${msg} <<<${NC}"
    echo ""
    read -r
}

run_cmd() {
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${CYAN}[DRY-RUN]${NC} $*"
    else
        "$@"
    fi
}

# ─── Parse Arguments ─────────────────────────────────────────────

BOARD=""
PORT=""
BAND="868"
GPIO=false
TRANSPORT=false
NODE_NAME="RNode"
TXP="14"
SF="7"
CR="5"
BW=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --board)     BOARD="$2"; shift 2 ;;
        --port)      PORT="$2"; shift 2 ;;
        --band)      BAND="$2"; shift 2 ;;
        --gpio)      GPIO=true; shift ;;
        --transport) TRANSPORT=true; shift ;;
        --name)      NODE_NAME="$2"; shift 2 ;;
        --txp)       TXP="$2"; shift 2 ;;
        --sf)        SF="$2"; shift 2 ;;
        --cr)        CR="$2"; shift 2 ;;
        --bw)        BW="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --list-boards) list_boards; exit 0 ;;
        --help|-h)
            head -35 "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            echo "  Use --help for usage information."
            exit 1
            ;;
    esac
done

# ─── Validate Inputs ────────────────────────────────────────────

if [[ -z "$BOARD" ]]; then
    err "Missing required --board argument."
    echo "  Use --list-boards to see available boards."
    exit 1
fi

if ! validate_board "$BOARD"; then
    err "Unknown board: '$BOARD'"
    echo "  Use --list-boards to see available boards."
    exit 1
fi

if [[ -z "$PORT" ]]; then
    err "Missing required --port argument."
    echo "  Example: --port /dev/ttyUSB0"
    exit 1
fi

if [[ ! "$BAND" =~ ^(433|868|915)$ ]]; then
    err "Invalid band: '$BAND'. Must be 433, 868, or 915."
    exit 1
fi

# ─── Resolve Board Config ───────────────────────────────────────

PIO_ENV=$(get_board_field "$BOARD" 2)
MCU=$(get_board_field "$BOARD" 3)
PRODUCT=$(get_board_field "$BOARD" 4)
MODEL_433=$(get_board_field "$BOARD" 5)
MODEL_868=$(get_board_field "$BOARD" 6)
VARIANT=$(get_board_field "$BOARD" 7)
BOARD_DESC=$(get_board_field "$BOARD" 8)

# Select model and frequency based on band
case "$BAND" in
    433)
        MODEL="$MODEL_433"
        FREQ="433775000"
        [[ -z "$BW" ]] && BW="125000"
        ;;
    868)
        MODEL="$MODEL_868"
        FREQ="869525000"
        [[ -z "$BW" ]] && BW="250000"
        ;;
    915)
        MODEL="$MODEL_868"  # 868 and 915 share the same model code
        FREQ="915000000"
        [[ -z "$BW" ]] && BW="250000"
        ;;
esac

# Firmware binary path
BUILD_DIR=".pio/build/$PIO_ENV"
if [[ "$MCU" == "nrf52" ]]; then
    FW_ZIP="$BUILD_DIR/rnode_firmware_${VARIANT}.zip"
    FW_BIN="$BUILD_DIR/rnode_firmware_${VARIANT}.bin"
else
    FW_BIN="$BUILD_DIR/rnode_firmware_${VARIANT}.bin"
fi

# ─── Check Prerequisites ────────────────────────────────────────

step "Checking prerequisites"

MISSING=()
command -v pio &>/dev/null        || MISSING+=("platformio (pip install platformio)")
command -v rnodeconf &>/dev/null  || MISSING+=("rnodeconf (pip install rns)")
command -v python3 &>/dev/null    || MISSING+=("python3")

if [[ "$MCU" == "nrf52" ]]; then
    command -v adafruit-nrfutil &>/dev/null || MISSING+=("adafruit-nrfutil (pip install adafruit-nrfutil)")
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
    err "Missing required tools:"
    for tool in "${MISSING[@]}"; do
        echo "  - $tool"
    done
    exit 1
fi

ok "All tools found"

# ─── Build Extra Flags ──────────────────────────────────────────

EXTRA_BUILD_FLAGS=""

if [[ "$GPIO" == true ]]; then
    EXTRA_BUILD_FLAGS="$EXTRA_BUILD_FLAGS -DHAS_GPIO_CONTROL"
fi

if [[ "$TRANSPORT" == true ]]; then
    EXTRA_BUILD_FLAGS="$EXTRA_BUILD_FLAGS -DTRANSPORT_ENABLED"
fi

# WSL V1 needs RNS explicitly enabled (disabled by default in upstream)
if [[ "$BOARD" == "wsl-v1" ]]; then
    if [[ "$GPIO" == true ]] || [[ "$TRANSPORT" == true ]]; then
        EXTRA_BUILD_FLAGS="$EXTRA_BUILD_FLAGS -DHAS_RNS -DRNS_USE_FS"
        info "Enabling RNS for Heltec WSL V1 (required for GPIO/transport)"
    fi
fi

# ─── Summary ────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}┌──────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│           microReticulum Flash Script             │${NC}"
echo -e "${BOLD}└──────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "  Board:       ${BOLD}$BOARD_DESC${NC}"
echo -e "  MCU:         $MCU"
echo -e "  PIO env:     $PIO_ENV"
echo -e "  Port:        $PORT"
echo -e "  Band:        ${BAND} MHz"
echo -e "  Product:     0x$PRODUCT"
echo -e "  Model:       0x$MODEL"
echo -e "  Frequency:   $FREQ Hz"
echo -e "  Bandwidth:   $BW Hz"
echo -e "  SF: $SF  CR: $CR  TXP: ${TXP} dBm"
echo -e "  GPIO:        $([ "$GPIO" == true ] && echo -e "${GREEN}enabled${NC}" || echo "disabled")"
echo -e "  Transport:   $([ "$TRANSPORT" == true ] && echo -e "${GREEN}enabled${NC}" || echo "disabled")"
echo -e "  Node name:   $NODE_NAME"
if [[ -n "$EXTRA_BUILD_FLAGS" ]]; then
    echo -e "  Extra flags: $EXTRA_BUILD_FLAGS"
fi
echo ""

if [[ "$DRY_RUN" == true ]]; then
    warn "DRY RUN — no commands will be executed"
    echo ""
fi

echo -e "  ${YELLOW}This will ERASE the flash and reprogram the device.${NC}"
echo -e "  Press Enter to continue, or Ctrl+C to abort..."
read -r

# ═══════════════════════════════════════════════════════════════
# STEP 1: Clean build
# ═══════════════════════════════════════════════════════════════

step "Step 1: Clean build"

info "Removing previous build artifacts..."
run_cmd rm -rf ".pio/build/$PIO_ENV"

# Patch node name in source if custom name provided
if [[ "$NODE_NAME" != "RNode" ]] && [[ "$GPIO" == true ]]; then
    # Patch the default name in RNode_Firmware.ino
    if grep -q 'gpio_control.init(gpio_identity' RNode_Firmware.ino 2>/dev/null; then
        info "Patching node name to: $NODE_NAME"
        sed -i.flash_backup 's/gpio_control\.init(gpio_identity, "[^"]*")/gpio_control.init(gpio_identity, "'"$NODE_NAME"'")/' RNode_Firmware.ino
    else
        warn "Could not find gpio_control.init() in RNode_Firmware.ino — name not patched"
    fi
fi

# Build with extra flags via PLATFORMIO_BUILD_FLAGS env var
if [[ -n "$EXTRA_BUILD_FLAGS" ]]; then
    info "Extra build flags:$EXTRA_BUILD_FLAGS"
    export PLATFORMIO_BUILD_FLAGS="$EXTRA_BUILD_FLAGS"
fi

run_cmd pio run -e "$PIO_ENV"

# Restore source immediately after build (also handled by cleanup trap)
if [[ -f "RNode_Firmware.ino.flash_backup" ]]; then
    mv -f RNode_Firmware.ino.flash_backup RNode_Firmware.ino
    info "Source restored (node name patch was build-time only)"
fi

ok "Build complete"

# ═══════════════════════════════════════════════════════════════
# STEP 2: Erase flash
# ═══════════════════════════════════════════════════════════════

step "Step 2: Erase flash"

if [[ "$MCU" == "nrf52" ]]; then
    info "nRF52 flash erase happens during upload (softdevice reflash)"
    info "If the device has existing firmware, double-tap the reset button to enter bootloader."
    prompt_reset "Put the board in bootloader mode (double-tap reset), then press Enter"
else
    info "Erasing entire flash..."
    run_cmd pio run -e "$PIO_ENV" -t erase --upload-port "$PORT"
    ok "Flash erased"
    echo ""
    info "Wait for the board to reset after erase."
    sleep 3
fi

# ═══════════════════════════════════════════════════════════════
# STEP 3: Upload filesystem (ESP32 only)
# ═══════════════════════════════════════════════════════════════

if [[ "$MCU" != "nrf52" ]]; then
    step "Step 3: Upload LittleFS filesystem"
    info "This formats the LittleFS partition and creates /cache/..."
    run_cmd pio run -e "$PIO_ENV" -t uploadfs --upload-port "$PORT"
    ok "Filesystem uploaded"
    sleep 2
else
    step "Step 3: Skipped (nRF52 uses InternalFS, no separate filesystem upload)"
fi

# ═══════════════════════════════════════════════════════════════
# STEP 4: Upload firmware
# ═══════════════════════════════════════════════════════════════

step "Step 4: Upload firmware"

if [[ "$MCU" == "nrf52" ]]; then
    info "Uploading nRF52 firmware via adafruit-nrfutil (DFU)..."
else
    info "Uploading ESP32 firmware via esptool..."
fi

if [[ -n "$EXTRA_BUILD_FLAGS" ]]; then
    export PLATFORMIO_BUILD_FLAGS="$EXTRA_BUILD_FLAGS"
fi

run_cmd pio run -e "$PIO_ENV" -t upload --upload-port "$PORT"

ok "Firmware uploaded"

# ═══════════════════════════════════════════════════════════════
# STEP 5: Wait for boot + prompt for reset
# ═══════════════════════════════════════════════════════════════

step "Step 5: Waiting for device boot"

info "The device needs to boot with the new firmware before provisioning."
info "You should see serial output indicating the device has started."
echo ""

if [[ "$MCU" == "nrf52" ]]; then
    prompt_reset "The nRF52 should have rebooted automatically. Press Enter when ready"
else
    prompt_reset "Press RESET on the board now, wait for boot, then press Enter"
fi

# ═══════════════════════════════════════════════════════════════
# STEP 6: Provision ROM
# ═══════════════════════════════════════════════════════════════

step "Step 6: Provision ROM"

info "Writing product=0x$PRODUCT model=0x$MODEL hwrev=1"
run_cmd rnodeconf "$PORT" --rom --product "$PRODUCT" --model "$MODEL" --hwrev 1
ok "ROM provisioned"

sleep 3

# ═══════════════════════════════════════════════════════════════
# STEP 7: Set firmware hash
# ═══════════════════════════════════════════════════════════════

step "Step 7: Setting firmware hash"

if [[ "$MCU" == "nrf52" ]]; then
    # nRF52: extract .bin from .zip, hash entire file
    if [[ -f "$FW_ZIP" ]]; then
        info "Extracting .bin from .zip for hashing..."
        run_cmd unzip -o "$FW_ZIP" "rnode_firmware_${VARIANT}.bin" -d "$BUILD_DIR"
    fi
    if [[ -f "$FW_BIN" ]]; then
        HASH=$(calc_firmware_hash "$FW_BIN" "$MCU")
    else
        err "Firmware binary not found at $FW_BIN"
        warn "You may need to set the firmware hash manually:"
        echo "  rnodeconf --firmware-hash <HASH> $PORT"
        HASH=""
    fi
else
    # ESP32: hash firmware minus last 32 bytes
    if [[ -f "$FW_BIN" ]]; then
        HASH=$(calc_firmware_hash "$FW_BIN" "$MCU")
    else
        err "Firmware binary not found at $FW_BIN"
        warn "You may need to set the firmware hash manually."
        HASH=""
    fi
fi

if [[ -n "${HASH:-}" ]]; then
    info "Hash: $HASH"
    run_cmd rnodeconf --firmware-hash "$HASH" "$PORT"
    ok "Firmware hash set"
else
    warn "Skipping firmware hash — set it manually later"
fi

sleep 3

# ═══════════════════════════════════════════════════════════════
# STEP 8: Enable TNC mode
# ═══════════════════════════════════════════════════════════════

step "Step 8: Enable TNC mode"

info "Configuring: freq=$FREQ bw=$BW sf=$SF cr=$CR txp=$TXP"
run_cmd rnodeconf "$PORT" --tnc --freq "$FREQ" --bw "$BW" --sf "$SF" --cr "$CR" --txp "$TXP"
ok "TNC mode enabled"

sleep 2

# ═══════════════════════════════════════════════════════════════
# STEP 9: Verify
# ═══════════════════════════════════════════════════════════════

step "Step 9: Verify device"

run_cmd rnodeconf "$PORT" -i

# ═══════════════════════════════════════════════════════════════
# Done!
# ═══════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}${GREEN}┌──────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}${GREEN}│                 Flash Complete!                   │${NC}"
echo -e "${BOLD}${GREEN}└──────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "  Board:     ${BOLD}$BOARD_DESC${NC}"
echo -e "  Band:      ${BAND} MHz"
echo -e "  Node name: $NODE_NAME"
echo -e "  GPIO:      $([ "$GPIO" == true ] && echo "enabled" || echo "disabled")"
echo -e "  Transport: $([ "$TRANSPORT" == true ] && echo "enabled" || echo "disabled")"
echo ""
echo -e "  Monitor serial output with:"
echo -e "    ${CYAN}tio $PORT${NC}"
echo ""

if [[ "$GPIO" == true ]]; then
    echo -e "  ${BOLD}GPIO Control:${NC}"
    echo -e "    The LXMF address will appear in serial output after boot."
    echo -e "    Send commands from Sideband using ${BOLD}opportunistic${NC} delivery:"
    echo -e "      PINS    — list available GPIO pins"
    echo -e "      SET <pin> HIGH/LOW"
    echo -e "      GET <pin>"
    echo -e "      STATUS  — all pin states"
    echo ""
fi

if [[ "$TRANSPORT" != true ]]; then
    echo -e "  ${BOLD}Reticulum config (~/.reticulum/config):${NC}"
    echo ""
    echo -e "    [[${NODE_NAME// /_}]]"
    echo -e "      type = RNodeInterface"
    echo -e "      interface_enabled = true"
    echo -e "      port = $PORT"
    echo -e "      frequency = $FREQ"
    echo -e "      bandwidth = $BW"
    echo -e "      txpower = $TXP"
    echo -e "      spreadingfactor = $SF"
    echo -e "      codingrate = $CR"
    echo ""
fi
