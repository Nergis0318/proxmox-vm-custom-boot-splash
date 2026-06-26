# syntax=docker/dockerfile:1
#
# Build environment for rebuilding Proxmox VE 9 (Debian 13 "trixie") pve-edk2-firmware
# OVMF images with a custom boot logo.
#
# This image only bakes in the build dependencies — the project source is mounted
# (or checked out) at /workspace and built with scripts/build-firmware.sh.
#
# Standalone use (from a repo clone):
#   docker run --rm -v "$PWD:/workspace" \
#     -e SKIP_DEPS=1 -e GIT_URL=https://git.proxmox.com/git/pve-edk2-firmware.git \
#     ghcr.io/<owner>/proxmox-vm-custom-boot-splash/build-env:latest \
#     bash scripts/build-firmware.sh assets/logo.png
#
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Mirrors install_build_deps() in scripts/build-firmware.sh for OVMF_ONLY=1, plus the
# extras a clean container needs that a live Proxmox host already provides:
#   - qemu-utils       -> qemu-img (on PVE this comes from pve-qemu-kvm)
#   - ca-certificates  -> clone pve-edk2-firmware + submodules over https
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      git \
      build-essential \
      bc \
      debhelper \
      dpkg-dev \
      dosfstools \
      acpica-tools \
      nasm \
      uuid-dev \
      mtools \
      xorriso \
      python3 \
      python3-pexpect \
      python3-pil \
      gcc-i686-linux-gnu \
      qemu-utils \
      ccache \
 && update-ccache-symlinks \
 && rm -rf /var/lib/apt/lists/*

# ccache masquerade symlinks live in /usr/lib/ccache (gcc, g++, i686-linux-gnu-gcc,
# ...). Prepend that dir to PATH so EDK2's GCC5 toolchain transparently compiles
# through ccache. update-ccache-symlinks (run above) creates the cross-compiler
# symlink now that gcc-i686-linux-gnu is installed.
ENV PATH="/usr/lib/ccache:${PATH}"

WORKDIR /workspace

CMD ["bash"]
