#!/bin/zsh
# Boot build/conquer.po (Conquer GS) on an emulated Apple IIgs, using the MAME inside Ample.
cd "$(dirname "$0")" || exit 1
MAME=/Applications/Emulatoren/Ample.app/Contents/MacOS/mame64
AMPLE="$HOME/Library/Application Support/Ample"

# scripted runs (the tests) ignore the Mac's mouse, which would move the
# game's cursor under the script
mouse=-mouse
for a in "$@"; do [ "$a" = "-autoboot_script" ] && mouse=-nomouse; done

exec "$MAME" apple2gs \
  -rompath "$AMPLE/roms" -hashpath "$AMPLE/hash" \
  -cfg_directory build/mame/cfg -nvram_directory build/mame/nvram \
  -snapshot_directory build/mame/snap \
  -window -nomax -skip_gameinfo $mouse \
  -flop3 build/conquer.po "$@"
