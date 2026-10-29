#!/bin/zsh
# Boot build/conquer.po (Conquer GS) on an emulated Apple IIgs, using the MAME inside Ample.
cd "$(dirname "$0")" || exit 1
MAME=/Applications/Emulatoren/Ample.app/Contents/MacOS/mame64
AMPLE="$HOME/Library/Application Support/Ample"

# scripted runs (the tests) ignore the Mac's mouse, which would move the
# game's cursor under the script
mouse=-mouse
for a in "$@"; do [ "$a" = "-autoboot_script" ] && mouse=-nomouse; done

# MAME's mouse makes far more counts than an Apple mouse for the same
# move (and wraps what doesn't fit), so the arrow races: MAME's mouse
# sensitivity is set to MOUSESPEED percent (40 unless set) in its settings
# for the IIgs, every time
speed=${MOUSESPEED:-40}
cfg=build/mame/cfg/apple2gs.cfg
mkdir -p build/mame/cfg
[ -f "$cfg" ] || printf '%s\n' '<?xml version="1.0"?>' '<mameconfig version="10">' \
  '    <system name="apple2gs">' '        <input>' '        </input>' '    </system>' \
  '</mameconfig>' > "$cfg"
grep -v 'macadb:MOUSE[12]' "$cfg" | awk -v s="$speed" '
  { print }
  /<input>/ && !done {
    printf "            <port tag=\":macadb:MOUSE1\" type=\"P1_MOUSE_X\" mask=\"255\" defvalue=\"0\" sensitivity=\"%s\" />\n", s
    printf "            <port tag=\":macadb:MOUSE2\" type=\"P1_MOUSE_Y\" mask=\"255\" defvalue=\"0\" sensitivity=\"%s\" />\n", s
    done = 1
  }' > "$cfg.new" && mv "$cfg.new" "$cfg"

exec "$MAME" apple2gs \
  -rompath "$AMPLE/roms" -hashpath "$AMPLE/hash" \
  -cfg_directory build/mame/cfg -nvram_directory build/mame/nvram \
  -snapshot_directory build/mame/snap \
  -window -nomax -skip_gameinfo $mouse \
  -flop3 build/conquer.po "$@"
