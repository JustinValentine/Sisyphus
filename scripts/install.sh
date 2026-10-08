#!/bin/bash
# Builds Sisyphus and installs it in Applications, where Launchpad and Spotlight find it and it can
# be kept in the Dock. Run it again after changes to update the installed copy.
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build.sh
DEST=/Applications
[[ -w "$DEST" ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
APP="$DEST/Sisyphus.app"
# Replace rather than overwrite in place, for the same code-signing reason as the build.
rm -rf "$APP"
ditto build/Sisyphus.app "$APP"
# Touch and register now so Launchpad, Spotlight and the Dock pick up the app, and any new icon,
# right away instead of serving a cached one.
touch "$APP" "$APP/Contents/Info.plist"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
printf 'Installed %s\n' "$APP"
if pgrep -xq Sisyphus; then
    printf 'Sisyphus is running. Quit it and open it again to use this version.\n'
fi
