#!/bin/bash
set -e
cd "$(dirname "$0")/.."
if [ -z "$THEOS" ]; then
  export THEOS=~theos
fi
make clean
make
echo ""
echo "→ .theos/obj/AstralCheat.dylib"
ls -lh .theos/obj/AstralCheat.dylib 2>/dev/null || ls -lh .theos/obj/*/AstralCheat.dylib 2>/dev/null
