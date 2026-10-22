# shellcheck shell=bash
# Shared helpers for the tv-*.sh scripts. Source it after setting HERE and SERIAL.
# Provides: PROTECTED, find_adb, is_protected, tv, tv_sh, connect.

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
