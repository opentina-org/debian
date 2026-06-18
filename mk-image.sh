#!/bin/bash -e
# SPDX-License-Identifier: MIT
#
# mk-image.sh: 把 rootfs tar 解压、叠加 overlay/,打成 rootfs.ext4。
# 通用流程,无外部 BSP / SDK 依赖。
#
# 用法:
#   ./mk-image.sh <rootfs.tar.gz>     解压 tar 并打镜像
#   ./mk-image.sh cover               复用现有 out/binary/ 直接打镜像
#
# 环境变量:
#   EXT4_SIZE_MB   ext4 镜像大小(MB),默认 2048
#   EXT4_LABEL     文件系统 label,默认 rootfs

SDK_ROOT_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SDK_OUT_PATH=${SDK_ROOT_PATH}/out
TARGET_ROOTFS_DIR=${SDK_OUT_PATH}/binary
ROOTFSIMAGE=rootfs.ext4
EXT4_SIZE_MB=${EXT4_SIZE_MB:-2048}
EXT4_LABEL=${EXT4_LABEL:-rootfs}

mk_error() { echo -e "\033[47;31mERROR: $*\033[0m"; }
mk_warn()  { echo -e "\033[47;34mWARN: $*\033[0m"; }
mk_info()  { echo -e "\033[47;32mINFO: $*\033[0m"; }

usage() {
	cat <<EOF
USAGE:
  $(basename "$0") <rootfs.tar.gz>   build rootfs.ext4 from a tar archive
  $(basename "$0") cover             reuse existing ${TARGET_ROOTFS_DIR#${SDK_ROOT_PATH}/}/

env vars:
  EXT4_SIZE_MB=<MB>   image size in MB (default 2048)
  EXT4_LABEL=<label>  ext4 label      (default rootfs)
EOF
	exit 1
}

apply_overlay() {
	local src=$1
	[ -d "$src" ] || return 0
	mk_info "Apply overlay: ${src#${SDK_ROOT_PATH}/}"
	cp -rfp "$src"/. "$TARGET_ROOTFS_DIR"/
}

build_rootfs() {
	local arg=$1
	mkdir -p "$SDK_OUT_PATH"

	if [ "$arg" = "cover" ]; then
		[ -d "$TARGET_ROOTFS_DIR" ] || { mk_error "No $TARGET_ROOTFS_DIR; cannot 'cover'"; exit 1; }
		mk_info "1. Reuse existing rootfs: $TARGET_ROOTFS_DIR"
	else
		[ -f "$arg" ] || { mk_error "Tar not found: $arg"; exit 1; }
		mk_info "1. Extract $arg ..."
		rm -rf "$TARGET_ROOTFS_DIR"
		mkdir -p "$TARGET_ROOTFS_DIR"
		# rootfs tar 顶层通常为 rootfs/ 或 binary/,strip 一层
		fakeroot tar -xpf "$arg" --strip-components=1 -C "$TARGET_ROOTFS_DIR"
	fi

	mk_info "2. Apply overlays ..."
	apply_overlay "$SDK_ROOT_PATH/overlay"

	mk_info "3. Build $ROOTFSIMAGE (${EXT4_SIZE_MB}MB) ..."
	fakeroot chown -h -R 0:0 "$TARGET_ROOTFS_DIR"
	rm -f "$SDK_OUT_PATH/$ROOTFSIMAGE"
	mkfs.ext4 -d "$TARGET_ROOTFS_DIR" -L "$EXT4_LABEL" -m 0 -F \
	          "$SDK_OUT_PATH/$ROOTFSIMAGE" "${EXT4_SIZE_MB}M"

	mk_info "===== done ====="
	mk_info "img: $SDK_OUT_PATH/$ROOTFSIMAGE"
}

[ $# -eq 0 ] && usage
build_rootfs "$1"
