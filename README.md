# Bluetooth on Xpenology/Arc DSM 7.4.1 (epyc7002, kernel 5.10.55+)

How to get working Bluetooth (`hci0`, `btusb`, BlueZ on top) on an
Xpenology/Arc Loader DSM VM. Neither Synology's nor AuxXxilium's kernel
config enables `CONFIG_BT`, and no Bluetooth modules exist anywhere on the
system. The fix is to build them out of tree against the exact kernel, and
load them.

**Status (September 2026):**
- **Build:** `build-modules.sh` reproduces the modules exactly. A rebuild
  matched the `srcversion` of all eight versioned modules, the compiled-in
  features, the vermagic and the USB id table of the set running on the box.
- **Real use:** since September 18 the modules have been driving a TP-Link
  UB500 dongle passed through from Proxmox. A BlueZ + `bleak` client reads
  a BLE scale with them (see
  [xiaomi-scale-s200-ble](https://github.com/faraga1/xiaomi-scale-s200-ble)).
- **Loading at boot:** verified from a container. The host systemd approach
  is **untested** (see [Loading the modules at boot](#loading-the-modules-at-boot)).

## Quick start

```bash
# 1. build (needs Docker, ~10 GB for the toolkit image; fine to run on DSM itself)
DOCKER="sudo docker" ./build-modules.sh          # -> out/*.ko

# 2. check they're for your kernel
uname -r                                          # 5.10.55+
modinfo -F vermagic out/bluetooth.ko              # 5.10.55+ SMP mod_unload

# 3. load
sudo ./load-modules.sh out
ls /sys/class/bluetooth                           # hci0, once an adapter is attached
```

Then make them load at every boot; see below.

## Why DSM needs this

Bluetooth has two layers:

1. **Kernel:** `bluetooth.ko`, `btusb.ko` and friends. These must be
   compiled for the exact running kernel. There's no generic `.ko`.
2. **Userspace:** `bluetoothd`, D-Bus. Normal, installable, or simply run
   inside a container that brings its own.

DSM ships neither, and there's no package or setting that adds the kernel
part: `CONFIG_BT` was never enabled when the kernel was built. That also
means the kernel's ECDH crypto module is missing, which Bluetooth needs.

## Step 1: know your kernel

```bash
cat /proc/version      # Linux version 5.10.55+ (AuxXxilium@Xpenology) ...
uname -r               # 5.10.55+
ls /lib/modules | wc -l   # DSM keeps .ko files directly in /lib/modules (no $(uname -r)/ subdir)
```

On this box the kernel is AuxXxilium's build for the Arc Loader, not
Synology's own. Arc also ships ~670 extra modules. Its version string and
configuration match Synology's epyc7002 kernel closely enough that modules
built against Synology's epyc7002 build tree load and run fine, as long as
the vermagic (`5.10.55+ SMP mod_unload`) matches.

**Only the vermagic is checked.** These kernels are built without
`CONFIG_MODVERSIONS`, so there are no per-symbol checksums. A loader update
that ships a rebuilt `5.10.55+` kernel with a different configuration would
still accept old modules, even if the internals they rely on changed.
**Rebuild the modules after any Arc loader/kernel update.** The build takes
a couple of minutes.

## Step 2: build — `build-modules.sh`

What it does:

- **Toolchain and kernel tree:** AuxXxilium's
  [`auxxxilium/syno-compiler:7.4`](https://github.com/AuxXxilium/syno-compiler)
  image. It contains Synology's epyc7002 kernel build tree (`.config`,
  headers, `Module.symvers`, prebuilt build tools) and the matching GCC 12
  cross toolchain.
- **Sources:** the build tree has no Bluetooth sources, so they come from
  upstream Linux **5.10.55** (kernel.org, checksum-verified). Only
  `net/bluetooth`, `drivers/bluetooth` and the ECC/ECDH files from
  `crypto/` are used.
- **Config:** the kernel's own config is left untouched, because
  regenerating it would also change the headers every module shares with
  the running kernel. The Bluetooth options are instead passed to this build
  only, in two forms: as make variables for the Makefiles, and as `-D`
  defines for the `IS_ENABLED()`/`#ifdef` checks in the code. That's the
  same mechanism the image's own `compile-module` command uses. The options
  mirror the upstream defaults, plus Realtek/Broadcom/MediaTek support in
  `btusb`:
  - `m`: `BT`, `BT_RFCOMM`, `BT_BNEP`, `BT_HIDP`, `BT_HCIBTUSB`,
    `BT_INTEL`, `BT_BCM`, `BT_RTL`, `CRYPTO_ECC`, `CRYPTO_ECDH`
  - `y`: `BT_BREDR`, `BT_LE`, `BT_HS`, `BT_DEBUGFS`, `BT_RFCOMM_TTY`,
    `BT_BNEP_MC_FILTER`, `BT_BNEP_PROTO_FILTER`, `BT_HCIBTUSB_BCM`,
    `BT_HCIBTUSB_RTL`, `BT_HCIBTUSB_MTK`
- **Output:** 10 modules in `out/`, debug info stripped (~1.4 MB in total).

**Other 5.10.55 platforms** in the same image (`geminilakenk`, `v1000nk`,
`r1000nk`, `epyc7003`...) should work with `PLATFORM=<name>`, but that's
untested. Platforms on kernel 4.4 need 4.4 sources and different options.

## Step 3: load order

```
ecc -> ecdh_generic -> bluetooth -> btintel, btbcm, btrtl -> btusb
                       bluetooth -> bnep, hidp, rfcomm
```

`load-modules.sh` loads them in this order and skips any already loaded.
For BLE only, `bnep`/`hidp`/`rfcomm` aren't needed (they're for Classic
networking, input devices and serial), but they're cheap to load.

**Never use `insmod -f` / `modprobe --force-vermagic`.** A refused module
was built for a different kernel; forcing it in risks a kernel panic instead
of a clean error. Load one module at a time and check `dmesg` if anything is
off. The first unsigned, out-of-tree module after a boot makes the kernel log
that it's now tainted; that's expected.

## Loading the modules at boot

DSM's own module directory is managed by the system, so these modules live
on a data volume and have to be loaded again after every boot.

**Verified: load them from the container that uses Bluetooth.** If whatever
needs Bluetooth runs in Docker anyway (e.g. a BlueZ + client container with
`--net=host --privileged`), let its entrypoint load the modules when `hci0`
is missing. Mount the module directory read-only, and add `kmod` to the
image. The container only starts once Docker and the data volumes are up,
so there's nothing to order at boot. This was tested by unloading every
Bluetooth module and restarting the container: it loaded all ten and
`hci0` came back.

```sh
# in the entrypoint, before starting bluetoothd; /bt-modules is the mounted module dir
if [ ! -e /sys/class/bluetooth/hci0 ]; then
  for m in ecc ecdh_generic bluetooth btintel btbcm btrtl btusb bnep hidp rfcomm; do
    grep -q "^$m " /proc/modules || insmod /bt-modules/$m.ko
  done
fi
```

A complete example is the `entrypoint.sh` in
[xiaomi-scale-s200-ble](https://github.com/faraga1/xiaomi-scale-s200-ble).

**Untested: a host systemd unit** (`systemd/example-bluetooth-modules.service`).
The first version of this repo shipped a unit that couldn't have worked
reliably. It ordered itself before `docker.service`, a unit that doesn't
exist on DSM 7.4 (Docker is `pkg-ContainerManager-dockerd.service`). It
also didn't wait for the volume its script lives on. And because the box
hadn't rebooted since, it had never actually run. The example now waits
for the volume with `RequiresMountsFor=` (`/volumeN` is in `/etc/fstab` on
DSM 7.4, so systemd has a mount unit for it) and orders itself before the
real Docker unit. It still hasn't been through a reboot, and DSM updates
may not preserve files in `/etc/systemd/system`.

## Getting the adapter to the VM (Proxmox)

```bash
lsusb                                   # on the Proxmox host; TP-Link UB500 = 2357:0604
qm set <vmid> -usb1 host=2357:0604      # use a free usbN slot
```

**Firmware: this only works thanks to the Proxmox host.** The UB500 is a
Realtek RTL8761BU. On the DSM side, two things are missing:

- kernel 5.10's `btusb` doesn't list the UB500's USB id as Realtek (that was
  added in a later kernel), so it never runs the Realtek setup;
- DSM has no `rtl_bt/` firmware anyway.

The dongle still runs Realtek's patched firmware. Proxmox's own kernel
uploads `rtl_bt/rtl8761bu_fw.bin` when it first binds the dongle at boot,
and the dongle keeps it when the VM takes it over. You can check this in
the guest:

```bash
hciconfig hci0 version    # Revision: 0xdfc6, Subversion: 0xd922  = patched fw 0xdfc6d922
                          # Subversion 0x8761 would mean bare ROM firmware
```

On bare-metal Xpenology, or if the host never binds the dongle before the VM
starts, the dongle would run its ROM firmware. That's untested, and
Realtek's ROM firmware is generally less reliable. The fix would be adding
the UB500's id to `btusb` with `BTUSB_REALTEK`, and providing the firmware
file.

## Files

- `build-modules.sh`: reproducible build (see Step 2).
- `load-modules.sh`: loads the modules in order: `sudo ./load-modules.sh <dir>`.
- `systemd/example-bluetooth-modules.service`: boot-time unit, **untested**
  (see above).

## Prior art

- [kcsoft/synology-bluetooth](https://github.com/kcsoft/synology-bluetooth):
  the same technique for Synology's DSM 7.1/7.2 kernels (4.4, geminilake).
- [AuxXxilium/syno-compiler](https://github.com/AuxXxilium/syno-compiler) and
  [AuxXxilium/arc](https://github.com/AuxXxilium/arc): the toolkit image and
  the loader.
