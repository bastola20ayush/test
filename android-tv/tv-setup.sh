#!/usr/bin/env bash
# Installs FLauncher on an Android TV over the network, makes it the home
# screen, and turns off the stock launcher, ads and the apps listed in
# packages-to-remove.txt.
#
# Usage: ./tv-setup.sh <tv-ip>[:port]            set up the TV
#        ./tv-setup.sh <tv-ip>[:port] --restore  undo everything this did
set -euo pipefail

if [[ $# -lt 1 || ( $# -eq 2 && $2 != --restore ) || $# -gt 2 ]]; then
  echo "usage: $0 <tv-ip>[:port] [--restore]" >&2
  exit 2
fi

HERE=$(cd "$(dirname "$0")" && pwd)
SERIAL=$1
[[ $SERIAL == *:* ]] || SERIAL="$SERIAL:5555"
LIST="$HERE/packages-to-remove.txt"
LOG="$HERE/removed-packages-${SERIAL//[:.]/_}.log"

FLAUNCHER_PKG=me.efesser.flauncher
FLAUNCHER_HOME=me.efesser.flauncher/.MainActivity
FLAUNCHER_APK="$HERE/flauncher-0.18.0.apk"
FLAUNCHER_URL=https://gitlab.com/api/v4/projects/26632151/packages/generic/flauncher/0.18.0/flauncher-0.18.0.apk
FLAUNCHER_SHA256=376fc528c880cdf7c7c04b2d3708c69f911144498218babb6300808b772af32e

# shellcheck source=tv-lib.sh
source "$HERE/tv-lib.sh"

install_flauncher() {
  if [[ ! -f $FLAUNCHER_APK ]]; then
    echo "Downloading FLauncher 0.18.0..."
    curl -fsSL -o "$FLAUNCHER_APK.part" "$FLAUNCHER_URL"
    mv "$FLAUNCHER_APK.part" "$FLAUNCHER_APK"
  fi
  local sum
  if command -v sha256sum >/dev/null; then
    sum=$(sha256sum "$FLAUNCHER_APK")
  else
    sum=$(shasum -a 256 "$FLAUNCHER_APK")
  fi
  if [[ ${sum%% *} != "$FLAUNCHER_SHA256" ]]; then
    rm -f "$FLAUNCHER_APK"
    echo "Downloaded FLauncher is corrupt (checksum mismatch). Run the script again." >&2
    exit 1
  fi

  echo "Installing FLauncher..."
  tv install -r "$FLAUNCHER_APK" || true
  # Stop here if it didn't install: turning off the stock home screen
  # without a replacement would leave the TV with no home screen.
  if ! tv_sh pm list packages "$FLAUNCHER_PKG" | grep -qxF "package:$FLAUNCHER_PKG"; then
    echo "FLauncher did not install, so nothing else was changed." >&2
    exit 1
  fi
  tv_sh cmd package set-home-activity "$FLAUNCHER_HOME" >/dev/null
}

remove_packages() {
  echo "Turning off stock launcher, ads and preinstalled apps..."
  local installed pkg out
  installed=$(tv_sh pm list packages -e | sed 's/^package://')
  while read -r pkg <&3; do
    pkg=${pkg%%#*}
    pkg=${pkg//[[:space:]]/}
    [[ -n $pkg ]] || continue
    grep -qxF "$pkg" <<<"$installed" || continue
    if is_protected "$pkg"; then
      echo "  skipped   $pkg (needed by the TV)"
      continue
    fi
    out=$(tv_sh pm disable-user --user 0 "$pkg")
    if [[ $out == *"new state: disabled-user"* ]]; then
      echo "  disabled  $pkg"
    else
      out=$(tv_sh pm uninstall -k --user 0 "$pkg")
      if [[ $out != *Success* ]]; then
        echo "  FAILED    $pkg: $out"
        continue
      fi
      echo "  removed   $pkg"
    fi
    echo "$pkg" >>"$LOG"
  done 3<"$LIST"
}

restore() {
  if [[ ! -f $LOG ]]; then
    echo "Nothing to restore: $LOG not found." >&2
    exit 1
  fi
  echo "Turning stock apps back on..."
  local pkg
  while read -r pkg <&3; do
    tv_sh pm install-existing "$pkg" >/dev/null
    tv_sh pm enable --user 0 "$pkg" >/dev/null
    echo "  restored  $pkg"
  done 3< <(sort -u "$LOG")
  echo "Uninstalling FLauncher..."
  tv uninstall "$FLAUNCHER_PKG" >/dev/null || true
  rm "$LOG"
  tv_sh am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null
  echo "Done. The TV is back to its original home screen."
}

find_adb
connect
if [[ ${2:-} == --restore ]]; then
  restore
  exit
fi
install_flauncher
remove_packages
tv_sh am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null
echo "Done. Press Home on the remote; if the TV asks which app to use, pick FLauncher, then Always."
echo "To undo: $0 $1 --restore"
