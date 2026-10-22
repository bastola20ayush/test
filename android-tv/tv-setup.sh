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

# Never turned off, even if someone adds them to the list: the TV would stop
# booting, lose its settings menu or its on-screen keyboard.
PROTECTED=(android com.android.systemui com.android.tv.settings com.android.settings
  com.google.android.gms com.google.android.gsf com.android.providers.settings
  com.google.android.inputmethod.latin com.google.android.leanback.ime "$FLAUNCHER_PKG")

find_adb() {
  if command -v adb >/dev/null; then
    ADB=adb
    return
  fi
  # Running in Termux on an Android phone: Google's platform-tools are built
  # for PCs, so use Termux's own adb package.
  if command -v pkg >/dev/null && [[ ${PREFIX:-} == *com.termux* ]]; then
    echo "adb not found, installing it..."
    pkg install -y android-tools
    ADB=adb
    return
  fi
  ADB="$HERE/platform-tools/adb"
  [[ -x $ADB ]] && return
  local os
  case $(uname -s) in
    Darwin) os=darwin ;;
    *) os=linux ;;
  esac
  echo "adb not found, downloading Android platform-tools..."
  curl -fsSL -o "$HERE/platform-tools.zip" \
    "https://dl.google.com/android/repository/platform-tools-latest-$os.zip"
  unzip -qo "$HERE/platform-tools.zip" -d "$HERE"
  rm "$HERE/platform-tools.zip"
}

is_protected() {
  local p
  for p in "${PROTECTED[@]}"; do
    [[ $p == "$1" ]] && return 0
  done
  return 1
}

tv() { "$ADB" -s "$SERIAL" "$@"; }
# Runs a command on the TV and prints its output without Windows line endings.
tv_sh() { tv shell "$@" 2>&1 | tr -d '\r' || true; }

connect() {
  echo "Connecting to $SERIAL..."
  "$ADB" connect "$SERIAL" >/dev/null || true
  local state
  for _ in $(seq 60); do
    state=$("$ADB" -s "$SERIAL" get-state 2>&1 || true)
    case $state in
      device) echo "Connected."; return ;;
      *unauthorized*) echo "  Choose \"Allow\" on the TV screen (tick \"Always allow\")." ;;
      *) "$ADB" connect "$SERIAL" >/dev/null 2>&1 || true ;;
    esac
    sleep 2
  done
  echo "Could not connect to $SERIAL. Check the IP address, that the TV and this" >&2
  echo "computer are on the same network, and that USB/network debugging is on." >&2
  exit 1
}

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
