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

run_cmd() {
  local label="$1"
  shift
  info "$label"
  "$@"
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

if ! confirm "Continue with package repair and desktop recovery?"; then
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

run_cmd "Refreshing package lists..." apt-get update || true
run_cmd "Repairing interrupted package state..." dpkg --configure -a || true
run_cmd "Fixing broken dependencies..." apt-get -f install -y || true

info "Installed Plasma/KDE-related packages:"
dpkg -l | egrep 'plasma|kde|sddm|kwin|kscreen|kubuntu|neon|discover|dolphin|konsole|kate' || true

if confirm "Purge common Plasma/KDE desktop packages and leftovers?"; then
  run_cmd "Purging Plasma/KDE desktop packages..." apt-get purge -y \
    plasma-desktop plasma-workspace plasma-workspace-wayland \
    kde-plasma-desktop kde-standard kde-full \
    kwin-x11 kwin-wayland \
    sddm discover plasma-discover \
    dolphin konsole kate \
    kubuntu-desktop \
    || true

  run_cmd "Autoremoving unused packages..." apt-get autoremove --purge -y || true
else
  warn "Skipping package purge."
fi

if confirm "Reinstall Cinnamon and Mint desktop components?"; then
  run_cmd "Reinstalling Mint desktop packages..." apt-get install -y \
    cinnamon \
    mint-meta-cinnamon \
    lightdm \
    slick-greeter \
    xorg \
    cinnamon-desktop-environment \
    linux-firmware \
    initramfs-tools \
    grub-pc grub-efi-amd64 \
    || true
else
  warn "Skipping desktop reinstall."
fi

if confirm "Rebuild initramfs and update GRUB?"; then
  run_cmd "Rebuilding initramfs..." update-initramfs -u -k all || true
  run_cmd "Updating GRUB..." update-grub || true
else
  warn "Skipping bootloader refresh."
fi

if confirm "Reinstall core runtime libraries?"; then
  run_cmd "Reinstalling core runtime libraries..." apt-get install -y --reinstall \
    libc6 libgcc-s1 libstdc++6 \
    || true
else
  warn "Skipping runtime library reinstall."
fi

run_cmd "Final package consistency pass..." dpkg --configure -a || true
run_cmd "Final broken dependency repair..." apt-get -f install -y || true

info "Linux Mint recovery completed: $(date)"
info "Log saved to: $LOG"
