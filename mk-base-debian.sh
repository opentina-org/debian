#!/bin/bash
# SPDX-License-Identifier: MIT
# Interactive wrapper → ./mk-lite-rootfs.sh (debootstrap). Use ./build.sh for full menu.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -n "${TARGET:-}" ] && [ -n "${RELEASE:-}" ] && [ -n "${ARCH:-}" ]; then
	if [ "${TARGET}" != "lite" ]; then
		echo "Only TARGET=lite is supported for bookworm/trixie."
		exit 1
	fi
	export ARCH
	exec "${SCRIPT_DIR}/mk-lite-rootfs.sh" "${RELEASE}"
fi

if [ -z "${TARGET:-}" ]; then
	echo "---------------------------------------------------------"
	echo "Desktop / image type (桌面或镜像类型):"
	echo "[0] Exit"
	echo "[1] lite (console only, recommended)"
	echo "---------------------------------------------------------"
	read -r input
	case $input in
	0) exit 0 ;;
	1) TARGET=lite ;;
	*)
		echo "Unsupported choice (only lite for trixie/bookworm in-tree)."
		exit 1
		;;
	esac
fi

if [ "${TARGET}" != "lite" ]; then
	echo "Only TARGET=lite is supported for Debian 12/13 here. Use ./mk-lite-rootfs.sh"
	exit 1
fi

if [ -z "${RELEASE:-}" ]; then
	echo "---------------------------------------------------------"
	echo "Debian release:"
	echo "[0] Exit"
	echo "[1] Debian 13 (trixie)"
	echo "[2] Debian 12 (bookworm)"
	echo "---------------------------------------------------------"
	read -r input
	case $input in
	0) exit 0 ;;
	1) RELEASE=trixie ;;
	2) RELEASE=bookworm ;;
	*)
		echo "Invalid release"
		exit 1
		;;
	esac
fi

if [ -z "${ARCH:-}" ]; then
	echo "---------------------------------------------------------"
	echo "Architecture:"
	echo "[0] Exit"
	echo "[1] armhf"
	echo "[2] arm64"
	echo "---------------------------------------------------------"
	read -r input
	case $input in
	0) exit 0 ;;
	1) ARCH=armhf ;;
	2) ARCH=arm64 ;;
	*)
		echo "Invalid ARCH"
		exit 1
		;;
	esac
fi

export ARCH
exec "${SCRIPT_DIR}/mk-lite-rootfs.sh" "${RELEASE}"
