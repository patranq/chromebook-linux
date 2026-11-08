# Debian for Samsung Series 5 Chromebook (XE500C21, "Alex")

GitHub Actions builds a ready-to-flash image: 64-bit LTS kernel + Debian 13 + Xfce.

1. Every push (or **Actions → Build Chromebook Linux image → Run workflow**) builds the image (~1 hour).
2. Download the artifact **chromebook-debian-image** and write it to an SD card / USB stick (balenaEtcher or Rufus).
3. In ChromeOS: `sudo bash /media/removable/CBTOOLS/sign-kernel.sh`
4. Reboot, press **Ctrl+U** → Debian from the card (login `anna` / `anna`).
5. When everything works: `sudo install-to-internal` (removes ChromeOS), then boot with **Ctrl+D**.
