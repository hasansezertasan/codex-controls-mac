#!/usr/bin/env bash
#
# debloat-mac.sh - trim background macOS features on a dedicated Codex box so its
# CPU, RAM, and disk I/O go to the agent instead of consumer services nobody is
# watching (README step 17).
#
# Items (1-3 are safe defaults; 4-6 are opt-in, off by default):
#   1. Disable Spotlight indexing on all volumes (agents use rg/grep)
#   2. Disable the Photos analysis LaunchAgent (photoanalysisd)
#   3. Reduce motion + transparency (needs logout/restart to fully apply)
#   4. Register this terminal as a Developer Tool (spctl developer-mode) so tools
#      it launches skip repeated Gatekeeper/syspolicyd assessments - the fix for
#      the process-spawn bottleneck in issue #3
#   5. Strip com.apple.quarantine from a work tree ($DEBLOAT_TREE, default ~/work)
#   6. Disable the mediaanalysisd SYSTEM daemon (Visual Look Up / Live Text) -
#      the CPU-hungry half. Needs sudo AND SIP disabled (csrutil disable from
#      Recovery); skipped with a warning if SIP is enabled.
#
# Everything here is reversible: re-run with --undo (plus the same item flags) to
# restore defaults. Idempotent - safe to re-run.
#
# Selection:
#   - Run at a terminal with no flags -> interactive checklist (safe pre-checked,
#     opt-ins unchecked).
#   - Piped / non-interactive with no flags -> safe items only (never hangs over SSH).
#   - Flags skip the menu:
#       --gatekeeper    enable item 4
#       --quarantine    enable item 5
#       --media-daemon  enable item 6
#       --all           enable items 4, 5, 6
#       --safe          items 1-3 only, no prompt
#       --undo          reverse the selected items instead of applying them
#
# Usage:
#   ./debloat-mac.sh                 # interactive menu (terminal) / safe only (piped)
#   ./debloat-mac.sh --safe          # safe items only, no prompt
#   ./debloat-mac.sh --all           # safe + every opt-in, no prompt
#   ./debloat-mac.sh --all --undo    # undo everything
#   DEBLOAT_TREE=~/repos ./debloat-mac.sh --quarantine
#
set -euo pipefail

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[skip]\033[0m %s\n' "$*"; }

UID_NUM="$(id -u)"
TREE="${DEBLOAT_TREE:-$HOME/work}"

LABELS=(
  "Disable Spotlight indexing (all volumes)"
  "Disable Photos analysis agent (photoanalysisd)"
  "Reduce motion + transparency"
  "Register this terminal as a Developer Tool (Gatekeeper exemption)"
  "Strip quarantine from a work tree ($TREE)"
  "Disable mediaanalysisd system daemon (needs SIP off)"
)
# Default selection: safe (1-3) on, opt-ins (4-6) off.
SEL=(1 1 1 0 0 0)

UNDO=0
FLAGS_GIVEN=0
for arg in "$@"; do
  case "$arg" in
    --gatekeeper)   SEL[3]=1; FLAGS_GIVEN=1 ;;
    --quarantine)   SEL[4]=1; FLAGS_GIVEN=1 ;;
    --media-daemon) SEL[5]=1; FLAGS_GIVEN=1 ;;
    --all)          SEL[3]=1; SEL[4]=1; SEL[5]=1; FLAGS_GIVEN=1 ;;
    --safe)         FLAGS_GIVEN=1 ;;
    --undo)         UNDO=1 ;;
    -h|--help)      sed -n '2,48p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

interactive_menu() {
  local verb="apply"; [ "$UNDO" = 1 ] && verb="undo"
  while true; do
    echo
    echo "Debloat macOS for agent use - choose what to $verb:"
    echo
    local i mark
    for i in "${!LABELS[@]}"; do
      mark="[ ]"; [ "${SEL[$i]}" = 1 ] && mark="[x]"
      printf "  %2d. %s %s\n" "$((i + 1))" "$mark" "${LABELS[$i]}"
    done
    echo
    printf "Toggle by number (space-separated, e.g. \"4 5\"), or Enter to accept: "
    local input n idx
    read -r input
    [ -z "$input" ] && break
    for n in $input; do
      if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#LABELS[@]}" ]; then
        idx=$((n - 1))
        [ "${SEL[$idx]}" = 1 ] && SEL[$idx]=0 || SEL[$idx]=1
      fi
    done
  done
}

