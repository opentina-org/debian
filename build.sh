#!/bin/bash
# SPDX-License-Identifier: MIT
# Unified Debian helper: interactive menu + rootfs tar selection + ext4 image assembly.
set -euo pipefail

DEBIAN_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEBIAN_CONFIG=${DEBIAN_DIR}/.config

mk_error() { echo -e "\033[47;31mERROR: $*\033[0m"; }

list_rootfs_tars_lines() {
	shopt -s nullglob
	local f
	for f in "${DEBIAN_DIR}/compressed_files"/*.tar.gz "${DEBIAN_DIR}/compressed_files"/*.tar \
	         "${DEBIAN_DIR}/out"/*.tar.gz; do
		[ -f "$f" ] && basename "$f"
	done | sort -u
	shopt -u nullglob
}

resolve_tar_path() {
	local base=$1 d
	for d in "${DEBIAN_DIR}/compressed_files" "${DEBIAN_DIR}/out"; do
		[ -f "$d/$base" ] && { echo "$d/$base"; return 0; }
	done
	return 1
}

do_select() {
	local list=()
	while IFS= read -r line; do
		[ -n "$line" ] && list+=("$line")
	done < <(list_rootfs_tars_lines)
	local cnt=${#list[@]}
	if [ "$cnt" -eq 0 ]; then
		mk_error "No .tar.gz/.tar under compressed_files/ or out/. Build one first."
		exit 1
	fi

	local cfg=""
	[ -f "$DEBIAN_CONFIG" ] && cfg=$(awk -F= '/^DEBIAN_TAR_ROOTFS=/{print $2}' "$DEBIAN_CONFIG" | tr -d '\r')

	local idx=0 i
	printf "Available rootfs archives:\n"
	for i in "${!list[@]}"; do
		[ "${list[$i]}" = "$cfg" ] && idx=$i
		printf "%4d. %s\n" "$i" "${list[$i]}"
	done

	local choice
	while true; do
		read -r -p "Choice [${list[$idx]}]: " choice
		[ -z "$choice" ] && choice=$idx
		if [[ $choice =~ ^[0-9]+$ ]] && [ "$choice" -ge 0 ] && [ "$choice" -lt "$cnt" ]; then
			echo "DEBIAN_TAR_ROOTFS=${list[$choice]}" >"$DEBIAN_CONFIG"
			break
		fi
		echo "Invalid input"
	done
}

build_image() {
	[ -f "$DEBIAN_CONFIG" ] || { mk_error "Run '$0 config' first to select a rootfs tar."; exit 1; }
	local tar path
	tar=$(awk -F= '/^DEBIAN_TAR_ROOTFS=/{print $2}' "$DEBIAN_CONFIG" | tr -d '\r')
	if ! path=$(resolve_tar_path "$tar"); then
		mk_error "Cannot find archive: $tar (looked under compressed_files/ and out/)"
		exit 1
	fi
	(cd "$DEBIAN_DIR" && ./mk-image.sh "$path")
}

clean_staging() {
	rm -rf "$DEBIAN_CONFIG" "${DEBIAN_DIR}/.build-work"
}

clean_out() {
	rm -rf "${DEBIAN_DIR}/out"/*.tar.gz "${DEBIAN_DIR}/out"/*.ext4 "${DEBIAN_DIR}/out/binary" 2>/dev/null || true
}

interactive_menu() {
	local c
	while true; do
		cat <<EOF

== Debian rootfs (${DEBIAN_DIR}) ==
 0) Exit
 1) Build lite rootfs (Docker)   → docker/build-rootfs.sh
 2) Build lite rootfs (local)    → mk-lite-rootfs.sh
 3) Customize from base tar      → mk-debian-rootfs.sh
 4) Select rootfs tar            → writes .config
 5) Build rootfs.ext4            → mk-image.sh
 6) Clean staging (.config, .build-work)
 7) Clean outputs (out/*.tar.gz, out/*.ext4, out/binary)
EOF
		read -r -p "Select [0-7]: " c
		case "$c" in
		0) exit 0 ;;
		1) read -r -p "Release [trixie/bookworm] (default trixie): " r; r=${r:-trixie}
		   exec "${DEBIAN_DIR}/docker/build-rootfs.sh" "$r" ;;
		2) read -r -p "Release [trixie/bookworm] (default trixie): " r; r=${r:-trixie}
		   (cd "$DEBIAN_DIR" && exec ./mk-lite-rootfs.sh "$r") ;;
		3) read -r -p "Base tar path: " p
		   (cd "$DEBIAN_DIR" && exec ./mk-debian-rootfs.sh "$p") ;;
		4) do_select ;;
		5) build_image ;;
		6) clean_staging ;;
		7) clean_out ;;
		*) echo "Invalid choice" ;;
		esac
	done
}

main() {
	cd "$DEBIAN_DIR"
	case "${1:-}" in
		menu|"")        interactive_menu ;;
		config)         do_select ;;
		clean)          clean_staging ;;
		clean-out)      clean_out ;;
		image|pack)     build_image ;;
		docker-lite)    shift || true
		                exec "${DEBIAN_DIR}/docker/build-rootfs.sh" "${@:-trixie}" ;;
		lite)           shift || true
		                exec "${DEBIAN_DIR}/mk-lite-rootfs.sh" "${@:-trixie}" ;;
		custom)         shift || true
		                exec "${DEBIAN_DIR}/mk-debian-rootfs.sh" "$@" ;;
		*)              echo "Usage: $0 [menu|config|clean|clean-out|image|docker-lite [release]|lite [release]|custom <tar>]"
		                exit 1 ;;
	esac
}

main "$@"
