#!/bin/bash
# SPDX-License-Identifier: MIT
# Bind-mount proc/sys/dev for chroot (debootstrap / apt inside rootfs).

if [ "$(id -u)" -eq 0 ]; then
	_M() { "$@"; }
else
	_M() { sudo "$@"; }
fi

function mnt() {
	echo "MOUNTING"
	_M mkdir -p "${2}/proc" "${2}/sys" "${2}/dev"
	_M mount -t proc /proc "${2}/proc"
	_M mount -t sysfs /sys "${2}/sys"
	_M mount -o bind /dev "${2}/dev"
}

function umnt() {
	echo "UNMOUNTING"
	_M umount "${2}/proc" 2>/dev/null || true
	_M umount "${2}/sys" 2>/dev/null || true
	_M umount "${2}/dev" 2>/dev/null || true
}

if [ "$1" = "-m" ] && [ -n "${2:-}" ]; then
	mnt "$1" "$2"
elif [ "$1" = "-u" ] && [ -n "${2:-}" ]; then
	umnt "$1" "$2"
else
	echo "Usage: $0 -m|-u <rootfs_dir>"
	exit 1
fi