if [ "$FLAGS_GIVEN" = 0 ]; then
  if [ -t 0 ]; then
    interactive_menu
  else
    echo "(non-interactive, no flags: safe items only - pass --all/--gatekeeper/etc. for opt-ins)"
  fi
fi

# --- 1. Spotlight indexing --------------------------------------------------
spotlight() {
  if [ "$UNDO" = 1 ]; then
    log "Re-enabling Spotlight indexing (all volumes)"
    sudo mdutil -a -i on >/dev/null || warn "mdutil returned nonzero (some volumes may not support indexing)"
  else
    log "Disabling Spotlight indexing (all volumes)"
    sudo mdutil -a -i off >/dev/null || warn "mdutil returned nonzero (some volumes may not support indexing)"
  fi
}

# --- 2. photoanalysisd (per-user LaunchAgent) -------------------------------
# disable/enable writes the persistent per-user override; bootout/kickstart acts
# on the currently-running instance. macOS/Photos may re-launch it later.
photoanalysis() {
  local svc="com.apple.photoanalysisd"
  if [ "$UNDO" = 1 ]; then
    log "Re-enabling $svc"
    launchctl enable "user/$UID_NUM/$svc" 2>/dev/null || warn "could not enable $svc"
    launchctl kickstart "gui/$UID_NUM/$svc" 2>/dev/null || true
  else
    log "Disabling $svc (stops future launches; booting out the running one)"
    launchctl disable "user/$UID_NUM/$svc" 2>/dev/null || warn "could not disable $svc"
    launchctl bootout "gui/$UID_NUM/$svc" 2>/dev/null || true
  fi
}

# --- 3. Reduce motion + transparency ----------------------------------------
# Takes effect on next logout/restart; Terminal needs Full Disk Access or the
# write can be silently reverted.
motion() {
  local val=true; [ "$UNDO" = 1 ] && val=false
  log "Setting reduceMotion / reduceTransparency = $val (logout/restart to apply)"
  defaults write com.apple.universalaccess reduceMotion -bool "$val" || warn "reduceMotion write failed (grant Terminal Full Disk Access)"
  defaults write com.apple.universalaccess reduceTransparency -bool "$val" || warn "reduceTransparency write failed (grant Terminal Full Disk Access)"
}

# --- 4. Developer Tools exemption (Gatekeeper / syspolicyd) ------------------
gatekeeper() {
  if [ "$UNDO" = 1 ]; then
    warn "Developer Tools exemption can't be removed via CLI - toggle it off in"
    warn "  System Settings -> Privacy & Security -> Developer Tools"
    return 0
  fi
  log "Registering this terminal as a Developer Tool (skips repeat Gatekeeper checks)"
  sudo spctl developer-mode enable-terminal || warn "spctl developer-mode failed (unsupported on this macOS?)"
}

# --- 5. Strip quarantine from a work tree -----------------------------------
quarantine() {
  if [ "$UNDO" = 1 ]; then
    warn "Quarantine removal is not reversible (the flag is simply gone); nothing to undo"
    return 0
  fi
  if [ ! -d "$TREE" ]; then
    warn "Work tree '$TREE' does not exist - set DEBLOAT_TREE to an existing path"
    return 0
  fi
  log "Stripping com.apple.quarantine from $TREE (recursive)"
  xattr -dr com.apple.quarantine "$TREE" || warn "xattr failed (nothing quarantined, or permission denied)"
}

# --- 6. mediaanalysisd system daemon (SIP-gated) ----------------------------
media_daemon() {
  local svc="com.apple.mediaanalysisd"
  if csrutil status 2>/dev/null | grep -q "enabled"; then
    warn "SIP is enabled - can't touch system/$svc. Disable SIP from Recovery (csrutil disable) first."
    return 0
  fi
  if [ "$UNDO" = 1 ]; then
    log "Re-enabling system/$svc"
    sudo launchctl enable "system/$svc" || warn "could not enable system/$svc"
  else
    log "Disabling system/$svc (Visual Look Up / Live Text)"
    sudo launchctl disable "system/$svc" || warn "could not disable system/$svc"
    sudo launchctl bootout "system/$svc" 2>/dev/null || true
  fi
}

RUN=(spotlight photoanalysis motion gatekeeper quarantine media_daemon)
for i in "${!RUN[@]}"; do
  [ "${SEL[$i]}" = 1 ] && "${RUN[$i]}"
done

echo
if [ "$UNDO" = 1 ]; then
  log "Done. Some items (reduce motion) need a logout/restart to fully revert."
else
  log "Done. Reduce-motion changes apply after logout/restart. Re-run with --undo to revert."
fi
