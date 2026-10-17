#!/usr/bin/env bash
set -euo pipefail

LOG="/root/mint-repair-$(date +%F-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

warn() {
  echo "[WARN] $*"
}

info() {
  echo "[INFO] $*"
}

confirm() {
  local prompt="$1"
  read -r -p "$prompt [y/N] " ans
  [[ "${ans:-N}" =~ ^[Yy]$ ]]
}

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root."
  exit 1
fi

info "Linux Mint recovery started: $(date)"
info "Log file: $LOG"

info "Current root mount state:"
mount | grep " on / " || true

info "Remounting root read-write if needed..."
mount -o remount,rw / || true

if ! confirm "Continue with package repair and boot recovery?"; then
  info "Aborted by user."
  exit 0
fi

info "Checking network connectivity..."
if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
  warn "Network does not appear reachable. apt operations may fail."
else
  info "Network is up."
fi

export DEBIAN_FRONTEND=noninteractive

info "Repairing interrupted package state..."
dpkg --configure -a || true
apt-get -f install -y || true
apt-get update || true

info "Installed Plasma/KDE-related packages:"
dpkg -l | egrep 'plasma|kde|sddm|kwin|kscreen|kubuntu|neon' || true

if confirm "Purge common Plasma 6 / KDE desktop packages?"; then
  info "Purging Plasma/KDE desktop packages..."
  apt-get purge -y \
    plasma-desktop plasma-workspace plasma-workspace-wayland \
    kde-plasma-desktop sddm \
    kwin-x11 kwin-wayland \
    discover plasma-discover \
    kde-standard kde-full \
    || true
  apt-get autoremove -y || true
else
  warn "Skipping package purge."
fi

if confirm "Reinstall Mint desktop components and boot tooling?"; then
  info "Reinstalling Mint desktop components..."
  apt-get install -y \
    cinnamon \
    lightdm \
    mint-meta-cinnamon \
    xorg \
    linux-firmware \
    initramfs-tools \
    grub-pc grub-efi-amd64 \
    || true
else
  warn "Skipping desktop reinstall."
fi

if confirm "Rebuild initramfs and update GRUB?"; then
  info "Rebuilding initramfs..."
  update-initramfs -u -k all || true

  info "Updating GRUB..."
  update-grub || true
else
  warn "Skipping bootloader refresh."
fi

if confirm "Reinstall core runtime libraries?"; then
  info "Reinstalling libc and compiler runtime libraries..."
  apt-get install -y --reinstall \
    libc6 libgcc-s1 libstdc++6 \
    || true
else
  warn "Skipping runtime library reinstall."
fi

info "Final package consistency pass..."
dpkg --configure -a || true
apt-get -f install -y || true

info "Linux Mint recovery completed: $(date)"
