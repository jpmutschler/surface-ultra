# Zadig presets for Quarch Torridon (ARM64)

Quarch's Torridon USB driver (v1.0.5) is a WinUSB package, but its INF only has x86/amd64/ia64 sections, so it won't install on ARM64. The device itself only needs the inbox `winusb.sys`. These presets bind WinUSB with Quarch's device interface GUID `{B5656C5D-5F67-4ACE-BA3B-E8906DEE3538}`, which Quarch software uses to find the device.

1. Plug in the Torridon module.
2. Run [Zadig](https://zadig.akeo.ie/). It's an x86 build that runs under emulation; use a release whose libwdi supports ARM64.
3. Device > Load Preset Device > the `.cfg` whose PID matches Device Manager (VID 16D0).
4. Pick **WinUSB** and click Install Driver. Zadig signs the generated package with a local certificate.
5. Open Quarch Power Studio (x64, runs under Prism) and check that it sees the module.

If it doesn't, ask Quarch for an ARM64 build of the driver, or run the Torridon from a lab x64 host.
