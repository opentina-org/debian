#!/bin/bash
# SPDX-License-Identifier: MIT
# One-shot Debian lite (no desktop) rootfs: debootstrap -> tar.gz, optional ext4.
# Runs on host (sudo) or in Docker as root (see docker/build-rootfs.sh).
#
# Usage:
#   ./mk-lite-rootfs.sh [trixie|bookworm]
# Env:
#   ARCH=arm64|armhf          (default arm64)
#   DEBIAN_MIRROR             (default http://mirrors.ustc.edu.cn/debian)
#   DEBIAN_SECURITY_MIRROR
#   ROOT_PASSWORD             (default root)
#   MAKE_EXT4=1               also write .ext4 next to .tar.gz
#   ROOTFS_EXT4_MB=<int>    ext4 size in MB (default: du(rootfs)+400)
#   SKIP_OVERLAY=1            do not rsync debian/overlay onto rootfs
#   EXTRA_DEBS="pkg1 pkg2"    extra apt packages inside chroot
#   HOST_UID / HOST_GID       when running as root in Docker, chown out/ to host user
set -euo pipefail

runroot() {
	if [ "$(id -u)" -eq 0 ]; then
		"$@"
	else
		sudo "$@"
	fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

RELEASE="${1:-trixie}"
ARCH="${ARCH:-arm64}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://mirrors.ustc.edu.cn/debian}"
DEBIAN_SECURITY_MIRROR="${DEBIAN_SECURITY_MIRROR:-http://mirrors.ustc.edu.cn/debian-security}"
ROOT_PASSWORD="${ROOT_PASSWORD:-root}"
SKIP_OVERLAY="${SKIP_OVERLAY:-0}"
EXTRA_DEBS="${EXTRA_DEBS:-}"

case "${RELEASE}" in
trixie | bookworm) ;;
*)
	echo "Unsupported release: ${RELEASE} (use trixie or bookworm)"
	exit 1
	;;
esac

case "${ARCH}" in
arm64)
	QEMU_BIN="/usr/bin/qemu-aarch64-static"
	;;
armhf)
	QEMU_BIN="/usr/bin/qemu-arm-static"
	;;
*)
	echo "Unsupported ARCH=${ARCH} (use arm64 or armhf)"
	exit 1
	;;
esac

HOST_ARCH="$(dpkg --print-architecture 2>/dev/null || echo unknown)"
NEED_QEMU=0
if [ "${ARCH}" != "${HOST_ARCH}" ]; then
	NEED_QEMU=1
fi

if [ "${NEED_QEMU}" = 1 ] && [ ! -f "${QEMU_BIN}" ]; then
	echo "Cross debootstrap needs ${QEMU_BIN} (install qemu-user-static, or use debian/docker/build-rootfs.sh)."
	exit 1
fi

if ! command -v debootstrap >/dev/null 2>&1; then
	echo "debootstrap not found. Install debootstrap or use debian/docker/build-rootfs.sh."
	exit 1
fi

TS="$(date +%Y%m%d-%H%M)"
WORK="${SCRIPT_DIR}/.build-work/${RELEASE}-lite-${ARCH}-${TS}"
ROOT="${WORK}/rootfs"
OUT="${SCRIPT_DIR}/out"
OUT_BASE="debian-${RELEASE}-lite-${ARCH}-${TS}"
TAR_GZ="${OUT}/${OUT_BASE}.tar.gz"
EXT4_IMG="${OUT}/${OUT_BASE}.ext4"

mkdir -p "${OUT}"

cleanup() {
	set +e
	if [ -n "${ROOT:-}" ] && mountpoint -q "${ROOT}/proc" 2>/dev/null; then
		"${SCRIPT_DIR}/ch-mount.sh" -u "${ROOT}"
	fi
}
trap cleanup EXIT

runroot rm -rf "${WORK}"
runroot mkdir -p "${WORK}"

