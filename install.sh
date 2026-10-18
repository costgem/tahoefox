#!/usr/bin/env bash

set -euo pipefail

NAME="tahoefox"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES=(userChrome.css userContent.css)
BLOCK_BEGIN="// ${NAME}:begin"
BLOCK_END="// ${NAME}:end"

profile=""
mode="copy"
action="install"
dry_run=0
migrate=1
force=0

usage() {
  cat <<EOF
Usage: ./install.sh [options]

  -p, --profile PATH   Install into this profile folder instead of the default one
  -l, --link           Link the CSS files instead of copying them (handy while editing)
  -u, --uninstall      Remove the theme and its preferences from the profile
      --no-migrate     Do not carry over existing gwfox.* preferences
  -n, --dry-run        Show what would happen without changing anything
  -f, --force          Run even if Firefox appears to be open
  -h, --help           Show this help

Firefox should be closed while the installer runs.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--profile) profile="${2:?--profile needs a path}"; shift 2 ;;
    -l|--link) mode="link"; shift ;;
    -u|--uninstall) action="uninstall"; shift ;;
    --no-migrate) migrate=0; shift ;;
    -n|--dry-run) dry_run=1; shift ;;
    -f|--force) force=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

say() { printf '%s\n' "$*"; }
run() {
  if [[ $dry_run -eq 1 ]]; then
    say "  [dry run] $*"
  else
    "$@"
  fi
}

firefox_roots() {
  if [[ -n "${FIREFOX_ROOT:-}" ]]; then
    printf '%s\n' "$FIREFOX_ROOT"
    return
  fi
  case "$(uname -s)" in
    Darwin) printf '%s\n' "$HOME/Library/Application Support/Firefox" ;;
    *)
      printf '%s\n' \
        "$HOME/.mozilla/firefox" \
        "$HOME/snap/firefox/common/.mozilla/firefox" \
        "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"
      ;;
  esac
}

