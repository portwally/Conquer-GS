#!/bin/zsh
# Build the Conquer GS boot disk: build/conquer.po (800K ProDOS)
set -e
cd "$(dirname "$0")" || exit 1

mkdir -p build
python3 tools/makegfx.py build/gfx
python3 tools/makemusic.py build/gfx
python3 tools/makesound.py build/gfx

# assemble (Merlin 32 writes its output next to the source)
(cd src && ../tools/merlin32 -V ../vendor/merlin32/Library main.s > ../build/merlin.log) \
  || { cat build/merlin.log; exit 1; }
rm -f src/error_output.txt
grep -qi error build/merlin.log && { cat build/merlin.log; exit 1; }
mv src/CONQUER.SYSTEM "build/CONQUER.SYSTEM#FF2000"
# the program loads at $2000 and must end below its variables at $9200
size=$(wc -c < "build/CONQUER.SYSTEM#FF2000")
[ "$size" -le 29184 ] || { echo "CONQUER.SYSTEM is $size bytes, over 29184"; exit 1; }
# every equ in the game, for the test scripts (tools/vars.lua)
python3 tools/equates.py --symbols src/CONQUER.SYSTEM_Symbols.txt \
  src/main.s build/gfx/gfxequ.s build/gfx/sndequ.s build/gfx/musequ.s > build/equates.lua
mv src/CONQUER.SYSTEM_Symbols.txt build/symbols.txt   # for tools/bench.lua
rm -f src/_FileInformation.txt src/error_output.txt src/*_Output.txt

# disk image: ProDOS boots and runs the first .SYSTEM file it finds
rm -f build/conquer.po
cadius CREATEVOLUME build/conquer.po CONQUER.GS 800KB > /dev/null
cadius ADDFILE build/conquer.po /CONQUER.GS/ "vendor/prodos/PRODOS#FF0000" > /dev/null
cadius ADDFILE build/conquer.po /CONQUER.GS/ "build/CONQUER.SYSTEM#FF2000" > /dev/null
# the packed graphics, loaded by the game at start (a binary file, $06)
cp build/gfx/conquer.data "build/CONQUER.DATA#060000"
cadius ADDFILE build/conquer.po /CONQUER.GS/ "build/CONQUER.DATA#060000" > /dev/null
# the sound effects (an image of the DOC's sound RAM)
cp build/gfx/conquer.sound "build/CONQUER.SOUND#060000"
cadius ADDFILE build/conquer.po /CONQUER.GS/ "build/CONQUER.SOUND#060000" > /dev/null
# the instruction pages (packed), loaded by the game at start
cp build/gfx/conquer.help "build/CONQUER.HELP#060000"
cadius ADDFILE build/conquer.po /CONQUER.GS/ "build/CONQUER.HELP#060000" > /dev/null
# the title picture (a Super Hi-Res screen image, $C1), shown at start
cp assets/title.shr "build/CONQUER.TITLE#C10000"
cadius ADDFILE build/conquer.po /CONQUER.GS/ "build/CONQUER.TITLE#C10000" > /dev/null
cadius CATALOG build/conquer.po | grep -E "PRODOS|CONQUER.SYSTEM|CONQUER.DATA|CONQUER.TITLE|CONQUER.SOUND|CONQUER.HELP"
echo "Built build/conquer.po"
