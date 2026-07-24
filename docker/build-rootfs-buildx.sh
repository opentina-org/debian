#!/bin/bash
# SPDX-License-Identifier: MIT
# buildx-based Debian lite rootfs. Uses BuildKit + QEMU binfmt to cross-build
# an arm64/armhf rootfs without debootstrap, host privilege, or a manually
# managed binfmt registration loop.
#
# Usage:
#   debian/docker/build-rootfs-buildx.sh [trixie|bookworm]
#
# Env:
#   ARCH=arm64|armhf           (default arm64)
#   DEBIAN_MIRROR
#   DEBIAN_SECURITY_MIRROR
#   ROOT_PASSWORD              (default root)
#   EXTRA_DEBS="pkg1 pkg2"     extra apt packages
#   OPENTINA_SERIAL_TTY        (default ttyS0)
#   MAKE_EXT4=1                also produce .ext4
#   ROOTFS_EXT4_MB=<int>       ext4 size in MB (default du(rootfs)+400)
#   HOST_UID / HOST_GID        chown out/ to host user (Docker passes these in)
#   QEMU_BINFMT_SETUP=0        skip registering qemu binfmt on host
#   QEMU_BINFMT_IMAGE          default tonistiigi/binfmt:latest
#   BUILDX_BUILDER             override builder (default: current)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEBIAN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ARCH="${ARCH:-arm64}"
RELEASE="${1:-trixie}"

case "${RELEASE}" in
trixie | bookworm) ;;
*) echo "usage: $0 [trixie|bookworm]"; exit 1 ;;
esac

case "${ARCH}" in
arm64) PLATFORM="linux/arm64"; QEMU_ARCH="aarch64" ;;
armhf) PLATFORM="linux/arm/v7"; QEMU_ARCH="arm" ;;
*) echo "unsupported ARCH=${ARCH} (use arm64 or armhf)"; exit 1 ;;
esac

if ! command -v docker >/dev/null 2>&1; then
    echo "docker not found. Install Docker Engine."
    exit 1
fi
if ! docker buildx version >/dev/null 2>&1; then
    echo "docker buildx required (install docker-buildx-plugin or upgrade Docker)."
    exit 1
fi

# Register qemu binfmt if host can't directly execute the target arch.
HOSTM="$(uname -m)"
NEED_HOST_BINFMT=false
case "${HOSTM}" in
x86_64 | amd64)
    [ "${ARCH}" != "amd64" ] && NEED_HOST_BINFMT=true ;;
aarch64 | arm64)
    [ "${ARCH}" != "arm64" ] && NEED_HOST_BINFMT=true ;;
esac
if [ "${NEED_HOST_BINFMT}" = true ] && [ "${QEMU_BINFMT_SETUP:-1}" = "1" ]; then
    if ! [ -e "/proc/sys/fs/binfmt_misc/qemu-${QEMU_ARCH}" ]; then
        QEMU_BINFMT_IMAGE="${QEMU_BINFMT_IMAGE:-tonistiigi/binfmt:latest}"
        echo "==> register qemu binfmt for ${ARCH} via ${QEMU_BINFMT_IMAGE}"
        docker run --rm --privileged "${QEMU_BINFMT_IMAGE}" --install "${ARCH}"
    fi
fi

TS="$(date +%Y%m%d-%H%M)"
OUT="${DEBIAN_DIR}/out"
mkdir -p "${OUT}"
RAW_TAR="${OUT}/.buildx-${RELEASE}-${ARCH}-${TS}.tar"
OUT_BASE="debian-${RELEASE}-lite-${ARCH}-${TS}"
TAR_GZ="${OUT}/${OUT_BASE}.tar.gz"
EXT4_IMG="${OUT}/${OUT_BASE}.ext4"

# Snapshot OPENTINA_OEM_DIR into the build context so Dockerfile.rootfs can
# COPY it unconditionally. Always present (empty = no-op); cleaned on exit.
OEM_STAGE="${DEBIAN_DIR}/.oem-staging"
rm -rf "${OEM_STAGE}"
mkdir -p "${OEM_STAGE}"
if [ -n "${OPENTINA_OEM_DIR:-}" ]; then
    if [ -d "${OPENTINA_OEM_DIR}" ]; then
        echo "==> OEM staging: ${OPENTINA_OEM_DIR} -> ${OEM_STAGE}"
        cp -a "${OPENTINA_OEM_DIR}/." "${OEM_STAGE}/"
    else
        echo "OPENTINA_OEM_DIR=${OPENTINA_OEM_DIR} is set but not a directory" >&2
        exit 1
    fi
fi
trap 'rm -rf "${OEM_STAGE}"' EXIT

BUILDER_ARG=()
[ -n "${BUILDX_BUILDER:-}" ] && BUILDER_ARG=(--builder "${BUILDX_BUILDER}")

