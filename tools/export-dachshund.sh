#!/usr/bin/env bash
# Export the flagship Copilot dachshund as a Petdex-format pet pack (issue #10,
# "contribute" half). Compiles the pet, renders an 8×9 grid of 192×208 frames
# (1536×1872 spritesheet) + pet.json, validates the output, and prints the
# one-liner to submit it to the Petdex gallery.
#
# Usage:  tools/export-dachshund.sh [outdir]
#   outdir defaults to assets/petdex/copilot-dachshund (committed as the artifact).
#
# Submission itself is a separate, interactive step (Petdex uses OAuth login):
#   npx petdex submit <outdir>
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-$here/assets/petdex/copilot-dachshund}"
bin="$here/.bin/pet"

echo "› compiling pet…"
mkdir -p "$here/.bin"
swiftc "$here/pet.swift" "$here/PetCore.swift" -o "$bin"

echo "› exporting → $out"
"$bin" --export "$out"

sheet="$out/spritesheet.png"
[ -f "$sheet" ] || { echo "✗ no spritesheet produced" >&2; exit 1; }

# Validate dimensions (must be the canonical 1536×1872) via `sips`, always present on macOS.
dims="$(sips -g pixelWidth -g pixelHeight "$sheet" | awk '/pixel/{print $2}' | paste -sd x -)"
if [ "$dims" != "1536x1872" ]; then
  echo "✗ unexpected spritesheet size: $dims (want 1536x1872)" >&2
  exit 1
fi

echo "✓ valid Petdex pet at $out ($dims)"
echo
echo "Submit it to the gallery (interactive Petdex login):"
echo "    npx petdex submit \"$out\""
