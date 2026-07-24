#!/bin/bash
# SPDX-License-Identifier: MIT
# Customize an existing Debian rootfs tarball in a chroot: apply overlay/,
# refresh locale + apt, then leave the tree under custom_rootfs_work/ for
# repacking. Add packages via EXTRA_DEBS or the OEM path (see readme.md).
set -euo pipefail

DEBIAN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${DEBIAN_DIR}"

WORK_ROOTFS_DIR="${DEBIAN_DIR}/custom_rootfs_work"
BASE_TAR="${1:-}"

DATE_NAME="$(date "+%Y%m%d")"

mk_error() { echo -e "\033[47;31mERROR: $*\033[0m"; }
mk_warn() { echo -e "\033[47;34mWARN: $*\033[0m"; }
mk_info() { echo -e "\033[47;32mINFO: $*\033[0m"; }

help_info() {
	mk_info "Usage: ./mk-debian-rootfs.sh <path-to-base-rootfs.tar.gz>"
	mk_info "Example: ./mk-debian-rootfs.sh out/debian-trixie-lite-arm64-YYYYMMDD-HHMM.tar.gz"
	mk_info "Work dir: ${WORK_ROOTFS_DIR}"
	mk_info "See: debian/readme.md"
}

if [ -z "${BASE_TAR}" ]; then
	mk_error "missing base rootfs tar"
	help_info
	exit 1
fi

if [ ! -f "${BASE_TAR}" ]; then
	mk_error "not a file: ${BASE_TAR}"
	exit 1
fi

cleanup() {
	set +e
	sudo umount "${WORK_ROOTFS_DIR}/dev" 2>/dev/null || true
}
trap cleanup EXIT

sudo rm -rf "${WORK_ROOTFS_DIR}"
sudo mkdir -p "${WORK_ROOTFS_DIR}"

mk_info "------ Base tarball: ${BASE_TAR} ------"
sudo tar -xpf "${BASE_TAR}" --strip-components=1 -C "${WORK_ROOTFS_DIR}"

mk_info "------ overlay ------"
sudo cp -rf "${DEBIAN_DIR}/overlay/"* "${WORK_ROOTFS_DIR}/"

sudo mount -o bind /dev "${WORK_ROOTFS_DIR}/dev"

# shellcheck disable=SC2016
cat <<'EOF' | sudo chroot "${WORK_ROOTFS_DIR}"
echo -e "\033[47;34mWARN: Review and adjust chroot block in mk-debian-rootfs.sh as needed.\033[0m"
echo "nameserver 127.0.0.53" >> /etc/resolv.conf
echo "options edns0 trust-ad" >> /etc/resolv.conf

sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^LANG=.*$/LANG=en_US.UTF-8/' /etc/default/locale
echo "LC_ALL=en_US.UTF-8" >> /etc/default/locale
echo "LANGUAGE=en_US.UTF-8" >> /etc/default/locale
locale-gen

apt-get update
apt-get upgrade -y

# Install product-specific packages here, e.g.:
#   apt-get install -y --no-install-recommends <pkg>...
# For prebuilt .deb or files, prefer the OEM path (see readme.md).

rm -rf /var/lib/apt/lists/*
rm -rf /var/cache/
EOF

sudo umount "${WORK_ROOTFS_DIR}/dev"
trap - EXIT

mk_info "Done. Work tree: ${WORK_ROOTFS_DIR}"
mk_info "Optional: pack with: sudo tar -C ${WORK_ROOTFS_DIR} -cpzf ${DATE_NAME}-custom-rootfs.tar.gz ."
