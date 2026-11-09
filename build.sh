#!/bin/bash
# Builds a 32-bit Debian 12 (bookworm, i386) + Xfce disk image for the
# Samsung Series 5 Chromebook XE500C21 ("Alex", Intel Atom N570).
#
#  * 32-bit mainline LTS kernel (same kind as ChromeOS's own kernel on this
#    machine), no initramfs (disk/USB drivers built in)
#  * Disk layout of the image:
#      p1  KERN-A   32 MiB  ChromeOS kernel partition (filled later on the
#                           Chromebook by sign-kernel.sh)
#      p3  CBTOOLS  64 MiB  FAT32: bzImage, cmdline, sign-kernel.sh, keys
#      p2  ROOT-A           ext4 root file system
#    Kernel command line uses root=PARTUUID=%U/PARTNROFF=1, so the root is
#    always "the partition after the kernel partition" (p1 -> p2 on the
#    card, p2 -> p3 on the internal disk after install-to-internal).
#
# Run as root on Ubuntu 24.04 (GitHub Actions). See .github/workflows/build.yml

set -euo pipefail

KERNEL_SERIES="${KERNEL_SERIES:-6.12}"
SUITE="${SUITE:-bookworm}"
DEB_ARCH="${DEB_ARCH:-i386}"
export ARCH=i386          # kernel architecture (32-bit x86)
MIRROR="${MIRROR:-https://deb.debian.org/debian}"
USERNAME="${USERNAME:-anna}"
PASSWORD="${PASSWORD:-anna}"
HOSTNAME_="${HOSTNAME_:-chromebook}"
TZ_="${TZ_:-Asia/Yerevan}"

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HERE/work}"
OUT="${OUT:-$HERE/out}"
ROOT="$WORK/rootfs"
INFO="$OUT/build-info.txt"

mkdir -p "$WORK" "$OUT"
: > "$INFO"

