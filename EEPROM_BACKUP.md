# EEPROM Raw Flash Backup (nRF52840)

## Problem

The nRF52840 has no hardware EEPROM. Provisioning and radio config are stored in
files on LittleFS (internal flash). When the xiao runs on solar power and the
battery dies, the sudden power loss can corrupt LittleFS metadata. On next boot,
LittleFS fails to mount, auto-formats itself, and all files are wiped — including
provisioning data. The device then reports "EEPROM not provisioned" and is
bricked until re-provisioned via `rnodeconf`.

## Solution

Critical EEPROM data is backed up to a raw flash page at `0xEC000`, one 4KB page
immediately before the LittleFS region (`0xED000`). This page is outside LittleFS
management, so it survives filesystem corruption and auto-formatting. It also
survives firmware updates (UF2 only writes to application pages).

### Flash memory layout

```
0x00000 - 0x26000   Bootloader / SoftDevice
0x26000 - 0xEC000   Application (firmware)
0xEC000 - 0xED000   EEPROM backup (raw flash, 4KB page)  <-- new
0xED000 - 0xF4000   LittleFS (InternalFS, 7 pages)
0xF4000 - 0x100000  Bootloader data
```

### Backup format

```
Offset 0x000: Magic bytes "RNBK" (4 bytes)
Offset 0x004: Version (1 byte, currently 0x01)
Offset 0x005: Reserved (3 bytes)
Offset 0x008: ROM data (EEPROM_SIZE bytes — provisioning, serial, signature)
Offset 0x008+EEPROM_SIZE: CONF data (EEPROM_SIZE bytes — radio config)
After data: Checksum (2 bytes, sum of all preceding bytes)
```

### When the backup is written

- When `ADDR_INFO_LOCK` is written (provisioning via `rnodeconf`)
- When `ADDR_CONF_OK` is written (radio config saved)

Both trigger through the existing `eeprom_flush_rom()` / `eeprom_flush_conf()`
functions in `Utilities.h`.

### When the backup is restored

On boot, if LittleFS has been auto-formatted (files are missing) and a valid
backup exists in raw flash, `eeprom_begin()` automatically restores
`eeprom_rom`, `eeprom_conf`, and `eeprom_defaults` from the backup.

### Files involved

- `Utilities.h` — backup read/write functions, modified `eeprom_begin()` and flush functions
- `Device.h` — documents the flash layout

### RX duty cycle fix

A related issue was also fixed: transport nodes were set to `POWER_MODE_BALANCED`
by default, which enables RX duty cycling. This caused the radio to miss incoming
packets (the node could transmit but not receive). Changed to
`POWER_MODE_PERFORMANCE` for transport nodes to ensure continuous RX.
