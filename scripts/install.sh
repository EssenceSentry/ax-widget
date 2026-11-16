#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_app="${1:-dist/AX Widget.app}"
if [[ ! -d "$source_app" ]]; then echo "Build the app first: scripts/build.sh" >&2; exit 1; fi
destination="$HOME/Applications/AX Widget.app"
mkdir -p "$HOME/Applications"
if [[ -d "$destination" ]]; then
    backup="$HOME/Applications/AX Widget.previous.app"
    if [[ -e "$backup" ]]; then echo "Move $backup before replacing another build." >&2; exit 1; fi
    mv "$destination" "$backup"
fi
ditto "$source_app" "$destination"
open "$destination"
echo "Installed $destination"
