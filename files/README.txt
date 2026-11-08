Samsung Series 5 Chromebook (XE500C21) - Debian Linux card
==========================================================

STEP 1 (in ChromeOS): sign the kernel for this Chromebook
   Ctrl+Alt+T, type:  shell
   then type:         sudo bash /media/removable/CBTOOLS/sign-kernel.sh

STEP 2: test Linux from the card
   Restart, keep the card inserted, press Ctrl+U on the white screen.
   Login: anna   Password: anna   (change it with:  passwd)
   Check Wi-Fi, screen, touchpad, sound, keyboard (Alt+Shift = Armenian).

STEP 3 (in Linux, only when everything works): remove ChromeOS
   Open Terminal and type:   sudo install-to-internal
   Then power off, remove the card, power on and press Ctrl+D.

Never press SPACE on the white screen and keep the developer switch ON.
