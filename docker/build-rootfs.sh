#!/bin/bash
# SPDX-License-Identifier: MIT
# x86_64: one-time host binfmt via multiarch/qemu-user-static, then
#   docker run --platform linux/arm64 ubuntu:24.04 ... (no buildx, no docker build).
# aarch64: docker run native ubuntu, same install + mk-lite-rootfs.sh
#
# Usage:
#   debian/docker/build-rootfs.sh [trixie|bookworm]
# Env: ROOTFS_BASE_IMAGE, QEMU_BINFMT_IMAGE, QEMU_BINFMT_SETUP=0|1, DOCKER_AUTO_PLATFORM,
#      MAKE_EXT4, ARCH, DEBIAN_MIRROR, ...
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEBIAN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ARCH="${ARCH:-arm64}"
RELEASE="${1:-trixie}"
case "${RELEASE}" in
trixie | bookworm) ;;
*)
	echo "usage: $0 [trixie|bookworm]"
	exit 1
	;;
esac

if ! command -v docker >/dev/null 2>&1; then
	echo "docker not found. Install Docker Engine."
	exit 1
fi

ROOTFS_BASE_IMAGE="${ROOTFS_BASE_IMAGE:-ubuntu:24.04}"
QEMU_BINFMT_IMAGE="${QEMU_BINFMT_IMAGE:-multiarch/qemu-user-static}"

HOSTM="$(uname -m)"
DOCKER_PLATFORM="${DOCKER_PLATFORM-}"
if [ "${DOCKER_AUTO_PLATFORM:-1}" = "1" ] && [ -z "${DOCKER_PLATFORM}" ]; then
	if [[ "${HOSTM}" == "x86_64" || "${HOSTM}" == "amd64" ]]; then
		if [ "${ARCH}" = "arm64" ]; then
			DOCKER_PLATFORM="linux/arm64"
		elif [ "${ARCH}" = "armhf" ]; then
			DOCKER_PLATFORM="linux/arm/v7"
		fi
	elif [[ "${HOSTM}" == "aarch64" || "${HOSTM}" == "arm64" ]]; then
		if [ "${ARCH}" = "armhf" ]; then
			DOCKER_PLATFORM="linux/arm/v7"
		fi
	fi
fi

PLATFORM_ARGS=()
NEED_HOST_BINFMT=false
if [ -n "${DOCKER_PLATFORM}" ]; then
	PLATFORM_ARGS=(--platform "${DOCKER_PLATFORM}")
	echo "==> docker --platform ${DOCKER_PLATFORM} (host ${HOSTM}, target ${ARCH})"
	if [[ "${HOSTM}" == "x86_64" || "${HOSTM}" == "amd64" ]]; then
		NEED_HOST_BINFMT=true
	fi
fi

if [ "${NEED_HOST_BINFMT}" = true ] && [ "${QEMU_BINFMT_SETUP:-1}" = "1" ]; then
	echo "==> Register QEMU user interpreters on host: ${QEMU_BINFMT_IMAGE} --reset -p yes"
	echo "    (writes /proc/sys/fs/binfmt_misc; needs --privileged; skip with QEMU_BINFMT_SETUP=0 if already done)"
	docker run --rm --privileged "${QEMU_BINFMT_IMAGE}" --reset -p yes
fi

echo "==> docker pull ${ROOTFS_BASE_IMAGE}"
if [ ${#PLATFORM_ARGS[@]} -gt 0 ]; then
	docker pull "${PLATFORM_ARGS[@]}" "${ROOTFS_BASE_IMAGE}"
else
	docker pull "${ROOTFS_BASE_IMAGE}"
fi

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

echo "==> docker run (privileged) ${ROOTFS_BASE_IMAGE} release=${RELEASE} ARCH=${ARCH}"
docker run --rm --privileged "${PLATFORM_ARGS[@]}" \
	--network host \
	-e MAKE_EXT4="${MAKE_EXT4:-1}" \
	-e ARCH="${ARCH}" \
	-e DEBIAN_MIRROR="${DEBIAN_MIRROR:-}" \
	-e DEBIAN_SECURITY_MIRROR="${DEBIAN_SECURITY_MIRROR:-}" \
	-e ROOT_PASSWORD="${ROOT_PASSWORD:-}" \
	-e SKIP_OVERLAY="${SKIP_OVERLAY:-}" \
	-e EXTRA_DEBS="${EXTRA_DEBS:-}" \
	-e ROOTFS_EXT4_MB="${ROOTFS_EXT4_MB:-}" \
	-e HOST_UID="${HOST_UID}" \
	-e HOST_GID="${HOST_GID}" \
	-v "${DEBIAN_DIR}:/work" \
	-w /work \
	"${ROOTFS_BASE_IMAGE}" \
	bash -lc '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
	debootstrap rsync gzip e2fsprogs util-linux ca-certificates \
	gawk mount xz-utils tar coreutils procps bash
cd /work
exec ./mk-lite-rootfs.sh '"${RELEASE}"'
'

echo "Artifacts under: ${DEBIAN_DIR}/out/"
