# SPDX-License-Identifier: MIT
# Optional: pre-baked builder for aarch64 CI only. On x86_64 use build-rootfs.sh
# (official ubuntu:24.04 + multiarch/qemu-user-static on host) instead of docker build.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
		debootstrap \
		ca-certificates \
		rsync \
		gzip \
		xz-utils \
		tar \
		coreutils \
		e2fsprogs \
		util-linux \
		procps \
		bash \
		gawk \
		mount \
	&& rm -rf /var/lib/apt/lists/*

WORKDIR /work
