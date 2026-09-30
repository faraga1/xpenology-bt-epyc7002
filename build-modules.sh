#!/bin/sh
# Builds the Bluetooth kernel modules DSM doesn't ship, for Xpenology/Arc on
# the epyc7002 platform (kernel 5.10.55+):
#   ecc ecdh_generic bluetooth rfcomm bnep hidp btusb btintel btbcm btrtl
#
# Uses AuxXxilium's syno-compiler image (Synology's epyc7002 kernel build
# tree + cross toolchain) and the upstream Linux 5.10.55 sources for the
# Bluetooth subsystem. Needs Docker and ~10 GB of disk for the image; runs
# fine on the DSM box itself. Output: ./out/*.ko (debug info stripped).
#
#   ./build-modules.sh                      # on DSM: DOCKER="sudo docker" ./build-modules.sh
#
# Verified 2026-09-30: produces modules whose srcversion matches the set
# that has been running on a DSM 7.4.1 epyc7002 box (see README.md).
set -eu

KVER=5.10.55
KSHA256=7581113dad67a095bc5cc32b457e1a9283f91579e248f3b547a7302157fe8889
IMAGE=${IMAGE:-auxxxilium/syno-compiler:7.4}
PLATFORM=${PLATFORM:-epyc7002}
DOCKER=${DOCKER:-docker}
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$HERE/work}
OUT=${OUT:-$HERE/out}

mkdir -p "$WORK" "$OUT"
if [ ! -f "$WORK/linux-$KVER.tar.xz" ]; then
  curl -fSLo "$WORK/linux-$KVER.tar.xz" "https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-$KVER.tar.xz"
fi
(cd "$WORK" && echo "$KSHA256  linux-$KVER.tar.xz" | sha256sum -c -)

# Runs inside the image. The kernel was built without Bluetooth, so its
# generated config has none of the options below. Rather than regenerating
# the kernel's config (and with it headers shared with the running kernel),
# the options are passed to this build only: as make variables for the
# Makefiles, and as -D defines for the IS_ENABLED()/#ifdef checks in the C
# code. Same mechanism as the image's own compile-module command.
cat > "$WORK/build.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
K=/opt/$PLATFORM/build
export ARCH=x86_64 CROSS_COMPILE=/opt/$PLATFORM/bin/x86_64-pc-linux-gnu-
export PATH=/opt/$PLATFORM/bin:$PATH

SRC=/tmp/src
mkdir -p $SRC
tar -xJf /work/linux-$KVER.tar.xz -C $SRC --strip-components=1 \
  linux-$KVER/net/bluetooth linux-$KVER/drivers/bluetooth \
  linux-$KVER/crypto/ecc.c linux-$KVER/crypto/ecc.h linux-$KVER/crypto/ecc_curve_defs.h \
  linux-$KVER/crypto/ecdh.c linux-$KVER/crypto/ecdh_helper.c

YES="BT_BREDR BT_LE BT_HS BT_DEBUGFS BT_RFCOMM_TTY BT_BNEP_MC_FILTER BT_BNEP_PROTO_FILTER
     BT_HCIBTUSB_BCM BT_HCIBTUSB_RTL BT_HCIBTUSB_MTK"
MOD="BT BT_RFCOMM BT_BNEP BT_HIDP BT_HCIBTUSB BT_INTEL BT_BCM BT_RTL CRYPTO_ECC CRYPTO_ECDH"
VARS=() DEFS=""
for o in $YES; do VARS+=("CONFIG_$o=y"); DEFS+=" -DCONFIG_$o=1"; done
for o in $MOD; do VARS+=("CONFIG_$o=m"); DEFS+=" -DCONFIG_${o}_MODULE=1"; done

build() {  # <dir> [extra Module.symvers...]
  make -C $K M="$1" "${VARS[@]}" KCFLAGS="$DEFS" KBUILD_EXTRA_SYMBOLS="${*:2}" -j"$(nproc)" modules
}

# crypto/Makefile lists every crypto module, so build ecc + ecdh_generic
# from a directory of their own.
mkdir -p /tmp/ecdh
cp $SRC/crypto/ec* /tmp/ecdh/
printf 'obj-m += ecc.o ecdh_generic.o\necdh_generic-y := ecdh.o ecdh_helper.o\n' > /tmp/ecdh/Kbuild
build /tmp/ecdh
build $SRC/net/bluetooth /tmp/ecdh/Module.symvers
build $SRC/drivers/bluetooth $SRC/net/bluetooth/Module.symvers

for f in $(find /tmp/ecdh $SRC -name '*.ko'); do
  strip -g "$f"
  cp "$f" /output/
done
ls -l /output
EOF

$DOCKER run --rm -u 0 \
  -v "$WORK":/work -v "$OUT":/output \
  -e KVER="$KVER" -e PLATFORM="$PLATFORM" \
  --entrypoint bash "$IMAGE" /work/build.sh