echo "==> buildx build --platform=${PLATFORM} -f docker/Dockerfile.rootfs (SUITE=${RELEASE})"
docker buildx build "${BUILDER_ARG[@]}" \
    --platform "${PLATFORM}" \
    --progress "${BUILDX_PROGRESS:-auto}" \
    -f "${SCRIPT_DIR}/Dockerfile.rootfs" \
    --build-arg "SUITE=${RELEASE}" \
    --build-arg "DEBIAN_MIRROR=${DEBIAN_MIRROR:-http://deb.debian.org/debian}" \
    --build-arg "DEBIAN_SECURITY_MIRROR=${DEBIAN_SECURITY_MIRROR:-http://security.debian.org/debian-security}" \
    --build-arg "ROOT_PASSWORD=${ROOT_PASSWORD:-root}" \
    --build-arg "EXTRA_DEBS=${EXTRA_DEBS:-}" \
    --build-arg "SERIAL_TTY=${OPENTINA_SERIAL_TTY:-ttyS0}" \
    -o "type=tar,dest=${RAW_TAR}" \
    "${DEBIAN_DIR}"

# buildx -o type=tar emits the filesystem at root '/'; downstream mk-image.sh
# uses tar --strip-components=1 on a top-level 'rootfs/' dir, so re-wrap.
WRAP_DIR="$(mktemp -d -t opentina-buildx.XXXXXX)"
trap 'rm -rf "${WRAP_DIR}" "${OEM_STAGE}" "${RAW_TAR}"' EXIT
mkdir -p "${WRAP_DIR}/rootfs"

_owner_uid="${HOST_UID:-$(id -u)}"
_owner_gid="${HOST_GID:-$(id -g)}"

# fakeroot keeps root ownership across extract/repack/mkfs; a non-root build
# otherwise owns every file, breaking setuid binaries (mount -> EPERM).
if command -v fakeroot >/dev/null 2>&1; then
    FAKEROOT="fakeroot --"
else
    echo "WARNING: no fakeroot; rootfs owned by build user, setuid binaries broken" >&2
    FAKEROOT=""
fi

_host_mkfs=0
command -v mkfs.ext4 >/dev/null 2>&1 && _host_mkfs=1

echo "==> unpack + repack${MAKE_EXT4:+ + mkfs} under fakeroot (preserve root ownership)"
${FAKEROOT} bash -e -c '
    raw=$1; wrap=$2; targz=$3; make_ext4=$4; host_mkfs=$5; ext4=$6; mb=$7
    tar --numeric-owner -xpf "$raw" -C "$wrap/rootfs"
    tar --numeric-owner -cpf - -C "$wrap" rootfs | gzip -9 > "$targz.tmp"
    if [ "$make_ext4" = "1" ] && [ "$host_mkfs" = "1" ]; then
        [ -n "$mb" ] || { mb=$(du -sm "$wrap/rootfs" | cut -f1); mb=$((mb + 400)); }
        rm -f "$ext4"
        mkfs.ext4 -d "$wrap/rootfs" -L rootfs -m 0 -F "$ext4" "${mb}M" >/dev/null
    fi
' _ "${RAW_TAR}" "${WRAP_DIR}" "${TAR_GZ}" "${MAKE_EXT4:-0}" "${_host_mkfs}" "${EXT4_IMG}" "${ROOTFS_EXT4_MB:-}" \
    || { echo "fakeroot unpack/repack/mkfs failed"; exit 1; }

mv -f "${TAR_GZ}.tmp" "${TAR_GZ}"
chown "${_owner_uid}:${_owner_gid}" "${TAR_GZ}" 2>/dev/null || true

# no host mkfs.ext4: extract + mkfs as root in a container (root-owned).
if [ "${MAKE_EXT4:-0}" = "1" ] && [ "${_host_mkfs}" = "0" ]; then
    MB="${ROOTFS_EXT4_MB:-}"
    [ -n "${MB}" ] || MB="$(du -sm "${WRAP_DIR}/rootfs" | awk '{print $1+400}')"
    FALLBACK_IMAGE="${OPENTINA_MKE2FS_IMAGE:-opentina-buildenv:24.04}"
    _ext4_base="$(basename "${EXT4_IMG}")"
    _raw_base="$(basename "${RAW_TAR}")"
    _pre=""
    if ! docker image inspect "${FALLBACK_IMAGE}" >/dev/null 2>&1; then
        FALLBACK_IMAGE="ubuntu:24.04"
        _pre="apt-get update -qq && apt-get install -y -qq e2fsprogs >/dev/null &&"
    fi
    echo "==> host has no mkfs.ext4; using ${FALLBACK_IMAGE} (extract + mkfs as root in container)"
    rm -f "${EXT4_IMG}"
    docker run --rm \
        -v "${OUT}:/out" \
        --user 0:0 \
        "${FALLBACK_IMAGE}" \
        bash -c "set -e; ${_pre} mkdir -p /r && tar --numeric-owner -xpf /out/${_raw_base} -C /r && mkfs.ext4 -d /r -L rootfs -m 0 -F /out/${_ext4_base} ${MB}M >/dev/null && chown ${_owner_uid}:${_owner_gid} /out/${_ext4_base}" \
        || { echo "docker mkfs.ext4 failed"; exit 1; }
fi

[ "${MAKE_EXT4:-0}" = "1" ] && chown "${_owner_uid}:${_owner_gid}" "${EXT4_IMG}" 2>/dev/null || true

echo "Done: ${TAR_GZ}"
ls -lh "${TAR_GZ}" "${EXT4_IMG}" 2>/dev/null || ls -lh "${TAR_GZ}"
