#!/bin/sh
# Loads the out-of-tree Bluetooth modules (see build-modules.sh) in
# dependency order: ecc -> ecdh_generic -> bluetooth -> {btintel, btbcm,
# btrtl} -> btusb, and bluetooth -> {bnep, hidp, rfcomm}.
#
#   sudo ./load-modules.sh [module-dir]     # default: ./out next to this script
#
# Modules that are already loaded are skipped. Never force-load (insmod -f /
# modprobe --force-vermagic): a vermagic mismatch means the modules were
# built for a different kernel, and forcing them in risks a kernel panic.
set -u
DIR=${1:-$(cd "$(dirname "$0")" && pwd)/out}
for m in ecc ecdh_generic bluetooth btintel btbcm btrtl btusb bnep hidp rfcomm; do
  if grep -q "^$m " /proc/modules; then
    echo "$m already loaded"
  elif [ ! -f "$DIR/$m.ko" ]; then
    echo "$m: $DIR/$m.ko not found" >&2
  elif /sbin/insmod "$DIR/$m.ko"; then
    echo "loaded $m"
  else
    echo "FAILED to load $m -- see dmesg" >&2
  fi
done
[ -e /sys/class/bluetooth/hci0 ] && echo "hci0 is up" || echo "no hci0 (yet) -- is an adapter attached?"
