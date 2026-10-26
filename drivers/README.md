# Vendor drivers (ARM64), staged here and not committed

`scripts/30-HilDrivers.ps1` installs every `.inf` under this folder that declares an `NTarm64` section, and skips x64-only ones with a warning. Zips dropped straight into this folder are unpacked automatically.

Links checked 2026-10-08.

| Folder | Package | Where to get it | Status |
| --- | --- | --- | --- |
| `ftdi/` | FTDI CDM **2.12.36.20A** (Desktop, ARM64, 2025-03-04). Includes VCP and D2XX. Or **2.12.36.20UA** (Universal). | [ftdichip.com/drivers/d2xx-drivers](https://ftdichip.com/drivers/d2xx-drivers/): Windows row, **ARM** column. The site has no ARM64 setup .exe, so unzip the INF package. | Supported |
| `ftdi-fallback/` | FTDI CDM 2.12.36.4 ARM64 (2022), a known-good direct link | https://ftdichip.com/wp-content/uploads/2022/02/CDM-v2.12.36.4-for-ARM64-Signed-Distributable.zip | Older but proven |
| `wch/` | WCH CH343SER (CH343 / CH9102) | [wch-ic.com/downloads/CH343SER_ZIP.html](http://www.wch-ic.com/downloads/CH343SER_ZIP.html) | ARM64 not confirmed. Check whether the zip has an ARM64 INF. |
| `cp210x/` | Silicon Labs CP210x Universal **10.1.4** (2018, the last release listing ARM64) | [Release notes](https://www.silabs.com/documents/public/release-notes/CP210x_Universal_Windows_Driver_ReleaseNotes.txt) and [SiLabs legacy packages](https://community.silabs.com/s/article/legacy-os-software-and-driver-packages?language=en_US) | **Current 11.6.0 (Sep 2026) is x64/x86 only.** Avoid CP210x-based adapters on this laptop if you can. |
| (zip as-is) | Quarch Torridon USB driver v1.0.5 | Already staged. It's a WinUSB package with **no ARM64 section**. | Bind WinUSB with the presets in `tools/zadig/` |
| (none) | Total Phase Aardvark / Promira / Beagle | [totalphase.com/products/usb-drivers](https://www.totalphase.com/products/usb-drivers) lists 32/64-bit x86 only | **Ask Total Phase** |

Install notes:

- FTDI's INFs are in the `ARM64` (or `ARM64\Release`) subfolder: `FTDIBUS.inf` (the USB layer) and `FTDIPORT.inf` (the COM port layer). Both need to be installed.
- **D2XX DLL architecture must match the process.** Native ARM64 Python loads the ARM64 `ftd2xx.dll`. An x64 vendor app running under Prism emulation needs an x64 `ftd2xx.dll` and will fail to load the ARM64 one. This is a known FTDI-on-ARM issue.
- USB CDC-ACM devices (your Renesas MCU firmware, Binho Nova) use the inbox `usbser.sys` and need nothing here.
- WinUSB devices (pyusb/pyftdi with custom firmware) use the inbox `winusb.sys`. Zadig is x86-only but runs under emulation to bind it.
