#!/usr/bin/env bash
# Strips an Android TV down to YouTube (plus a live-TV app) on the FLauncher
# home screen. Everything it turns off can be brought back with
# "tv-setup.sh <tv-ip> --restore".
#
# Usage: ./tv-simple.sh <tv-ip>[:port]              list what would be turned off
#        ./tv-simple.sh <tv-ip>[:port] --apply      turn it off, keeping YouTube
#        ./tv-simple.sh <tv-ip>[:port] --diagnose   show which home screen the TV opens and what apps it has
#        ./tv-simple.sh <tv-ip>[:port] --aurora     install Aurora Store (an app store that replaces the Play Store)
#        ./tv-simple.sh <tv-ip>[:port] --nepali-tv  install a live-TV app and add the Nepali channel list
set -euo pipefail

MODE=${2:-}
if [[ $# -lt 1 || $# -gt 2 || ( -n $MODE && $MODE != --apply && $MODE != --aurora && $MODE != --diagnose && $MODE != --nepali-tv ) ]]; then
  echo "usage: $0 <tv-ip>[:port] [--apply | --aurora | --diagnose | --nepali-tv]" >&2
  exit 2
fi

HERE=$(cd "$(dirname "$0")" && pwd)
SERIAL=$1
[[ $SERIAL == *:* ]] || SERIAL="$SERIAL:5555"
LOG="$HERE/removed-packages-${SERIAL//[:.]/_}.log"

FLAUNCHER_PKG=me.efesser.flauncher
YOUTUBE_PKG=com.google.android.youtube.tv
TIVIMATE_PKG=ar.tvplayer.tv
AURORA_PKG=com.aurora.store
PLAY_STORE_PKG=com.android.vending
NEPAL_M3U=https://iptv-org.github.io/iptv/countries/np.m3u

# Apps that stay on. The Play Store is turned off only once Aurora Store is
# installed to take its place (see declutter).
KEEP=("$YOUTUBE_PKG" "$FLAUNCHER_PKG" "$AURORA_PKG"
  "$TIVIMATE_PKG" studio.scillarium.ottnavigator com.nst.iptvsmarterstvbox)

# Anything matching this is left alone even if it shows up as an app: vendor
# settings, HDMI/input switching, keyboards and system services differ on every
# TV brand, and turning them off can make the TV unusable.
SAFE_REGEX='settings|input|hdmi|setup|provision|keyboard|systemui|bluetooth|wifi|webview|installer|permission|provider|google\.android\.gms|gsf|\.ime($|\.)'

# shellcheck source=tv-lib.sh
source "$HERE/tv-lib.sh"

in_list() {
  local needle=$1 item
  shift
  for item in "$@"; do
    [[ $item == "$needle" ]] && return 0
  done
  return 1
}

# Prints the package of every app that can appear on a home screen.
launcher_packages() {
  local cat found pkg main=android.intent.action.MAIN
  found=$(for cat in LEANBACK_LAUNCHER LAUNCHER HOME; do
    tv_sh pm query-activities --brief -a $main -c "android.intent.category.$cat" |
      grep -oE '[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+/' | tr -d '/' || true
  done)
  if [[ -n $found ]]; then
    echo "$found"
    return
  fi
  # Older TVs (Android 7) don't have that command. Read the system's own list
  # of activities instead: each entry is "package/Activity filter", followed by
  # the categories it is listed under.
  found=$(tv_sh dumpsys package | awk '
    $2 ~ /^[A-Za-z0-9_.]+\/[^ ]+$/ && $3 == "filter" { pkg = $2; sub(/\/.*/, "", pkg) }
    /Category: "android.intent.category.(LAUNCHER|LEANBACK_LAUNCHER|HOME)"/ { if (pkg != "") print pkg }
  ' | sort -u)
  if [[ -n $found ]]; then
    echo "$found"
    return
  fi
  echo "Checking each app one by one (about a minute)..." >&2
  while read -r pkg; do
    for cat in LEANBACK_LAUNCHER LAUNCHER HOME; do
      if tv_sh cmd package resolve-activity --brief -a $main -c "android.intent.category.$cat" -p "$pkg" |
        grep -qF "$pkg/"; then
        echo "$pkg"
        break
      fi
    done
  done < <(tv_sh pm list packages -e | sed -n 's/^package://p')
}

re_enable_youtube() {
  tv_sh pm install-existing "$YOUTUBE_PKG" >/dev/null
  tv_sh pm enable --user 0 "$YOUTUBE_PKG" >/dev/null
  if [[ -f $LOG ]]; then
    grep -vxF "$YOUTUBE_PKG" "$LOG" >"$LOG.tmp" || true
    mv "$LOG.tmp" "$LOG"
  fi
  echo "YouTube is turned on."
}

declutter() {
  local installed pkg out uninstall=() todo=() skipped=()
  installed=$(tv_sh pm list packages -e | sed -n 's/^package://p')
  # Every app that was installed by hand, whether it is turned on or not.
  while read -r pkg; do
    [[ -n $pkg ]] || continue
    in_list "$pkg" "${KEEP[@]}" || is_protected "$pkg" || uninstall+=("$pkg")
  done < <(tv_sh pm list packages -3 | sed -n 's/^package://p' | sort -u)
  # Built-in apps that show on a home screen.
  while read -r pkg; do
    [[ -n $pkg ]] || continue
    grep -qxF "$pkg" <<<"$installed" || continue
    in_list "$pkg" ${uninstall[@]+"${uninstall[@]}"} && continue
    if [[ $pkg == "$PLAY_STORE_PKG" ]] && ! grep -qxF "$AURORA_PKG" <<<"$installed"; then
      echo "Keeping the Play Store: Aurora Store isn't installed yet (run --aurora first)."
      skipped+=("$pkg")
    elif in_list "$pkg" "${KEEP[@]}" || is_protected "$pkg" || [[ $pkg =~ $SAFE_REGEX ]]; then
      skipped+=("$pkg")
    else
      todo+=("$pkg")
    fi
  done < <(launcher_packages | sort -u)

  echo
  echo "Keeping (${#skipped[@]}):"
  printf '  %s\n' ${skipped[@]+"${skipped[@]}"}
  echo "To uninstall - apps that were installed by hand (${#uninstall[@]}):"
  printf '  %s\n' ${uninstall[@]+"${uninstall[@]}"}
  echo "To turn off - built-in apps that can't be uninstalled (${#todo[@]}):"
  printf '  %s\n' ${todo[@]+"${todo[@]}"}
  if [[ $MODE != --apply ]]; then
    echo
    echo "Nothing was changed. Run again with --apply to do it."
    return
  fi

  echo
  for pkg in ${uninstall[@]+"${uninstall[@]}"}; do
    out=$(tv_sh pm uninstall "$pkg")
    if [[ $out != *Success* ]]; then
      echo "  FAILED    $pkg: $out"
      continue
    fi
    echo "  uninstalled  $pkg"
    # Updated built-in apps (such as Chrome) fall back to the built-in version.
    if tv_sh pm list packages -e | grep -qxF "package:$pkg"; then
      todo+=("$pkg")
    fi
  done
  for pkg in ${todo[@]+"${todo[@]}"}; do
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
  done
  tv_sh am force-stop "$FLAUNCHER_PKG" >/dev/null
  tv_sh am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null
  echo "Done. Press Home on the remote."
}

components() {
  grep -oE '[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+/[A-Za-z0-9_.$]+' | sort -u || true
}

diagnose() {
  local cat main=android.intent.action.MAIN
  echo "Home screen the TV opens now:"
  tv_sh cmd package resolve-activity --brief -a $main -c android.intent.category.HOME | components | sed 's/^/  /'
  echo "Selecting FLauncher as the home screen..."
  tv_sh cmd package set-home-activity "$FLAUNCHER_PKG/.MainActivity" | sed 's/^/  /'
  echo "Home screen the TV opens now:"
  tv_sh cmd package resolve-activity --brief -a $main -c android.intent.category.HOME | components | sed 's/^/  /'
  echo "Android version: $(tv_sh getprop ro.build.version.release)"
  echo "Raw app query (first lines):"
  tv_sh pm query-activities --brief -a $main -c android.intent.category.LAUNCHER | head -6 | sed 's/^/  /' || true
  echo "Raw per-app query for FLauncher:"
  tv_sh cmd package resolve-activity --brief -a $main -c android.intent.category.LEANBACK_LAUNCHER -p "$FLAUNCHER_PKG" |
    head -6 | sed 's/^/  /' || true
  for cat in HOME LEANBACK_LAUNCHER LAUNCHER; do
    echo "Apps listed under $cat:"
    tv_sh pm query-activities --brief -a $main -c "android.intent.category.$cat" | components | sed 's/^/  /'
  done
  echo "Apps turned off:"
  tv_sh pm list packages -d | sed 's/^/  /'
  echo "Apps installed by hand:"
  tv_sh pm list packages -3 | sed 's/^/  /'
}

aurora() {
  local apk="$HERE/aurora-store.apk" code
  if tv_sh pm list packages "$AURORA_PKG" | grep -qxF "package:$AURORA_PKG"; then
    echo "Aurora Store is already installed."
    return
  fi
  echo "Finding the latest Aurora Store on F-Droid..."
  code=$(curl -fsSL https://f-droid.org/api/v1/packages/$AURORA_PKG |
    grep -oE '"suggestedVersionCode": *[0-9]+' | grep -oE '[0-9]+')
  [[ -n $code ]] || { echo "Couldn't find the Aurora Store version." >&2; exit 1; }
  echo "Downloading Aurora Store (version $code)..."
  curl -fsSL -o "$apk" "https://f-droid.org/repo/${AURORA_PKG}_$code.apk"
  tv install -r "$apk"
  rm -f "$apk"
  if tv_sh pm list packages "$AURORA_PKG" | grep -qxF "package:$AURORA_PKG"; then
    echo "Aurora Store is installed. Run with --apply to turn off the Play Store."
  else
    echo "Aurora Store did not install; the Play Store was left on." >&2
    exit 1
  fi
}

nepali_tv() {
  local list="$HERE/nepal.m3u"
  echo "Downloading the Nepali channel list..."
  curl -fsSL -o "$list" "$NEPAL_M3U"
  echo "Found $(grep -c '^#EXTINF' "$list") channels:"
  sed -n 's/^#EXTINF:[^,]*,//p' "$list" | tr -d '\r' | head -60 | sed 's/^/  /'

  echo
  if tv_sh pm list packages -e | grep -qxF "package:$PLAY_STORE_PKG"; then
    echo "Opening the Play Store on the TV. Choose Install on TiviMate (the TV screen)."
    tv_sh am start -a android.intent.action.VIEW -d "'market://details?id=$TIVIMATE_PKG'" >/dev/null
  else
    echo "Opening Aurora Store on the TV. Search for TiviMate and choose Install."
    echo "(First time: choose Anonymous login if it asks you to sign in.)"
    tv_sh monkey -p "$AURORA_PKG" -c android.intent.category.LAUNCHER 1 >/dev/null
  fi
  read -r -p "When TiviMate has finished installing, press Enter here: "
  tv_sh monkey -p "$TIVIMATE_PKG" -c android.intent.category.LAUNCHER 1 >/dev/null
  echo
  echo "On the TV, in TiviMate: Add playlist -> M3U playlist, then move to the"
  echo "address box so the keyboard opens (cursor in the box)."
  read -r -p "When the cursor is in the address box, press Enter here and I'll type the address: "
  tv_sh input text "$NEPAL_M3U" >/dev/null
  echo "Typed: $NEPAL_M3U"
  echo "On the TV, close the keyboard and choose Next until the channels load."
}

find_adb
connect
if [[ $MODE == --diagnose ]]; then
  diagnose
  exit
fi
if [[ $MODE == --aurora ]]; then
  aurora
  exit
fi
if [[ $MODE == --nepali-tv ]]; then
  nepali_tv
  exit
fi
re_enable_youtube
declutter