default_profile() {
  local root="$1" ini="$1/profiles.ini"
  [[ -f "$ini" ]] || return 1
  awk -v root="$root" '
    function resolve(p, rel) { return rel == "0" ? p : root "/" p }
    { sub(/\r$/, "") }
    /^\[/ { section = $0; next }
    {
      eq = index($0, "=")
      if (eq == 0) next
      key = substr($0, 1, eq - 1); value = substr($0, eq + 1)
    }
    section ~ /^\[Install/ && key == "Default" { install = value }
    section ~ /^\[Profile/ && key == "Path" { path[section] = value }
    section ~ /^\[Profile/ && key == "IsRelative" { rel[section] = value }
    section ~ /^\[Profile/ && key == "Default" && value == "1" { marked = section }
    END {
      if (install != "") {
        r = "1"
        for (s in path) if (path[s] == install) r = rel[s]
        print resolve(install, r)
        exit
      }
      if (marked != "") { print resolve(path[marked], rel[marked]); exit }
      exit 1
    }
  ' "$ini"
}

find_profile() {
  local root found
  while IFS= read -r root; do
    if found="$(default_profile "$root")" && [[ -d "$found" ]]; then
      printf '%s\n' "$found"
      return 0
    fi
  done < <(firefox_roots)
  return 1
}

firefox_running() {
  pgrep -x firefox >/dev/null 2>&1 || pgrep -x firefox-bin >/dev/null 2>&1 ||
    pgrep -f "Firefox.app/Contents/MacOS/firefox" >/dev/null 2>&1
}

strip_block() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
    index($0, b) == 1 { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip
  ' "$file"
}

migrated_prefs() {
  local prefs="$1/prefs.js"
  [[ $migrate -eq 1 && -f "$prefs" ]] || return 0
  grep -E '^user_pref\("gwfox\.[^"]+", ' "$prefs" |
    grep -v '"gwfox\.safari"' |
    sed -E 's/^user_pref\("gwfox\./user_pref("tahoefox./' || true
}

block_prefs() {
  local file="$1/user.js"
  [[ -f "$file" ]] || return 0
  awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
    index($0, b) == 1 { inside = 1; next }
    $0 == e { inside = 0; next }
    inside && /^user_pref\("tahoefox\./
  ' "$file"
}

carry_over_prefs() {
  local dir="$1" prefs="$1/prefs.js" lines line name seen=" "
  lines="$(block_prefs "$dir"; migrated_prefs "$dir")"
  [[ -n "$lines" ]] || return 0
  while IFS= read -r line; do
    name="${line#user_pref(\"}"
    name="${name%%\"*}"
    [[ "$seen" == *" $name "* ]] && continue
    seen+="$name "
    if [[ -f "$prefs" ]] && grep -qF "user_pref(\"$name\"," "$prefs"; then
      continue
    fi
    say "Setting $name in prefs.js"
    if [[ $dry_run -eq 0 ]]; then
      printf '%s\n' "$line" >> "$prefs"
    fi
  done <<< "$lines"
}

pref_block() {
  say "$BLOCK_BEGIN"
  say 'user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);'
  say 'user_pref("svg.context-properties.content.enabled", true);'
  if [[ "$(uname -s)" == "Darwin" ]]; then
    say 'user_pref("widget.macos.native-context-menus", false);'
  fi
  say "$BLOCK_END"
}

install_theme() {
  local dir="$1" chrome="$1/chrome" stamp backup="" f
  stamp="$(date +%Y%m%d-%H%M%S)"

  if [[ -d "$chrome" ]] && find "$chrome" -mindepth 1 -maxdepth 1 | grep -q . &&
    ! compgen -G "$dir/chrome.${NAME}-backup-*" >/dev/null; then
    backup="$dir/chrome.${NAME}-backup-$stamp"
    say "Backing up the current chrome folder to $(basename "$backup")"
    run cp -R "$chrome" "$backup"
  fi
  run mkdir -p "$chrome"

  for f in "${FILES[@]}"; do
    run rm -f "$chrome/$f"
    if [[ "$mode" == "link" && "$f" == "userContent.css" ]]; then
      say "Hard-linking $f"
      if ! run ln "$SRC_DIR/$f" "$chrome/$f"; then
        say "Could not hard-link $f, copying it instead"
        run cp "$SRC_DIR/$f" "$chrome/$f"
      fi
    elif [[ "$mode" == "link" ]]; then
      say "Linking $f"
      run ln -s "$SRC_DIR/$f" "$chrome/$f"
    else
      say "Copying $f"
      run cp "$SRC_DIR/$f" "$chrome/$f"
    fi
  done

  carry_over_prefs "$dir"

  say "Writing preferences to user.js"
  if [[ $dry_run -eq 1 ]]; then
    pref_block | sed 's/^/  [dry run] /'
  else
    local tmp
    tmp="$(mktemp)"
    { strip_block "$dir/user.js"; pref_block; } > "$tmp"
    mv "$tmp" "$dir/user.js"
  fi
}

uninstall_theme() {
  local dir="$1" chrome="$1/chrome" f latest
  for f in "${FILES[@]}"; do
    if [[ -e "$chrome/$f" || -L "$chrome/$f" ]]; then
      say "Removing $f"
      run rm -f "$chrome/$f"
    fi
  done
  latest="$(ls -d "$dir"/chrome."${NAME}"-backup-* 2>/dev/null | sort | head -n 1 || true)"
  if [[ -n "$latest" ]]; then
    say "Restoring files from $(basename "$latest")"
    run cp -R "$latest/." "$chrome/"
  fi
  if [[ -f "$dir/user.js" ]]; then
    say "Removing Tahoefox preferences from user.js"
    if [[ $dry_run -eq 0 ]]; then
      local tmp
      tmp="$(mktemp)"
      strip_block "$dir/user.js" > "$tmp"
      mv "$tmp" "$dir/user.js"
    fi
  fi
  say "Tahoefox's own about:config switches (tahoefox.*) stay in place; reset them there if you like."
}

main() {
  if [[ -z "$profile" ]]; then
    profile="$(find_profile)" || {
      say "Could not find a Firefox profile. Pass one with --profile (see about:profiles)." >&2
      exit 1
    }
  fi
  [[ -d "$profile" ]] || { say "Profile folder not found: $profile" >&2; exit 1; }

  if firefox_running && [[ $dry_run -eq 0 && $force -eq 0 ]]; then
    say "Firefox is running. Quit it first, then run the installer again." >&2
    exit 1
  fi

  say "Profile: $profile"
  if [[ "$action" == "uninstall" ]]; then
    uninstall_theme "$profile"
    say "Done. Start Firefox to go back to the stock look."
  else
    install_theme "$profile"
    say "Done. Start Firefox to see Tahoefox."
  fi
}

main
