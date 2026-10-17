#!/usr/bin/env bash
# mint-repair.sh
# Nukes KDE Plasma (incl. Plasma 6 / backports PPAs), fixes dependency
# problems, and reinstalls Cinnamon on Linux Mint.
# Run as root from recovery mode (network required).
#
# Usage:  ./mint-repair.sh          (interactive)
#         ./mint-repair.sh --yes    (no prompts)

set -uo pipefail

LOG="/root/mint-repair-$(date +%F-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

ASSUME_YES=0
[[ "${1:-}" == "--yes" ]] && ASSUME_YES=1

info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }

confirm() {
  (( ASSUME_YES )) && return 0
  read -r -p "$1 [y/N] " ans
  [[ "${ans:-N}" =~ ^[Yy]$ ]]
}

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

fix_deps() {
  info "Repairing package state..."
  dpkg --configure -a --force-confdef --force-confold || true
  apt-get "${APT_OPTS[@]}" -f install || true
  dpkg --configure -a || true
}

info "Linux Mint recovery started: $(date)"
info "Log file: $LOG"

# ---------------------------------------------------------------- 1. prep
info "Remounting / read-write..."
mount -o remount,rw / || warn "Could not remount / rw"
mount -a 2>/dev/null || true   # mount /boot, /boot/efi, etc.

info "Checking network..."
if ! ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
  warn "No network detected; apt will likely fail."
fi

# Clear stale locks from the interrupted install
if ! pgrep -x apt >/dev/null && ! pgrep -x apt-get >/dev/null && ! pgrep -x dpkg >/dev/null; then
  info "Removing stale apt/dpkg locks..."
  rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend \
        /var/lib/apt/lists/lock /var/cache/apt/archives/lock
fi

confirm "This will PURGE all KDE/Plasma packages and reinstall Cinnamon. Continue?" || exit 0

# ------------------------------------------- 2. disable KDE/Plasma 6 repos
info "Looking for KDE/Plasma-related third-party repositories..."
grep -rilE 'kubuntu|kde-neon|neon\.kde|plasma|kubuntu-ppa' \
  /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | while read -r f; do
  warn "Disabling repo file: $f"
  mv "$f" "$f.disabled-by-mint-repair"
done

# Remove apt pins that favor KDE repos
grep -rilE 'kubuntu|neon|plasma' /etc/apt/preferences /etc/apt/preferences.d/ 2>/dev/null | while read -r f; do
  warn "Disabling apt pin: $f"
  mv "$f" "$f.disabled-by-mint-repair"
done

info "Unholding any held packages..."
apt-mark showhold | xargs -r apt-mark unhold || true

apt-get update || warn "apt-get update reported errors"

# -------------------------------------------------- 3. initial dep repair
fix_deps

# ------------------------------------------------------ 4. nuke KDE/Plasma
KDE_REGEX='^(plasma-|kde-|kde[a-z]+|kf5-|kf6-|libkf5|libkf6|libkpipewire|libkscreen|libkworkspace|libplasma|libkirigami|kirigami|kwin|kscreen|ksysguard|kubuntu-|sddm|breeze|oxygen|powerdevil|systemsettings|dolphin|konsole|kate|kwrite|konqueror|discover|plasma|qml6-module-org-kde|qml-module-org-kde|xdg-desktop-portal-kde|baloo|akonadi|kio|kwayland|polkit-kde|khelpcenter|ksshaskpass|kwalletmanager|kwallet|phonon4qt|libphonon4qt|qt6-wayland|sddm-theme)'

list_kde_pkgs() {
  dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null \
    | awk '$1 !~ /^un/ && $1 !~ /^rc?$/ {print $2}' \
    | grep -E "$KDE_REGEX" \
    | grep -vE '^(mint-|cinnamon|lightdm|slick-greeter)' || true
}

mapfile -t KDE_PKGS < <(list_kde_pkgs)
# also catch packages in 'rc' (removed, config remains) state
mapfile -t KDE_RC < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null \
  | awk '$1 ~ /^rc/ {print $2}' | grep -E "$KDE_REGEX" || true)

