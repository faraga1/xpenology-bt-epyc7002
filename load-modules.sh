#!/bin/sh
# Loads the out-of-tree Bluetooth kernel modules built for this NAS's exact
# kernel (AuxXxilium epyc7002/DSM 7.4, vermagic 5.10.55+ SMP mod_unload).
# Order matters: dependency chain is ecc -> ecdh_generic -> bluetooth ->
# {btintel,btbcm,btrtl} -> btusb, and bluetooth -> {bnep,hidp,rfcomm}.
#
# Adjust MODULE_DIR for your own setup -- this is the directory the built
# .ko files were staged into (see README.md for the build process).
set -u
MODULE_DIR="/volume2/docker/bt-modules"
cd "$MODULE_DIR" || exit 1
LOG=/tmp/bluetooth-module-load.log
: > "$LOG"
for m in ecc ecdh_generic bluetooth btintel btbcm btrtl btusb bnep hidp rfcomm; do
  if /sbin/insmod "$m.ko" >>"$LOG" 2>&1; then
    echo "loaded $m" >>"$LOG"
  else
    echo "FAILED to load $m (may already be loaded)" >>"$LOG"
  fi
done
exit 0
