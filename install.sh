#!/bin/bash
# omarchy-island installer. Safe to run again (it updates an existing install).
#
#   ./install.sh            install / update
#   ./install.sh --no-start set everything up but leave the bar in place
#
# What it does, all reversible with ./uninstall.sh:
#   1. links quickshell/ as the `island` Quickshell config
#   2. clones the Omarchy plugins the island takes over (`omarchy plugin
#      clone`) and rebuilds them from your Omarchy version + our overlay
#   3. installs the island OSD plugin and turns Omarchy's OSD off
#   4. keeps every panel widget in the (hidden) bar's center so panels open
#      under the island
#   5. installs a systemd user service and an Omarchy post-update hook
set -euo pipefail
# Plugin reloads can temporarily keep the shell busy longer than its 2s default.
export OMARCHY_SHELL_IPC_TIMEOUT=${OMARCHY_SHELL_IPC_TIMEOUT:-30s}
source "$(dirname "$(readlink -f "$0")")/tools/lib.sh"

START=1
[[ ${1:-} == --no-start ]] && START=0

# ── Preflight ────────────────────────────────────────────────────────────────
for c in qs jq git python3 omarchy-shell omarchy-plugin-clone omarchy-plugin-catalog omarchy-toggle-bar systemctl; do
  command -v "$c" >/dev/null || die "missing '$c' — omarchy-island needs Omarchy 4.5 or newer (Quickshell shell)"
done
omarchy-shell shell listPlugins >/dev/null 2>&1 || die "the Omarchy shell is not running (start your session first)"
for x in "${PANELS[@]}" osd; do upstream_dir "$x" >/dev/null || die "this Omarchy has no omarchy.$x plugin — too old or too new for omarchy-island"; done

mkdir -p "$STATE" "$PLUGINS" "$HOME/.config/quickshell" "$HOME/.config/systemd/user" "$HOME/.config/omarchy/hooks/post-update.d"
first_run=0
[[ -f $STATE/installed ]] || first_run=1
if (( first_run )) && [[ -f $SHELL_JSON ]]; then
  cp "$SHELL_JSON" "$STATE/shell.json.before-install"
  say "backed up your shell.json → $STATE/shell.json.before-install"
fi

# ── 1. Quickshell config ─────────────────────────────────────────────────────
QS=$HOME/.config/quickshell/island
if [[ -e $QS && ! -L $QS ]]; then
  mv "$QS" "$STATE/quickshell-island.before-install"
  warn "an existing ~/.config/quickshell/island was moved to $STATE"
fi
ln -sfn "$REPO/quickshell" "$QS"
say "Quickshell config linked"

# ── 2. Clones ────────────────────────────────────────────────────────────────
touch "$STATE/created"
for x in "${PANELS[@]}"; do
  if ! d=$(clone_dir "$x"); then
    say "cloning omarchy.$x"
    omarchy-plugin-clone "omarchy.$x" >/dev/null
    d=$(clone_dir "$x") || die "cloning omarchy.$x failed"
    basename "$d" >>"$STATE/created"
  fi
  rebuild_clone "$x" "$d" | sed 's/^/  /'
done
restyle_third_party | sed 's/^/  /'
patch_omadrop | sed 's/^/  /'
say "panels rebuilt from your Omarchy version"

# ── 3. OSD ───────────────────────────────────────────────────────────────────
# Migrate any older link to our OSD plugin under another id.
for l in "$PLUGINS"/*; do
  [[ -L $l && $(readlink -f "$l") == "$REPO/omarchy-plugin/island-osd" && $(basename "$l") != island.osd ]] || continue
  omarchy-shell shell setPluginEnabled "$(basename "$l")" false >/dev/null 2>&1 || true
  rm "$l"
done
ln -sfn "$REPO/omarchy-plugin/island-osd" "$PLUGINS/island.osd"
omarchy-shell shell rescanPlugins >/dev/null
sleep 1
omarchy-shell shell setPluginEnabled omarchy.osd false >/dev/null 2>&1 || true
[[ $(omarchy-shell shell setPluginEnabled island.osd true 2>/dev/null) == ok ]] || warn "could not enable island.osd (check: omarchy plugin list)"
say "island OSD on, Omarchy OSD off"

# ── 4. Bar layout ────────────────────────────────────────────────────────────
while IFS= read -r id; do
  [[ -n $id ]] || continue
  section=center; [[ $id == *.menu ]] && section=centerEnd
  r=$(omarchy-shell shell putBarWidget "$id" "{\"section\":\"$section\"}" 2>/dev/null || true)
  [[ $r == ok ]] || r=$(omarchy-shell shell moveBarWidget "$id" "{\"section\":\"$section\"}" 2>/dev/null || true)
  [[ $r == ok ]] || warn "$id: $r"
done < <(bar_widgets)
say "panel widgets placed in the bar's center"

# ── 5. Service and hook ──────────────────────────────────────────────────────
# Older installs used island.service.
# Stop it first: with its unit file gone, `disable --now` would not stop it.
if [[ -e $HOME/.config/systemd/user/island.service || -L $HOME/.config/systemd/user/island.service ]] \
   || systemctl --user is-active --quiet island.service 2>/dev/null; then
  systemctl --user stop island.service >/dev/null 2>&1 || true
  systemctl --user disable island.service >/dev/null 2>&1 || true
  rm -f "$HOME/.config/systemd/user/island.service"
  systemctl --user reset-failed island.service >/dev/null 2>&1 || true
fi
rm -f "$HOME/.config/omarchy/hooks/post-update.d/island-sync.hook"
sed "s|@REPO@|$REPO|g" "$REPO/omarchy-island.service.in" >"$HOME/.config/systemd/user/omarchy-island.service"
cat >"$HOME/.config/omarchy/hooks/post-update.d/omarchy-island.hook" <<EOF
#!/bin/bash
# omarchy-island: rebuild the island's clones against the new Omarchy.
[[ -x "$REPO/tools/island-sync" ]] && "$REPO/tools/island-sync" --quiet || true
EOF
chmod +x "$HOME/.config/omarchy/hooks/post-update.d/omarchy-island.hook"
systemctl --user daemon-reload
touch "$STATE/installed"
echo "$REPO" >"$STATE/repo"

omarchy-restart-shell >/dev/null 2>&1 || true
if (( START )); then
  systemctl --user enable --now omarchy-island.service >/dev/null
  systemctl --user restart omarchy-island.service
  say "omarchy-island is running. Hover the pill, click it, scroll on it."
else
  systemctl --user enable omarchy-island.service >/dev/null
  say "installed; start it with: systemctl --user start omarchy-island"
fi
echo "  Remove everything with: $REPO/uninstall.sh"