info "KDE/Plasma packages found: ${#KDE_PKGS[@]} installed, ${#KDE_RC[@]} config-only"
printf '  %s\n' "${KDE_PKGS[@]}" "${KDE_RC[@]}" 2>/dev/null | head -n 300

if (( ${#KDE_PKGS[@]} + ${#KDE_RC[@]} > 0 )); then
  confirm "Purge the packages listed above?" && {
    info "Purging KDE/Plasma via apt..."
    apt-get "${APT_OPTS[@]}" purge "${KDE_PKGS[@]}" "${KDE_RC[@]}" || {
      warn "apt purge failed; forcing removal with dpkg (ignoring dependencies)..."
      for p in "${KDE_PKGS[@]}" "${KDE_RC[@]}"; do
        dpkg --purge --force-all "$p" 2>/dev/null || true
      done
    }
    # Retry in case dependencies blocked some
    mapfile -t LEFT < <(list_kde_pkgs)
    if (( ${#LEFT[@]} > 0 )); then
      warn "Retrying ${#LEFT[@]} leftover packages with dpkg --force-all..."
      for p in "${LEFT[@]}"; do dpkg --purge --force-all "$p" 2>/dev/null || true; done
    fi
  }
fi

# Make sure SDDM can't take over the display manager from LightDM
systemctl disable sddm 2>/dev/null || true
rm -f /etc/systemd/system/display-manager.service

info "Autoremoving orphaned packages..."
apt-get "${APT_OPTS[@]}" autoremove --purge || true
apt-get clean

fix_deps

# ---------------------------------------------- 5. reset conflicting libs
info "Forcing a clean package index and reinstalling core libraries..."
apt-get update || true
apt-get "${APT_OPTS[@]}" --fix-broken --fix-missing install || true
apt-get "${APT_OPTS[@]}" --reinstall install \
  libc6 libgcc-s1 libstdc++6 libqt5core5a 2>/dev/null || true

# If packages came from a newer (backports/PPA) version, downgrade to Mint's
info "Syncing installed packages to Mint repository versions..."
apt-get "${APT_OPTS[@]}" --allow-downgrades dist-upgrade || true

fix_deps

# ------------------------------------------------------ 6. install Cinnamon
info "Installing Cinnamon + Mint desktop..."
apt-get "${APT_OPTS[@]}" install \
  mint-meta-cinnamon \
  cinnamon \
  cinnamon-desktop-environment \
  lightdm \
  slick-greeter \
  lightdm-settings \
  xorg \
  xserver-xorg \
  network-manager \
  network-manager-gnome \
  linux-firmware || {
    warn "Full install failed; trying minimal Cinnamon install..."
    apt-get "${APT_OPTS[@]}" install cinnamon lightdm slick-greeter xorg || true
  }

apt-get "${APT_OPTS[@]}" install --reinstall lightdm || true

info "Setting LightDM as the default display manager..."
echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager
DEBIAN_FRONTEND=noninteractive dpkg-reconfigure lightdm 2>/dev/null || true
systemctl enable lightdm 2>/dev/null || true
systemctl set-default graphical.target 2>/dev/null || true

fix_deps

# ---------------------------------------------------- 7. boot files / GRUB
info "Rebuilding initramfs for all kernels..."
update-initramfs -c -k all 2>/dev/null || update-initramfs -u -k all || true

info "Updating GRUB..."
update-grub || true
if [[ -d /sys/firmware/efi ]]; then
  grub-install --target=x86_64-efi --efi-directory=/boot/efi 2>/dev/null \
    || warn "grub-install (EFI) failed or /boot/efi not mounted"
fi

# --------------------------------------------------------------- 8. verify
info "Verifying package state..."
dpkg --audit || true
apt-get check || true

LEFT_FINAL=$(list_kde_pkgs | wc -l)
info "KDE/Plasma packages remaining: $LEFT_FINAL"
info "Cinnamon installed: $(dpkg -s cinnamon 2>/dev/null | grep -m1 '^Status' || echo 'NO')"

info "Recovery completed: $(date)"
info "Log saved to: $LOG"
info "Reboot with: reboot"
