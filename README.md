# Bluetooth on Xpenology/Arc DSM 7.4.1 (AuxXxilium, epyc7002 platform)

How to get real Bluetooth kernel support (`hci0`, working `btusb`) inside
a **Xpenology/Arc Loader** DSM 7.4.1 VM — where Synology's own build has
`CONFIG_BT` disabled and no Bluetooth kernel modules exist anywhere on the
filesystem — by cross-compiling the missing modules as out-of-tree
`.ko` files against the *actual* kernel this platform runs, and loading
them at boot.

Confirmed working: `hci0` comes up, a USB Bluetooth dongle passed through
from the Proxmox host is recognized, and a real BLE GATT session
(`bluetoothd` + a Python `bleak` client) runs against it — see
[xiaomi-scale-s200-ble](https://github.com/faraga1/xiaomi-scale-s200-ble)
for what this was actually built for.

## Why this isn't as simple as `apt install bluez` or a DSM package

Bluetooth support has two independent layers, and DSM's own package
manager only ever gives you the second one:

1. **Kernel-level**: the `bluetooth`/`btusb`/etc. kernel modules, which
   have to be compiled *for the exact running kernel* (module ABI is
   version- and config-sensitive — there's no "generic" `.ko`).
2. **Userspace**: `bluez`/`bluetoothd`, D-Bus, etc. — this part is normal
   and installable the usual way (or, as here, just run inside a
   container that carries its own).

DSM never ships the kernel-level piece on this platform, and there is no
Control Panel toggle or package that adds it, because it was never built
in to begin with.

## Step 1: find out what kernel you're actually running

This matters more than it sounds. On this box, `/proc/version` and the
sheer number of extra third-party `.ko` files present (~670, which no
stock Synology image ships) revealed that **the running kernel is not
actually Synology's own build** — it's a custom kernel built by
**AuxXxilium** (the maintainer of the Arc Loader used to boot DSM under
Xpenology on non-Synology hardware). This is an important distinction:
Synology's *and* AuxXxilium's own published kernel `.config` both have
`CONFIG_BT` disabled, so Bluetooth was never compiled in by either party
— but knowing exactly which kernel and toolchain you're dealing with is
what makes cross-compiling against it *possible* rather than a guessing
game.

Identify yours the same way:

```bash
cat /proc/version
ls -1 /lib/modules/$(uname -r)/ 2>/dev/null | wc -l   # stock Synology ships far fewer .ko files
uname -r                                                # note the exact vermagic string, e.g. 5.10.55+
```

## Step 2: the toolchain

Kernel modules must be compiled with a toolchain that matches the exact
kernel the target actually runs — not the generic Synology DSM Toolkit,
which targets Synology's own stock kernel, not AuxXxilium's fork of it.
AuxXxilium publishes a matching build container image for exactly this
purpose:

```
auxxxilium/syno-compiler:7.4
```

Run it against AuxXxilium's own kernel source tree for your platform
(this NAS: `epyc7002`) to get a build environment whose headers/config
actually match what's running.

## Step 3: which modules, and in what order

`CONFIG_BT` being disabled means the *entire* Bluetooth subsystem is
missing, not just the USB driver — including its ECDH crypto dependency
(`CONFIG_CRYPTO_ECDH` is also off). Build and load these, strictly in
this order (`load-modules.sh` in this repo encodes it):

```
ecc.ko             -- ECC primitives, needed by ecdh_generic
ecdh_generic.ko     -- CONFIG_CRYPTO_ECDH's module form
bluetooth.ko        -- core net/bluetooth subsystem
btintel.ko          -- (only if relevant to your adapter's chipset)
btbcm.ko
btrtl.ko
btusb.ko             -- the actual USB HCI driver
bnep.ko              -- Bluetooth PAN
hidp.ko              -- Bluetooth HID
rfcomm.ko            -- Bluetooth serial
```

Dependency chain: `ecc → ecdh_generic → bluetooth → {btintel,btbcm,btrtl}
→ btusb`, and separately `bluetooth → {bnep,hidp,rfcomm}`. `btintel`/
`btbcm`/`btrtl` are vendor-specific chipset quirks-and-firmware-loading
modules for Intel/Broadcom/Realtek adapters respectively; a generic USB
dongle (this was verified with a TP-Link UB500) mostly just needs
`btusb`, but building all three is cheap and avoids guessing which one a
given adapter's chipset actually wants.

**Every module must vermagic-match your exact running kernel** (see Step
1) — `modinfo <module>.ko | grep vermagic` — or the kernel will refuse to
load it.

## Step 4: load them safely

**Never use `insmod -f` / `modprobe --force-vermagic`.** A vermagic
mismatch means the module was built for the wrong kernel; forcing it past
that check risks a kernel panic on a production VM, not a clean failure.
If a plain `insmod` rejects a module, that's the kernel correctly telling
you something is actually wrong (wrong kernel version, missing
dependency) — fix the real cause, don't bypass the check.

```bash
sudo ./load-modules.sh
dmesg -T | tail -30      # confirm each module loaded cleanly, check for hci0
hciconfig -a              # or: bluetoothctl list
```

`net/bluetooth` and `drivers/bluetooth` are mature, heavily-used mainline
kernel subsystems — this is a fundamentally lower-risk kind of module
load than, say, a GPU driver's probe path, but treat every `insmod` on a
live system deliberately regardless: load one module, check `dmesg`,
then move to the next.

## Step 5: boot persistence

These modules live outside `/lib/modules` (DSM's own module tree is
read-only/managed) and need to be reloaded on every boot. A oneshot
systemd unit that runs before `docker.service` (so any container
depending on the adapter, e.g. one running `bluetoothd` itself, starts
after Bluetooth is actually up) is the simplest fit — see
`systemd/example-bluetooth-modules.service` in this repo for a template.
Enable it with `systemctl enable`.

## Step 6: getting a physical adapter to the VM

If DSM itself runs as a Proxmox VM guest (as here), the adapter needs to
be passed through at the VM level, not just present on the Proxmox host:

```bash
# on the Proxmox host, find the adapter:
lsusb   # note vendor:product, e.g. 2357:0604 for a TP-Link UB500

# attach it to the running VM (adjust the VM id and usbN slot):
qm set <vmid> -usb1 host=2357:0604
```

Proxmox's own kernel needs no patching for this — Bluetooth support on
the *host* side is normal, mainline, and already present; it's only the
DSM *guest* kernel that lacks it, which is what steps 1–5 above address.

This is a real, if minor, change to a live VM's hardware configuration —
treat it with the same care as any other production VM edit (know how to
reverse it, confirm before applying it if anyone else depends on that
VM).

## Prior art / cross-references

- [kcsoft/synology-bluetooth](https://github.com/kcsoft/synology-bluetooth)
  — the same general technique (out-of-tree Bluetooth module build for a
  Synology-derived kernel that ships without `CONFIG_BT`), documented for
  a different platform/kernel version. Useful as a sanity check that this
  approach is sound and precedented, not a novel risk.
- [AuxXxilium/arc](https://github.com/AuxXxilium/arc) — the Arc Loader
  project itself, and the source of the `syno-compiler` build image and
  kernel source used here.

## What's in this repo

- `load-modules.sh` — the actual, verified-working load script for this
  platform (epyc7002, DSM 7.4.1, AuxXxilium kernel vermagic
  `5.10.55+ SMP mod_unload`). Load order and module list are exactly as
  used; adjust vermagic/paths for your own kernel.
- `systemd/example-bluetooth-modules.service` — a template boot-time unit
  based on the one actually used, generalized (paths/names are
  placeholders — this file is illustrative, not lifted verbatim from a
  live system).

**Not included**: the exact original build script/Dockerfile used inside
`syno-compiler` for this specific run — it wasn't preserved after the
build session that produced the `.ko` files ended. Steps 2–3 above
describe the real, verified toolchain/module list/dependency order that
worked; reconstructing an exact one-shot build script from them (rather
than running the compiler interactively) is a reasonable follow-up if
that's useful to you — a PR with one is welcome.
