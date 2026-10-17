# Linux Mint Recovery Script

This repository contains a recovery script for repairing a broken Linux Mint installation after an interrupted Plasma 6 install.

## Contents

- `mint-repair.sh` — conservative recovery script to repair packages, remove problematic Plasma/KDE components, and rebuild boot files.

## Usage

Run as root from recovery mode or a live USB chroot:

```bash
chmod +x mint-repair.sh
./mint-repair.sh
```

## Notes

The script is intentionally conservative and logs actions to `/root/mint-repair-<timestamp>.log`.
