#!/usr/bin/env bash
# Builds dist/RXPQuestPanel-v<version>.zip and dist/release.json from the files
# in the repo root. The version comes from "## Version:" in RXPQuestPanel.toc.
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=RXPQuestPanel
TOC="$NAME.toc"
VERSION=$(sed -n 's/^## Version: *//p' "$TOC" | tr -d '\r[:space:]')
[ -n "$VERSION" ] || { echo "no ## Version in $TOC" >&2; exit 1; }
ZIP="$NAME-v$VERSION.zip"

rm -rf dist
mkdir -p "dist/$NAME"
cp "$TOC" Core.lua README.txt "dist/$NAME/"
(cd dist && zip -qrX "$ZIP" "$NAME" && rm -rf "$NAME")

# release.json tells WowUp (and other managers) which game flavor each zip is for.
# Flavors come from the TOC's ## Interface numbers: 16xxx = WoW Forever, 11xxx = Classic Era.
meta=""
for n in $(sed -n 's/^## Interface: *//p' "$TOC" | tr -d '\r' | tr ',' ' '); do
  case "$n" in
    16*) flavor=forever ;;
    11*) flavor=classic ;;
    *) continue ;;
  esac
  meta="$meta${meta:+, }{\"flavor\": \"$flavor\", \"interface\": $n}"
done
[ -n "$meta" ] || { echo "no known flavors in ## Interface" >&2; exit 1; }
cat > dist/release.json <<JSON
{
  "releases": [
    {
      "name": "$NAME",
      "version": "v$VERSION",
      "filename": "$ZIP",
      "nolib": false,
      "metadata": [$meta]
    }
  ]
}
JSON

# Release notes: the "Changes in <version>" section of README.txt.
awk -v h="Changes in $VERSION" '
  $0 == h { on = 1; next }
  on && /^Changes in / { exit }
  on { print }
' README.txt | sed 's/^  //' > dist/NOTES.md
[ -s dist/NOTES.md ] || echo "RXP Quest Panel v$VERSION" > dist/NOTES.md
echo "$VERSION" > dist/VERSION
echo "built dist/$ZIP"