log()  { echo; echo "########## $* ##########"; }
info() { echo "$*" | tee -a "$INFO"; }
die()  { echo "FATAL: $*" | tee -a "$INFO"; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"
# 32-bit kernel build on a 64-bit machine needs the multilib compiler bits
apt-get install -y gcc-multilib >/dev/null 2>&1 || info "note: gcc-multilib could not be installed"
NPROC="$(nproc)"

###########################################################################
log "1. Kernel source"
###########################################################################
RELJSON="$(curl -fsSL https://www.kernel.org/releases.json)"
KVER="$(echo "$RELJSON" | jq -r --arg s "$KERNEL_SERIES." \
        'first(.releases[] | select(.version|startswith($s)) | .version) // empty')"
if [ -z "$KVER" ] || [ "$KVER" = "null" ]; then
  KVER="$(echo "$RELJSON" | jq -r 'first(.releases[] | select(.moniker=="longterm") | .version) // empty')"
  info "WARNING: $KERNEL_SERIES not listed any more, using longterm $KVER"
fi
[ -n "$KVER" ] && [ "$KVER" != "null" ] || die "could not determine kernel version"
KMAJ="${KVER%%.*}"
info "Kernel version: $KVER"

cd "$WORK"
if [ ! -d "linux-$KVER" ]; then
  curl -fL --retry 3 -o "linux-$KVER.tar.xz" \
    "https://cdn.kernel.org/pub/linux/kernel/v${KMAJ}.x/linux-$KVER.tar.xz"
  tar -xf "linux-$KVER.tar.xz"
  rm -f "linux-$KVER.tar.xz"
fi
cd "linux-$KVER"

###########################################################################
log "2. Kernel configuration"
###########################################################################
make i386_defconfig
S=scripts/config

# Small, simple, predictable boot
$S --set-str LOCALVERSION "-alex" --disable LOCALVERSION_AUTO
$S --disable RANDOMIZE_BASE
# 32-bit specifics: Atom N570, 2 GB RAM
$S --disable NOHIGHMEM --enable HIGHMEM4G --disable HIGHMEM64G
$S --disable M486 --disable M586 --disable M686 --enable MATOM
$S --enable KERNEL_XZ --disable KERNEL_GZIP
$S --enable CC_OPTIMIZE_FOR_SIZE --disable CC_OPTIMIZE_FOR_PERFORMANCE
$S --enable IKCONFIG --enable IKCONFIG_PROC
$S --disable DEBUG_INFO --disable DEBUG_INFO_DWARF5 --disable DEBUG_INFO_DWARF4 \
   --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT --enable DEBUG_INFO_NONE

# Must be BUILT IN (there is no initramfs): disks, USB/SD reader, ext4,
# console, keyboard, graphics
for o in ATA SATA_AHCI SCSI BLK_DEV_SD \
         USB USB_PCI USB_EHCI_HCD USB_EHCI_PCI USB_UHCI_HCD \
         USB_STORAGE USB_STORAGE_REALTEK USB_UAS \
         EXT4_FS EXT4_FS_POSIX_ACL EXT4_FS_SECURITY \
         DEVTMPFS DEVTMPFS_MOUNT TMPFS TMPFS_POSIX_ACL TMPFS_XATTR \
         AUTOFS_FS UNIX FHANDLE \
         VT VT_CONSOLE DRM DRM_I915 FB FRAMEBUFFER_CONSOLE \
         SERIO SERIO_I8042 KEYBOARD_ATKBD INPUT_EVDEV \
         MOUSE_PS2 MOUSE_PS2_CYPRESS MOUSE_PS2_SYNAPTICS MOUSE_PS2_ELANTECH \
         MOUSE_PS2_ALPS MOUSE_PS2_LOGIPS2PP MOUSE_PS2_TRACKPOINT \
         SND_HDA_INTEL SND_HDA_CODEC_REALTEK SND_HDA_GENERIC \
         ACPI_BATTERY ACPI_AC ACPI_BUTTON ACPI_VIDEO \
         NLS_CODEPAGE_437 NLS_ISO8859_1 NLS_UTF8 VFAT_FS \
         CPU_FREQ X86_ACPI_CPUFREQ INTEL_IDLE \
         CHROME_PLATFORMS WLAN WLAN_VENDOR_ATH ATH9K_PCI \
         MEDIA_USB_SUPPORT MEDIA_CAMERA_SUPPORT \
         ZRAM_BACKEND_LZO ZRAM_BACKEND_LZ4 ZRAM_BACKEND_ZSTD \
         SECCOMP SECCOMP_FILTER USER_NS CGROUPS \
         ; do
  $S --enable "$o"
done

# Loaded later as modules
for o in CFG80211 MAC80211 ATH9K \
         I2C_I801 MOUSE_CYAPA CHROMEOS_LAPTOP CHROMEOS_ACPI \
         MEDIA_SUPPORT USB_VIDEO_CLASS \
         ZRAM FUSE_FS EXFAT_FS NTFS3_FS ISO9660_FS UDF_FS \
         INPUT_UINPUT SENSORS_CORETEMP BT BT_HCIBTUSB \
         MMC MMC_REALTEK_USB MISC_RTSX_USB \
         ; do
  $S --module "$o"
done

make olddefconfig

bad=0
for o in X86_32 HIGHMEM4G \
         ATA SATA_AHCI SCSI BLK_DEV_SD USB USB_EHCI_HCD USB_UHCI_HCD \
         USB_STORAGE EXT4_FS DEVTMPFS UNIX DRM_I915 FRAMEBUFFER_CONSOLE \
         SERIO_I8042 KEYBOARD_ATKBD; do
  grep -q "^CONFIG_$o=y" .config || { info "MISSING (must be built in): $o"; bad=1; }
done
for o in ATH9K CFG80211 MAC80211 SND_HDA_INTEL MOUSE_PS2 ZRAM FUSE_FS; do
  grep -qE "^CONFIG_$o=(y|m)" .config || { info "MISSING: $o"; bad=1; }
done
for o in SND_HDA_CODEC_REALTEK MOUSE_CYAPA I2C_I801 CHROMEOS_LAPTOP \
         USB_VIDEO_CLASS USB_STORAGE_REALTEK EXFAT_FS NTFS3_FS; do
  grep -qE "^CONFIG_$o=(y|m)" .config || info "note: $o is not enabled"
done
[ "$bad" = 0 ] || die "kernel configuration is missing required options"
cp .config "$OUT/kernel-config.txt"

###########################################################################
log "3. Kernel build ($NPROC CPUs)"
###########################################################################
make -j"$NPROC" bzImage modules
KREL="$(make -s kernelrelease)"
BZ="arch/x86/boot/bzImage"
BZSIZE="$(stat -c %s "$BZ")"
info "Kernel release: $KREL"
info "bzImage size:   $BZSIZE bytes"
[ "$BZSIZE" -lt $((14*1024*1024)) ] || die "bzImage is too big for a 16 MiB kernel partition"

rm -rf "$WORK/modroot"
make INSTALL_MOD_PATH="$WORK/modroot" INSTALL_MOD_STRIP=1 modules_install
rm -f "$WORK/modroot/lib/modules/$KREL/build" "$WORK/modroot/lib/modules/$KREL/source"
cp "$BZ" "$WORK/bzImage"
cd "$WORK"

# Sanity check: the kernel can be packed in ChromeOS format (dummy stub;
# the real boot stub is taken from the Chromebook by sign-kernel.sh)
KEYDIR=/usr/share/vboot/devkeys
if command -v vbutil_kernel >/dev/null && [ -f "$KEYDIR/kernel.keyblock" ]; then
  printf 'console=tty1' > "$WORK/test-cmdline"
  dd if=/dev/zero of="$WORK/test-stub" bs=512 count=1 status=none
  vbutil_kernel --pack "$WORK/test.kern" --keyblock "$KEYDIR/kernel.keyblock" \
    --signprivate "$KEYDIR/kernel_data_key.vbprivk" --version 1 \
    --config "$WORK/test-cmdline" --vmlinuz "$WORK/bzImage" \
    --bootloader "$WORK/test-stub" --arch x86
  info "Test-packed kernel size: $(stat -c %s "$WORK/test.kern") bytes"
  rm -f "$WORK/test.kern" "$WORK/test-stub" "$WORK/test-cmdline"
else
  info "note: vbutil_kernel / devkeys not on build machine, skipped pack test"
fi

###########################################################################
log "4. Debian $SUITE root file system"
###########################################################################
cleanup_mounts() {
  for m in dev/pts dev proc sys run; do
    mountpoint -q "$ROOT/$m" 2>/dev/null && umount -l "$ROOT/$m" || true
  done
}
trap cleanup_mounts EXIT

unset ARCH   # only the kernel build needs it
rm -rf "$ROOT"
BASE_INC="ca-certificates,locales,systemd-sysv,dbus"
if ! debootstrap --arch="$DEB_ARCH" --components=main,contrib,non-free-firmware \
       --include="$BASE_INC" "$SUITE" "$ROOT" "$MIRROR"; then
  info "WARNING: debootstrap with signature check failed, retrying over HTTPS without it"
  rm -rf "$ROOT"
  debootstrap --arch="$DEB_ARCH" --no-check-gpg --components=main,contrib,non-free-firmware \
    --include="$BASE_INC" "$SUITE" "$ROOT" "$MIRROR"
fi

cat > "$ROOT/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main contrib non-free non-free-firmware
deb $MIRROR $SUITE-updates main contrib non-free non-free-firmware
deb https://security.debian.org/debian-security $SUITE-security main contrib non-free non-free-firmware
EOF

mount --bind /dev "$ROOT/dev"
mount --bind /dev/pts "$ROOT/dev/pts"
mount -t proc proc "$ROOT/proc"
mount -t sysfs sys "$ROOT/sys"
mount -t tmpfs tmpfs "$ROOT/run"
cp /etc/resolv.conf "$ROOT/etc/resolv.conf.build" 2>/dev/null || true
rm -f "$ROOT/etc/resolv.conf"
echo "nameserver 1.1.1.1" > "$ROOT/etc/resolv.conf"
echo "nameserver 8.8.8.8" >> "$ROOT/etc/resolv.conf"
printf '#!/bin/sh\nexit 101\n' > "$ROOT/usr/sbin/policy-rc.d"
chmod 755 "$ROOT/usr/sbin/policy-rc.d"

cat > "$ROOT/tmp/setup.sh" <<'CHROOT'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

# Network hiccups: retry each download, and retry the whole install
cat > /etc/apt/apt.conf.d/80-retries <<'EOF'
Acquire::Retries "10";
Acquire::https::Timeout "60";
EOF
retry() {
  local n=1
  until "$@"; do
    [ "$n" -ge 4 ] && return 1
    echo "### attempt $n failed, retrying in 20 s: $*"
    n=$((n + 1)); sleep 20
  done
}

retry apt-get update

# Locales: English UI + Armenian
sed -i -e 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' -e 's/^# *\(hy_AM.UTF-8 UTF-8\)/\1/' /etc/locale.gen
grep -q '^en_US.UTF-8' /etc/locale.gen || echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
grep -q '^hy_AM.UTF-8' /etc/locale.gen || echo 'hy_AM.UTF-8 UTF-8' >> /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/default/locale

# Keyboard (also used by Xorg): English + Armenian phonetic, Alt+Shift switches
cat > /etc/default/keyboard <<'EOF'
XKBMODEL="pc105"
XKBLAYOUT="us,am"
XKBVARIANT=",phonetic"
XKBOPTIONS="grp:alt_shift_toggle"
BACKSPACE="guess"
EOF

# Only ask apt for packages that exist (a missing one would stop everything)
want() {
  for p in "$@"; do
    if apt-cache show "$p" >/dev/null 2>&1; then echo "$p"
    else echo "MISSING PACKAGE (skipped): $p" >&2; fi
  done
}

retry apt-get -y install --no-install-recommends $(want \
  sudo network-manager wpasupplicant wireless-regdb iw rfkill \
  kmod udev dbus-user-session systemd-timesyncd \
  console-setup keyboard-configuration tzdata \
  zram-tools rsync cgpt vboot-kernel-utils gdisk fdisk parted \
  e2fsprogs dosfstools exfatprogs ntfs-3g \
  nano less bash-completion curl wget unzip \
  alsa-utils pciutils usbutils)

retry apt-get -y install $(want \
  xserver-xorg-core xserver-xorg-input-libinput xserver-xorg-input-synaptics \
  lightdm lightdm-gtk-greeter \
  xfce4 xfce4-terminal xfce4-power-manager xfce4-pulseaudio-plugin \
  xfce4-xkb-plugin xfce4-screenshooter xfce4-taskmanager \
  thunar-archive-plugin mousepad ristretto engrampa \
  network-manager-gnome pipewire-audio pavucontrol \
  firefox-esr \
  libreoffice-writer libreoffice-calc libreoffice-gtk3 \
  fonts-noto-core fonts-dejavu fonts-liberation2 \
  gvfs gvfs-backends udisks2 xdg-user-dirs)

apt-get -y clean
CHROOT
chmod 755 "$ROOT/tmp/setup.sh"
chroot "$ROOT" /tmp/setup.sh 2>&1 | tee "$OUT/packages-log.txt"
grep 'MISSING PACKAGE' "$OUT/packages-log.txt" >> "$INFO" || true
for t in cgpt vbutil_kernel; do
  chroot "$ROOT" sh -c "command -v $t" >/dev/null || info "WARNING: $t is not in the image"
done
rm -f "$ROOT/tmp/setup.sh"

###########################################################################
log "5. System settings"
###########################################################################
echo "$HOSTNAME_" > "$ROOT/etc/hostname"
cat > "$ROOT/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME_
::1         localhost ip6-localhost ip6-loopback
EOF

ln -sf "/usr/share/zoneinfo/$TZ_" "$ROOT/etc/localtime"
echo "$TZ_" > "$ROOT/etc/timezone"

cat > "$ROOT/etc/fstab" <<'EOF'
# The root file system is mounted by the kernel (root=PARTUUID=%U/PARTNROFF=1).
EOF

# Compressed swap in RAM (2 GB machine)
cat > "$ROOT/etc/default/zramswap" <<'EOF'
ALGO=lzo-rle
PERCENT=60
PRIORITY=100
EOF

# Xfce: compositing off (faster on Atom)
mkdir -p "$ROOT/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"
cat > "$ROOT/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
EOF

# User
chroot "$ROOT" useradd -m -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chroot "$ROOT" chpasswd
for g in sudo netdev audio video plugdev users bluetooth lpadmin; do
  chroot "$ROOT" getent group "$g" >/dev/null && chroot "$ROOT" usermod -aG "$g" "$USERNAME" || true
done

# Kernel modules + installer
mkdir -p "$ROOT/usr/lib/modules"
cp -a "$WORK/modroot/lib/modules/$KREL" "$ROOT/usr/lib/modules/"
chroot "$ROOT" depmod -a "$KREL"
mkdir -p "$ROOT/boot"
cp "$WORK/bzImage" "$ROOT/boot/vmlinuz-$KREL"
install -m 755 "$HERE/files/install-to-internal" "$ROOT/usr/local/sbin/install-to-internal"

# Clean up build-only bits
rm -f "$ROOT/usr/sbin/policy-rc.d" "$ROOT/etc/resolv.conf" "$ROOT/etc/resolv.conf.build"
: > "$ROOT/etc/machine-id"
rm -f "$ROOT/var/lib/dbus/machine-id"
rm -rf "$ROOT/var/lib/apt/lists/"* "$ROOT/var/cache/apt/"*.bin
cleanup_mounts
trap - EXIT

###########################################################################
log "6. Disk image"
###########################################################################
USED_MB="$(du -s -x --block-size=1M "$ROOT" | cut -f1)"
ROOT_MB=$(( USED_MB * 125 / 100 + 700 ))
ROOT_MB=$(( (ROOT_MB + 63) / 64 * 64 ))
info "Root files: ${USED_MB} MiB, root partition: ${ROOT_MB} MiB"

rm -f "$WORK/root.img" "$WORK/tools.img"
mkfs.ext4 -F -q -L ROOT-A -i 8192 -d "$ROOT" "$WORK/root.img" "${ROOT_MB}M"

# FAT partition with the files needed on the ChromeOS side
printf '%s' "console=tty1 root=PARTUUID=%U/PARTNROFF=1 rootwait rw noinitrd rootfstype=ext4 loglevel=4 i915.modeset=1" \
  > "$WORK/cmdline.txt"
mkfs.vfat -F 32 -n CBTOOLS -C "$WORK/tools.img" $((64*1024)) >/dev/null
export MTOOLS_SKIP_CHECK=1
mcopy -i "$WORK/tools.img" "$WORK/bzImage" ::/bzImage
mcopy -i "$WORK/tools.img" "$WORK/cmdline.txt" ::/cmdline.txt
mcopy -i "$WORK/tools.img" "$HERE/files/sign-kernel.sh" ::/sign-kernel.sh
mcopy -i "$WORK/tools.img" "$HERE/files/README.txt" ::/README.txt
if [ -f "$KEYDIR/kernel.keyblock" ] && [ -f "$KEYDIR/kernel_data_key.vbprivk" ]; then
  mmd -i "$WORK/tools.img" ::/devkeys
  mcopy -i "$WORK/tools.img" "$KEYDIR/kernel.keyblock" ::/devkeys/kernel.keyblock
  mcopy -i "$WORK/tools.img" "$KEYDIR/kernel_data_key.vbprivk" ::/devkeys/kernel_data_key.vbprivk
fi

IMG="$OUT/chromebook-debian.img"
P1_START=2048;   P1_SIZE=$((32*2048))           # KERN-A  32 MiB
P3_START=$((P1_START + P1_SIZE)); P3_SIZE=$((64*2048))   # CBTOOLS 64 MiB
P2_START=$((P3_START + P3_SIZE)); P2_SIZE=$((ROOT_MB*2048))
TOTAL=$((P2_START + P2_SIZE + 2048))

rm -f "$IMG"
truncate -s $((TOTAL*512)) "$IMG"
sgdisk -o "$IMG" >/dev/null
sgdisk -n 1:$P1_START:$((P1_START+P1_SIZE-1)) -t 1:FE3A2A5D-4F32-41A7-B725-ACCC3285A309 -c 1:KERN-A \
       -n 3:$P3_START:$((P3_START+P3_SIZE-1)) -t 3:EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 -c 3:CBTOOLS \
       -n 2:$P2_START:$((P2_START+P2_SIZE-1)) -t 2:0FC63DAF-8483-4772-8E79-3D69D8477DE4 -c 2:ROOT-A \
       "$IMG" >/dev/null
sgdisk -p "$IMG" | tee -a "$INFO"

dd if="$WORK/tools.img" of="$IMG" bs=1M seek=$((P3_START/2048)) conv=notrunc,sparse status=none
dd if="$WORK/root.img"  of="$IMG" bs=1M seek=$((P2_START/2048)) conv=notrunc,sparse status=none
sync

info "Image: $(basename "$IMG")  $(( $(stat -c %s "$IMG") / 1024 / 1024 )) MiB"
info "Login: $USERNAME / $PASSWORD"
info "Built: $(date -u)"
log "Done"
