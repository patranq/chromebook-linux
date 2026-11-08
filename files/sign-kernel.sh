#!/bin/bash
# Run this IN CHROMEOS on the Chromebook (Ctrl+Alt+T, shell):
#
#     sudo bash /media/removable/CBTOOLS/sign-kernel.sh
#
# It packs and signs the Linux kernel (with the public developer keys and
# the boot stub of this Chromebook's own firmware) and writes it to the
# card's kernel partition. The internal disk is only READ, never written.

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP=/tmp/cbsign
DL=/home/chronos/user/Downloads
KERN_GUID="FE3A2A5D-4F32-41A7-B725-ACCC3285A309"

rm -rf "$TMP"; mkdir -p "$TMP"
exec > >(tee "$TMP/sign-log.txt") 2>&1

save_log() {
  if [ -d "$DL" ]; then
    cp "$TMP"/*.txt "$DL/" 2>/dev/null
    chown chronos:chronos "$DL"/sign-log.txt "$DL"/current-kernel.txt "$DL"/new-kernel.txt 2>/dev/null
    echo "(log saved to Downloads/sign-log.txt)"
  fi
}
die() {
  echo
  echo "ERROR: $*"
  echo "Nothing was written to the internal disk."
  save_log
  exit 1
}
partdev() { case "$1" in *[0-9]) echo "${1}p$2" ;; *) echo "${1}$2" ;; esac; }
num() { printf '%d' "$1" 2>/dev/null; }

echo "=== Chromebook kernel signing ==="
[ "$(id -u)" = 0 ] || die "please run with sudo"
for t in cgpt vbutil_kernel rootdev dd; do
  command -v "$t" >/dev/null || die "tool '$t' not found"
done

# --- 1. Which disk is the card, which is internal -------------------------
for f in bzImage cmdline.txt; do
  [ -f "$HERE/$f" ] || die "$f not found next to this script"
done
SRC="$(df -P "$HERE" | awk 'NR==2{print $1}')"
case "$SRC" in /dev/*) ;; *) die "cannot find the card device (got: $SRC)" ;; esac
DISK="$(echo "$SRC" | sed -E 's/p?[0-9]+$//')"
INTERNAL="$(rootdev -s -d 2>/dev/null)"
[ -n "$INTERNAL" ] || INTERNAL=/dev/sda
echo "Card:          $DISK"
echo "Internal disk: $INTERNAL"
[ "$DISK" != "$INTERNAL" ] || die "the card and the internal disk look the same"

TYPE="$(cgpt show -i 1 -t "$DISK" 2>/dev/null | tr 'a-z' 'A-Z')"
echo "$TYPE" | grep -q -e "$KERN_GUID" -e "CHROMEOS KERNEL" \
  || die "partition 1 of the card is not a kernel partition - was the image written correctly? (type: $TYPE)"
KPART="$(partdev "$DISK" 1)"
[ -b "$KPART" ] || die "$KPART not found"

# --- 2. Boot stub from the running ChromeOS kernel -------------------------
ROOTPART="$(rootdev -s)"
RNUM="$(echo "$ROOTPART" | grep -o '[0-9]*$')"
CURK="$(partdev "$INTERNAL" $((RNUM - 1)))"
echo "Current ChromeOS kernel: $CURK"
vbutil_kernel --verify "$CURK" --verbose > "$TMP/current-kernel.txt" 2>&1
grep -q -i 'preamble' "$TMP/current-kernel.txt" || die "could not read the current kernel ($CURK)"

if grep -q '%U' "$TMP/current-kernel.txt"; then
  echo "OK: firmware uses %U (partition UUID) substitution"
else
  echo "WARNING: %U not seen in the ChromeOS command line (continuing)"
fi

KB_SIZE="$(awk '/^Key ?block:/{s=1;next} s&&/^[ \t]*Size:/{print $2;exit}' "$TMP/current-kernel.txt")"
PRE_SIZE="$(awk '/^Preamble:/{s=1;next} s&&/^[ \t]*Size:/{print $2;exit}' "$TMP/current-kernel.txt")"
LOAD="$(awk -F: '/Body load address/{gsub(/[ \t]/,"",$2);print $2;exit}' "$TMP/current-kernel.txt")"
BL_ADDR="$(awk -F: '/Bootloader address/{gsub(/[ \t]/,"",$2);print $2;exit}' "$TMP/current-kernel.txt")"
BL_SIZE="$(awk -F: '/Bootloader size/{gsub(/[ \t]/,"",$2);print $2;exit}' "$TMP/current-kernel.txt")"
echo "keyblock=$KB_SIZE preamble=$PRE_SIZE load=$LOAD bootloader=$BL_ADDR size=$BL_SIZE"

STUB="$TMP/bootstub.efi"
if [ -n "$KB_SIZE" ] && [ -n "$PRE_SIZE" ] && [ -n "$LOAD" ] && [ -n "$BL_ADDR" ] && [ -n "$BL_SIZE" ]; then
  KB_N=$(num "$KB_SIZE"); PRE_N=$(num "$PRE_SIZE"); LOAD_N=$(num "$LOAD")
  BLA_N=$(num "$BL_ADDR"); BLS_N=$(num "$BL_SIZE")
  if [ "$BLS_N" -gt 0 ]; then
    OFF=$(( KB_N + PRE_N + BLA_N - LOAD_N ))
    echo "Extracting boot stub: offset $OFF, $BLS_N bytes"
    dd if="$CURK" of="$STUB" bs=4096 iflag=skip_bytes,count_bytes \
       skip="$OFF" count="$BLS_N" 2>/dev/null \
      || dd if="$CURK" of="$STUB" bs=1 skip="$OFF" count="$BLS_N" 2>/dev/null
    if [ "$(head -c 2 "$STUB")" = "MZ" ]; then
      echo "OK: boot stub looks like an EFI program"
    else
      echo "WARNING: extracted boot stub does not start with MZ"
      ALT="$(find / -xdev \( -name 'bootstub.efi' -o -name 'bootstub*.efi' \) 2>/dev/null | head -n1)"
      if [ -n "$ALT" ]; then
        echo "Using $ALT instead"; cp "$ALT" "$STUB"
      else
        echo "Continuing with the extracted boot stub"
      fi
    fi
  else
    echo "Current kernel has no boot stub - using an empty one"
    dd if=/dev/zero of="$STUB" bs=512 count=1 2>/dev/null
  fi
else
  ALT="$(find / -xdev \( -name 'bootstub.efi' -o -name 'bootstub*.efi' \) 2>/dev/null | head -n1)"
  [ -n "$ALT" ] || die "could not find the boot stub (see Downloads/current-kernel.txt)"
  echo "Using boot stub file $ALT"; cp "$ALT" "$STUB"
fi
[ -s "$STUB" ] || die "boot stub is empty"

# --- 3. Keys ------------------------------------------------------------
KB=/usr/share/vboot/devkeys/kernel.keyblock
PK=/usr/share/vboot/devkeys/kernel_data_key.vbprivk
if [ ! -f "$KB" ] || [ ! -f "$PK" ]; then
  KB="$HERE/devkeys/kernel.keyblock"; PK="$HERE/devkeys/kernel_data_key.vbprivk"
fi
[ -f "$KB" ] && [ -f "$PK" ] || die "developer keys not found"
echo "Keys: $KB"

# --- 4. Pack and sign -----------------------------------------------------
tr -d '\r\n' < "$HERE/cmdline.txt" > "$TMP/cmdline"
echo "Command line: $(cat "$TMP/cmdline")"
cp "$HERE/bzImage" "$TMP/bzImage"
vbutil_kernel --pack "$TMP/linux.kern" \
  --keyblock "$KB" --signprivate "$PK" --version 1 \
  --config "$TMP/cmdline" --vmlinuz "$TMP/bzImage" \
  --bootloader "$STUB" --arch x86 \
  || die "packing the kernel failed"
vbutil_kernel --verify "$TMP/linux.kern" --verbose > "$TMP/new-kernel.txt" 2>&1 \
  || die "the packed kernel did not verify"

SIZE=$(stat -c %s "$TMP/linux.kern")
PSIZE=$(( $(cgpt show -i 1 -s "$DISK") * 512 ))
echo "Signed kernel: $SIZE bytes (partition: $PSIZE bytes)"
[ "$SIZE" -le "$PSIZE" ] || die "signed kernel does not fit in the card's kernel partition"

# --- 5. Write to the CARD (not the internal disk) ------------------------
echo "Writing to $KPART ..."
dd if="$TMP/linux.kern" of="$KPART" bs=1M conv=fsync 2>/dev/null || die "writing to the card failed"
cgpt add -i 1 -P 15 -T 1 -S 1 "$DISK" || die "could not set the card's boot flags"
crossystem dev_boot_usb=1 2>/dev/null
sync

echo
cgpt show "$DISK"
echo
echo "=================================================================="
echo " DONE. The card is ready."
echo " 1. Restart the Chromebook (keep the card inserted)."
echo " 2. On the white 'OS verification is OFF' screen press Ctrl+U."
echo " 3. Login: anna   password: anna"
echo "=================================================================="
save_log
