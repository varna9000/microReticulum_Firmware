# microReticulum_Firmware

Fork of RNode_Firmware with integration of the [microReticulum](https://github.com/attermann/microReticulum) Network Stack to implement a completeley self-contained standalone Reticulum node.

> **Custom Board Support:** For build, flash, and provisioning instructions for the **Seeed XIAO nRF52840 + Wio-SX1262**, **Seeed XIAO ESP32-S3 + Wio-SX1262**, **Heltec Wireless Stick Lite V1**, and **TTGO LoRa32 V1** boards, see [CUSTOM_BOARDS.md](CUSTOM_BOARDS.md).

## Installation

This firmware can be easily installed on devices in the same way as RNode using the new `fw-url` switch to `rnodeconf` which allows firmware images to be pulled from an alternate repository. RNS may need to be updated to the latest version to use this new switch.

The latest version of this firmware can be installed in the usual RNode way with the following command:
```
rnodeconf --autoinstall --fw-url https://github.com/attermann/microReticulum_Firmware/releases/
```

## Enabling Transport Mode

By default this firmware will operate just like any other RNode firmware allowing it to be used as just a radio by RNS installed on an attached machine.

To enable `Transport Mode` using the RNS embedded on the device, the device must be switched to TNC mode using a command like the following:
```
rnodeconf --tnc --freq 915000000 --bw 125000 --sf 8 --cr 5 --txp 17 /dev/ttyACM0
```
When in `Transport Mode`, the device will display a row of "TTTTTTTTTTT" across the top of the AirTime panel of the display to indicate that the embedded RNS is active and routing packets.

Note that at the present time, when in TNC mode this firmware does not operate like a regular RNode does when in TNC mode due to logging from the embedded RNS that is output on the serial port. This can clobber KISS communication from the attached machine so do not attempt to attach another RNS to the device while in this mode. On the plus side, there is extensive logging available on the serial port to observe the embedded RNS in action and to aid in troubleshooting.

## Build Dependencies

Build environment is configured for use in [VSCode](https://code.visualstudio.com/) and [PlatformIO](https://platformio.org/).

## Building from Source

Building and uploading to hardware is simple through the VSCode PlatformIO IDE
- Install VSCode and PlatformIO
- Clone this repo
- Lanch PlatformIO and load repo
- In PlatformIO, select the environment for intended board
- Build, Upload, and Monitor to observe application logging

Uploading to devices requires access to the `rnodeconf` utility included in the official [Reticulum](https://github.com/markqvist/Reticulum) distribution to update the device firmware hash. Without this step the device will report invalid firmware and will fail to fully initialize.

Instructions for command line builds and packaging for firmware distribution.

## Solar / Battery Operation (XIAO nRF52840)

Brownout during a flash write can corrupt the on-chip LittleFS at a level deeper
than `Adafruit_LittleFS::begin()`'s auto-format can recover from, which on a
naive build manifests as a permanent reboot loop (~3s cycle, `EEPROM
initialisation failed.` on each boot, LFS assertion at `lfs.c:1144`).

The firmware now self-heals from this on the next boot:

1. `-DLFS_NO_ASSERT` makes LittleFS return `LFS_ERR_CORRUPT` instead of
   `abort()`-ing on an internal sanity check.
2. `eeprom_begin()` runs an explicit `InternalFS.format()` + retry whenever
   either the mount or the subsequent file-open step fails.
3. `FileSystem::init()` (RNS side) does the same on its mount path.
4. RNS startup and the identity-restore block are gated on `fs_ready`, so a
   still-unmountable FS can't crash the boot.
5. Identity keys are preserved across formatting via the raw-flash backup at
   `0xEC000` (outside the LittleFS region) — the node keeps its RNS address.

Recovery messages, if they fire, are prefixed `[EEPROM] …` and `[FS] …` on the
serial monitor. `[IDENTITY] Backup is current` on a healthy boot confirms the
raw-flash backup matches the live identity files.

## Roadmap

- [ ] Extend KISS interface to support config/control of the integrated stack
- [ ] Add interface for easy customization of firmware
- [ ] Add power management and sleep states to extend battery runtime
- [x] Add build targets for NRF52 boards
- [x] Auto-recover from brownout-induced LittleFS corruption on XIAO nRF52840

Please open an Issue if you have trouble building ior using the API, and feel free to start a new Discussion for anything else.