# Cross debootstrap runs arm64 binaries via binfmt; each new Docker run has empty binfmt_misc.
if [ "${NEED_QEMU}" = 1 ]; then
	echo "==> activate qemu-user binfmt (before any cross chroot)"
	runroot mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
	if command -v dpkg-reconfigure >/dev/null 2>&1; then
		runroot dpkg-reconfigure -f noninteractive qemu-user-static || true
	fi
	if command -v update-binfmts >/dev/null 2>&1; then
		runroot update-binfmts --enable 2>/dev/null || true
	fi
fi

echo "==> debootstrap --foreign ${RELEASE} (${ARCH}) -> ${ROOT}"
runroot debootstrap --foreign --arch="${ARCH}" --variant=minbase \
	"${RELEASE}" "${ROOT}" "${DEBIAN_MIRROR}"

if [ "${NEED_QEMU}" = 1 ]; then
	echo "==> copy ${QEMU_BIN} into rootfs (second-stage + chroot apt)"
	runroot cp -a "${QEMU_BIN}" "${ROOT}/usr/bin/"
fi

echo "==> debootstrap second-stage"
"${SCRIPT_DIR}/ch-mount.sh" -m "${ROOT}"
runroot env DEBIAN_FRONTEND=noninteractive chroot "${ROOT}" /debootstrap/debootstrap --second-stage

write_sources_list() {
	local r="$1"
	local m="$2"
	local sec="$3"
	local f="${ROOT}/etc/apt/sources.list"
	if [ "${r}" = "bookworm" ]; then
		runroot tee "${f}" >/dev/null <<EOF
deb ${m}/ bookworm main contrib non-free non-free-firmware
deb ${m}/ bookworm-updates main contrib non-free non-free-firmware
deb ${sec}/ bookworm-security main contrib non-free non-free-firmware
EOF
	else
		runroot tee "${f}" >/dev/null <<EOF
deb ${m}/ trixie main contrib non-free non-free-firmware
deb ${m}/ trixie-updates main contrib non-free non-free-firmware
deb ${sec}/ trixie-security main contrib non-free non-free-firmware
EOF
	fi
}

echo "==> apt sources (${RELEASE})"
write_sources_list "${RELEASE}" "${DEBIAN_MIRROR}" "${DEBIAN_SECURITY_MIRROR}"
if [ -f /etc/resolv.conf ]; then
	runroot cp /etc/resolv.conf "${ROOT}/etc/resolv.conf"
fi

echo "==> apt upgrade + lite packages"
runroot env DEBIAN_FRONTEND=noninteractive chroot "${ROOT}" bash -se <<INNER
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get -y update
apt-get -y full-upgrade
apt-get -y install --no-install-recommends \
	openssh-server sudo locales ca-certificates curl wget \
	iproute2 iputils-ping ifupdown isc-dhcp-client \
	vim-tiny less file pciutils usbutils kmod dbus \
	systemd-sysv systemd-timesyncd udev ${EXTRA_DEBS}

# debootstrap minbase ships /lib/systemd/systemd but often no /sbin/init; the kernel
# then falls back to /bin/sh (serial shows "with environment" + job control warning).
if [ ! -e /sbin/init ] && [ ! -e /usr/sbin/init ]; then
	ln -sf /lib/systemd/systemd /usr/sbin/init
fi

tee /etc/fstab >/dev/null <<'FSTAB'
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
proc            /proc           proc    defaults          0       0
sysfs           /sys            sysfs   defaults          0       0
tmpfs           /tmp            tmpfs   defaults,nodev,nosuid  0  0
FSTAB

sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

echo root:${ROOT_PASSWORD} | chpasswd

echo debian-lite > /etc/hostname
grep -q '^127\.0\.1\.1[[:space:]]\+debian-lite' /etc/hosts 2>/dev/null || echo "127.0.1.1	debian-lite" >> /etc/hosts

# OpenTina: kernel+U-Boot load from separate FAT boot partition; do not auto-mount ESP at /boot.
mkdir -p /etc/systemd/system.conf.d
printf '%s\n' '[Manager]' 'DefaultTimeoutStartSec=120s' > /etc/systemd/system.conf.d/opentina.conf

systemctl set-default multi-user.target 2>/dev/null || true
systemctl mask rsyslog.service 2>/dev/null || true

mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /lib/systemd/system/ssh.service /etc/systemd/system/multi-user.target.wants/ssh.service 2>/dev/null || true
systemctl enable ssh 2>/dev/null || true

apt-get clean
rm -rf /var/lib/apt/lists/*
INNER

if [ "${SKIP_OVERLAY}" != "1" ] && [ -d "${SCRIPT_DIR}/overlay" ]; then
	echo "==> rsync overlay (excluding etc/apt/sources.list)"
	runroot rsync -a \
		--exclude 'etc/apt/sources.list' \
		"${SCRIPT_DIR}/overlay/" "${ROOT}/"
fi

SERIAL_TTY="${OPENTINA_SERIAL_TTY:-ttyS0}"
echo "==> enable opentina-serial-getty@${SERIAL_TTY} (after overlay)"
runroot systemctl --root="${ROOT}" disable "serial-getty@${SERIAL_TTY}.service" 2>/dev/null || true
runroot systemctl --root="${ROOT}" enable "opentina-serial-getty@${SERIAL_TTY}.service" 2>/dev/null || true

"${SCRIPT_DIR}/ch-mount.sh" -u "${ROOT}"

echo "==> pack ${TAR_GZ} (top-level directory rootfs/ for --strip-components=1)"
runroot tar --numeric-owner -cpf - -C "${WORK}" rootfs | gzip -9 >"${TAR_GZ}.tmp"
mv -f "${TAR_GZ}.tmp" "${TAR_GZ}"

_owner_uid="${HOST_UID:-$(id -u)}"
_owner_gid="${HOST_GID:-$(id -g)}"
if [ "$(id -u)" -eq 0 ] && [ -n "${HOST_UID:-}" ]; then
	chown "${_owner_uid}:${_owner_gid}" "${TAR_GZ}" || true
elif [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
	sudo chown "${_owner_uid}:${_owner_gid}" "${TAR_GZ}" 2>/dev/null || true
fi

if [ "${MAKE_EXT4:-0}" = 1 ]; then
	MB="${ROOTFS_EXT4_MB:-}"
	if [ -z "${MB}" ]; then
		MB="$(runroot du -sm "${ROOT}" | awk '{print $1+400}')"
	fi
	echo "==> mkfs.ext4 ${EXT4_IMG} (${MB}M)"
	runroot rm -f "${EXT4_IMG}"
	if runroot mkfs.ext4 -d "${ROOT}" -L rootfs -F "${EXT4_IMG}" "${MB}M" 2>/dev/null; then
		:
	else
		echo "==> mkfs.ext4 -d unsupported or failed; fallback loop+rsync"
		rm -f "${EXT4_IMG}.tmp"
		dd if=/dev/zero of="${EXT4_IMG}.tmp" bs=1M "count=${MB}" status=none
		runroot mkfs.ext4 -F "${EXT4_IMG}.tmp"
		MNT="${WORK}/._ext4_mnt"
		mkdir -p "${MNT}"
		runroot mount -o loop "${EXT4_IMG}.tmp" "${MNT}"
		runroot rsync -aHAX "${ROOT}/" "${MNT}/"
		runroot umount "${MNT}"
		rmdir "${MNT}" 2>/dev/null || true
		mv -f "${EXT4_IMG}.tmp" "${EXT4_IMG}"
	fi
	if [ "$(id -u)" -eq 0 ] && [ -n "${HOST_UID:-}" ]; then
		chown "${_owner_uid}:${_owner_gid}" "${EXT4_IMG}" || true
	elif [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
		sudo chown "${_owner_uid}:${_owner_gid}" "${EXT4_IMG}" 2>/dev/null || true
	fi
	echo "Wrote ${EXT4_IMG}"
fi

if [ "$(id -u)" -eq 0 ] && [ -n "${HOST_UID:-}" ]; then
	chown -R "${_owner_uid}:${_owner_gid}" "${OUT}" "${SCRIPT_DIR}/.build-work" 2>/dev/null || true
fi

echo "Done: ${TAR_GZ}"
ls -lh "${TAR_GZ}" "${EXT4_IMG}" 2>/dev/null || ls -lh "${TAR_GZ}"
