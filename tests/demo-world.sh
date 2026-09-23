#!/bin/bash
# Point Herd at a fictional fleet (tests/demo-world/herdr) for screenshots and demos, and put the real
# settings back afterwards. Only this widget's entry in shell.json is touched. The real herdr is never
# called while the demo is on.
#
#   tests/demo-world.sh start | restore
set -euo pipefail
SHELL_JSON="${OMARCHY_SHELL_JSON:-$HOME/.config/omarchy/shell.json}"
BACKUP="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-herd-demo-entry.json"   # this plugin's entry only
STUB="$(cd "$(dirname "$0")" && pwd)/demo-world/herdr"
case "${1:-}" in
start)
  [[ -f $BACKUP ]] && { echo "demo already running (backup exists); run restore first" >&2; exit 1; }
  mkdir -p "$(dirname "$BACKUP")"; jq '[.. | objects | select(.id? == "cgranier.herd")][0]' "$SHELL_JSON" >"$BACKUP"
  jq --arg stub "$STUB" '(.. | objects | select(.id? == "cgranier.herd")) += {herdrPath: $stub, machines: "buildbox,nas,pi", includeLocal: false, notifyBlocked: false, notifyDone: false}' \
    "$SHELL_JSON" >"$SHELL_JSON.tmp" && cat "$SHELL_JSON.tmp" >"$SHELL_JSON" && rm -f "$SHELL_JSON.tmp"
  echo "fictional fleet in place (restart the shell so the pollers pick it up). Restore with: $0 restore" ;;
restore)
  [[ -f $BACKUP ]] || { echo "nothing to restore" >&2; exit 1; }
  jq --slurpfile e "$BACKUP" '(.. | objects | select(.id? == "cgranier.herd")) = $e[0]' "$SHELL_JSON" >"$SHELL_JSON.tmp" && cat "$SHELL_JSON.tmp" >"$SHELL_JSON" && rm -f "$SHELL_JSON.tmp" "$BACKUP"; echo "real settings restored" ;;
*) sed -n '2,5p' "$0" ;;
esac
