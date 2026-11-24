# Shared helpers for install.sh, uninstall.sh and tools/island-sync.
# shellcheck shell=bash

REPO=${REPO:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}
PLUGINS=${ISLAND_PLUGINS:-$HOME/.config/omarchy/plugins}
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-island
SHELL_JSON=$HOME/.config/omarchy/shell.json
OVERLAY=$REPO/omarchy-plugin/overlay
BASE=$REPO/omarchy-plugin/base
SHARED=$REPO/omarchy-plugin/shared

# Built-in Omarchy plugins the island takes over. Each one becomes a clone
# (`omarchy plugin clone`) rebuilt from the current Omarchy version plus our
# overlay, so Omarchy updates keep flowing in.
PANELS=(network bluetooth audio monitor power elsewhen weather clock agents menu notifications image-picker)
# Panels that get the island look (Island* components instead of Omarchy's).
STYLED=(network bluetooth audio monitor power elsewhen weather clock agents)
# Third-party plugins restyled in place if installed (optional).
THIRD_PARTY=(crmne.omastats lucas.omadrop mirador)

say()  { printf '\033[1;35m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

_catalog=""
upstream_dir() {   # omarchy.<x> → its source folder in /usr/share/omarchy
  local x=$1
  [[ -n $_catalog ]] || _catalog=$(omarchy-plugin-catalog 2>/dev/null || echo '[]')
  local d
  d=$(jq -r --arg id "omarchy.$x" '.[] | select(.firstParty and .id == $id) | .sourceDir' <<<"$_catalog" | head -1)
  if [[ -z $d || ! -d $d ]]; then
    for d in "/usr/share/omarchy/shell/plugins/$x" "/usr/share/omarchy/shell/plugins/panels/$x"; do
      [[ -d $d ]] && break
    done
  fi
  [[ -d $d ]] && echo "$d"
}

clone_dir() {      # the user's clone of omarchy.<x>, whatever its prefix
  local x=$1 m
  for m in "$PLUGINS"/*/manifest.json; do
    [[ -f $m ]] || continue
    [[ $(jq -r '.omarchy.clonedFrom // empty' "$m" 2>/dev/null) == "omarchy.$x" ]] || continue
    # our own OSD plugin lives in the repo; it is not a clone
    [[ $(readlink -f "$(dirname "$m")") == "$REPO"/* ]] && continue
    dirname "$m"
    return 0
  done
  return 1
}

files_of() { (cd "$1" && find . -type f \( -name '*.qml' -o -name '*.js' \) ! -name 'Island*.qml' | sed 's|^\./||' | sort); }

is_styled() { local x; for x in "${STYLED[@]}"; do [[ $x == "$1" ]] && return 0; done; return 1; }

# Omarchy's panel widgets → island ones (idempotent).
restyle_file() {
  sed -i -E 's/\bKeyboardPanel\b/IslandPanel/g; s/\bPanelSectionHeader\b/IslandSectionHeader/g;
    s/\bPanelSeparator\b/IslandSeparator/g; s/\bPanelSlider\b/IslandSlider/g; s/\bToggleSwitch\b/IslandSwitch/g;
    s/\bPanelActionButton\b/IslandActionButton/g; s/(^|[^A-Za-z.])TextField \{/\1IslandTextField {/g;
    s/(^|[^A-Za-z.])Button \{/\1IslandButton {/g' "$1"
}

link_components() {  # Island*.qml next to every QML folder of a plugin
  local dir
  while IFS= read -r dir; do
    for comp in "$SHARED"/Island*.qml; do ln -sfn "$comp" "$dir/$(basename "$comp")"; done
  done < <(find "$1" -type f -name '*.qml' ! -name 'Island*.qml' -printf '%h\n' | sort -u)
}

# Rebuild a clone from the current Omarchy version + our overlay.
#   overlay file → three-way merge (ours = overlay, base = Omarchy version the
#                  overlay was written against, theirs = current Omarchy)
#   other files  → current Omarchy
# A file the user edited by hand since the last rebuild is backed up first.
# Prints one line per changed file; "conflict:" lines keep Omarchy's version.
rebuild_clone() {
  local x=$1 dest=$2 up f ours base theirs tmp hashdir stamp=${3:-$(date +%Y%m%d-%H%M%S)}
  up=$(upstream_dir "$x") || { echo "missing: omarchy.$x"; return 1; }
  hashdir=$STATE/hashes/$x
  tmp=$(mktemp)
  while IFS= read -r f; do
    theirs=$up/$f ours=$OVERLAY/$x/$f base=$BASE/$x/$f
    if [[ -f $ours && -f $theirs && -f $base ]]; then
      if ! git merge-file -p "$ours" "$base" "$theirs" >"$tmp" 2>/dev/null; then
        cp "$theirs" "$tmp"; echo "conflict: $x/$f"
      fi
    elif [[ -f $ours ]]; then cp "$ours" "$tmp"
    else cp "$theirs" "$tmp"
    fi
    is_styled "$x" && [[ $f == *.qml ]] && restyle_file "$tmp"
    if ! cmp -s "$tmp" "$dest/$f"; then
      if [[ -f $dest/$f && -f $hashdir/$f.sha ]] && [[ $(sha256sum <"$dest/$f") != "$(cat "$hashdir/$f.sha")" ]]; then
        mkdir -p "$STATE/backup/$stamp/$x/$(dirname "$f")"
        cp "$dest/$f" "$STATE/backup/$stamp/$x/$f"
        echo "backup: $x/$f (edited by hand → $STATE/backup/$stamp)"
      fi
      mkdir -p "$dest/$(dirname "$f")"
      cp "$tmp" "$dest/$f"
      echo "updated: $x/$f"
    fi
    mkdir -p "$hashdir/$(dirname "$f")"
    sha256sum <"$dest/$f" >"$hashdir/$f.sha"
  done < <( { files_of "$up"; [[ -d $OVERLAY/$x ]] && files_of "$OVERLAY/$x"; } | sort -u)
  rm -f "$tmp"
  if is_styled "$x" || [[ $x == menu || $x == image-picker ]]; then link_components "$dest"; fi
  return 0
}

restyle_third_party() {  # prints "updated:" lines
  local id f before
  for id in "${THIRD_PARTY[@]}"; do
    [[ -d $PLUGINS/$id ]] || continue
    link_components "$PLUGINS/$id"
    while IFS= read -r f; do
      before=$(md5sum <"$f"); restyle_file "$f"
      [[ $(md5sum <"$f") != "$before" ]] && echo "updated: $id/${f#"$PLUGINS/$id/"}"
    done < <(find "$PLUGINS/$id" -type f -name '*.qml' ! -name 'Island*.qml')
  done
  return 0
}

# Omadrop (optional): three IPC calls the island's shelf needs. Its own
# updates wipe them, so this re-adds them when missing.
patch_omadrop() {
  local od=$PLUGINS/lucas.omadrop/OmaDrop.qml
  [[ -f $od ]] || return 0
  grep -q 'function delivered' "$od" && return 0
  python3 - "$od" <<'PY' && echo "updated: lucas.omadrop/OmaDrop.qml (shelf IPC)" || echo "conflict: lucas.omadrop (shelf IPC could not be added)"
import sys
p = sys.argv[1]; s = open(p).read()
anchor = '    function copyline(value: string): void { root.copyText(String(value || "")) }'
if anchor not in s: sys.exit(1)
s = s.replace(anchor, anchor + """
    // omarchy-island: the island's shelf drops files here and empties it.
    function add(uris: string): void {
      var list = String(uris || "").split(/\\r?\\n/).filter(function(u) { return u.trim() !== "" })
      if (list.length) root.addDroppedUris(list, true)
    }
    function delivered(): void { if (root.itemCount > 0) root.finishDragAll(ShelfModel.cloneJson(root.activeItems)) }
    function removepath(path: string): void { root.removeTileByPath(String(path || "")) }""", 1)
open(p, "w").write(s)
PY
}

# Widget ids that must sit in the (hidden) bar: a bar-widget plugin only runs
# while it is in bar.layout, and the island opens their panels.
bar_widgets() {
  local x d
  for x in "${PANELS[@]}"; do
    d=$(clone_dir "$x") || continue
    jq -e '.kinds | index("bar-widget")' "$d/manifest.json" >/dev/null 2>&1 && jq -r .id "$d/manifest.json"
  done
  for x in "${THIRD_PARTY[@]}"; do
    [[ -f $PLUGINS/$x/manifest.json ]] && jq -e '.kinds | index("bar-widget")' "$PLUGINS/$x/manifest.json" >/dev/null 2>&1 && echo "$x"
  done
  return 0
}
