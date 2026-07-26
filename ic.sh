#!/usr/bin/env bash
#
# ic - "isolated codex": run Codex CLI on the box over SSH, with computer use.
#
# Each `ic` invocation creates its own GUI-session `tmux` session running
# `codex` (so multiple independent conversations can run at once), then attaches
# to it. The persistent `cc` anchor (installed by setup-computer-use.sh) keeps a
# tmux *server* alive inside the GUI login session on a fixed socket; because
# tmux is one server per socket, every session created here lands on that server
# and inherits the GUI login session - which is what makes computer use work
# over SSH (via the computer-use MCP; see setup-computer-use.sh).
#
# Usage:
#   ic                 # new codex session
#   ic -c              # continue the most recent conversation (codex resume --last)
#   ic -r              # resume picker (codex resume)
#   ic <codex flags>   # any other args forward to codex
#   ic ls              # list live ic-* sessions (state, age, proc)
#   ic attach <id>     # attach a running session (alias: ic a)
#
# Config: set IC_BOX to <user>@<host> (default below). IC_SOCK overrides the
# tmux socket path (must match setup-computer-use.sh; default below).
#
set -euo pipefail

BOX="${IC_BOX:-you@codexbox.local}"
SOCK="${IC_SOCK:-/tmp/cc-tmux.sock}"   # fixed tmux socket (matches setup-computer-use.sh)
YOLO="--dangerously-bypass-approvals-and-sandbox"   # the box is a throwaway sandbox

usage() {
  cat <<'EOF'
ic - "isolated codex": run Codex CLI on the box over SSH, with computer use.

All codex sessions run with --dangerously-bypass-approvals-and-sandbox (aka
--yolo): the box is an isolated sandbox, so approvals are auto-granted and there
is no inner sandbox.

Usage:
  ic                 new codex session
  ic -c              continue the most recent conversation (codex resume --last)
  ic -r              resume picker (codex resume)
  ic <codex flags>   any other args forward to codex
  ic sh              a plain shell on the box (no codex; alias: ic shell)
  ic vnc             open Screen Sharing (VNC) to the box
  ic rc              how to drive the box from your phone (ChatGPT Remote; the
                       pairing is done in the ChatGPT desktop app, not the CLI)
  ic history         stored conversations: count, location, recent (alias: hist)
  ic ls              list live sessions (state, age, proc)
  ic attach <id>     attach a running session (alias: ic a)
  ic kill <id>       kill a session (alias: ic k)
  ic kill-all        kill all sessions
  ic kill-except <id> <id> ...   kill all sessions except the listed ones (space-separated)
  ic -h | --help     this help

Config: set IC_BOX to <user>@<host> (default: you@codexbox.local).
Detach from a session with Ctrl-] then D; reattach with: ic attach <id>
EOF
}

# Normalize a session id: accept "ic-1234", "1234", and map to full name.
norm() { case "$1" in ic-*) printf '%s' "$1";; *) printf 'ic-%s' "$1";; esac; }

case "${1:-}" in
  -h|--help|help)
    usage
    ;;

  -c|--continue)
    # Continue the most recent conversation. codex uses a subcommand (not a flag)
    # for this, so translate: ic -c -> codex resume --last.
    sess="ic-$(date +%H%M%S)-$$"
    exec ssh "$BOX" -t "tmux -S $SOCK new-session -s $sess \"codex resume --last $YOLO\""
    ;;

  -r|--resume)
    # Interactive resume picker: ic -r -> codex resume.
    sess="ic-$(date +%H%M%S)-$$"
    exec ssh "$BOX" -t "tmux -S $SOCK new-session -s $sess \"codex resume $YOLO\""
    ;;

  ls)
    # Each live ic-* tmux session: attach state, age, and what's running (codex /
    # a plain shell). Codex has no per-pid session map (unlike Claude Code), so
    # this reports process state only - use `ic history` to browse conversations.
    ssh "$BOX" "SOCK='$SOCK' bash -s" <<'RSCRIPT'
SOCK="${SOCK:-/tmp/cc-tmux.sock}"
sessions=$(tmux -S "$SOCK" list-sessions -F '#{session_name}|#{session_attached}|#{session_created}' 2>/dev/null | grep '^ic-' | sort -t'|' -k3,3nr)
[ -z "$sessions" ] && { echo "No live ic sessions."; exit 0; }
now=$(date +%s)
fmt_age() {
  t="$1"; [ -z "$t" ] && { echo "?"; return; }; [ "$t" -lt 0 ] && t=0
  if [ "$t" -ge 86400 ]; then echo "$((t/86400))d$(((t%86400)/3600))h"
  elif [ "$t" -ge 3600 ]; then echo "$((t/3600))h$(((t%3600)/60))m"
  elif [ "$t" -ge 60 ]; then echo "$((t/60))m"; else echo "${t}s"; fi
}
printf "%-20s %-9s %-7s %s\n" "SESSION" "STATE" "AGE" "PROC"
printf '%s\n' "$sessions" | while IFS='|' read -r name attached created; do
  state=Detached; [ "${attached:-0}" -ge 1 ] 2>/dev/null && state=Attached
  if [ -n "$created" ]; then age=$(fmt_age "$((now - created))"); else age="?"; fi
  # walk the session's pane process tree (a few levels) to find codex
  pids=$(tmux -S "$SOCK" list-panes -t "$name" -F '#{pane_pid}' 2>/dev/null | tr '\n' ' ')
  for p in $pids; do pids="$pids $(pgrep -P "$p" 2>/dev/null)"; done
  for p in $pids; do pids="$pids $(pgrep -P "$p" 2>/dev/null)"; done
  proc=shell
  for p in $pids; do case "$(ps -o comm= -p "$p" 2>/dev/null)" in *codex*) proc=codex; break;; esac; done
  printf "%-20s %-9s %-7s %s\n" "$name" "$state" "$age" "$proc"
done
echo ""
echo "attach: ic attach <id>   (alias: ic a; detach: Ctrl-] then D)"
echo "kill:   ic kill <id>     (alias: ic k)"
echo "        ic kill-all      / ic kill-except <id> <id> ...   (keeps only the listed ones)"
echo "conversations: ic history"
RSCRIPT
    ;;

  attach|a)
    id="${2:-}"
    if [ -z "$id" ]; then
      echo "Usage: ic attach <id>   (see 'ic ls' for live sessions)"; exit 1
    fi
    sess="$(norm "$id")"
    exec ssh "$BOX" -t "tmux -S $SOCK attach -t $sess"
    ;;

  sh|shell)
    # A plain shell in a fresh GUI-session tmux session (no codex) - persists and
    # has GUI access (screencapture etc. work), unlike a plain `ssh` shell.
    sess="ic-sh-$(date +%H%M%S)-$$"
    exec ssh "$BOX" -t "tmux -S $SOCK new-session -s $sess zsh"
    ;;

  vnc)
    # Screen Sharing accepts vnc://user@host, so BOX works as-is (the username
    # is prefilled). Requires Screen Sharing enabled on the box (README step 15).
    open "vnc://$BOX"
    ;;

  rc|remote-control)
    # Codex phone control (ChatGPT Remote) is paired from the ChatGPT *desktop*
    # app, not the CLI - there is no `codex remote-control`. Print the steps.
    cat <<EOF
Drive the box from your phone with ChatGPT Remote (official Codex feature).
Work runs on the box; your phone sends prompts, approvals, and follow-ups.

Set it up once from the ChatGPT desktop app on your *source* Mac (it has the GUI):

  1. ChatGPT desktop -> Settings > Connections > SSH -> Add
       host: $BOX   (the same SSH host this 'ic' uses)
       pick the remote project folder
     Requires: codex installed and on PATH on the box (it is, if 'ic' works).
  2. On your phone's ChatGPT app -> Remote tab -> pick the host -> start/continue
     a Codex thread that runs on the box.
  3. Optional, on the box's GUI (via 'ic vnc'): ChatGPT desktop ->
     Settings > Connections -> "Keep this Mac awake", enable Computer Use.

See README step 13 for details.
EOF
    ;;

  history|hist)
    # Overview of stored Codex conversations. Codex writes one rollout JSONL per
    # session under ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl.
    ssh "$BOX" 'CODEX_HOME="${CODEX_HOME:-$HOME/.codex}" bash -s' <<'RSCRIPT'
d="$CODEX_HOME/sessions"
files=$(find "$d" -type f -name 'rollout-*.jsonl' 2>/dev/null)
[ -z "$files" ] && { echo "No conversations yet in $d"; exit 0; }
n=$(printf '%s\n' "$files" | wc -l | tr -d ' ')
size=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
echo "Conversations"
echo "  $d"
echo "  $n total · ${size:-?}"
echo ""
echo "  recent:"
printf '%s\n' "$files" | xargs -I{} stat -f '%m {}' {} 2>/dev/null | sort -rn | head -10 | while read -r _ f; do
  when=$(stat -f '%Sm' -t '%b %d %H:%M' "$f" 2>/dev/null)
  msgs=$(wc -l < "$f" | tr -d ' ')
  # best-effort first user prompt; tolerant of format drift (degrades to blank)
  prev=$(jq -rs 'first(.[] | (.payload? // .) | select((.role? == "user") or (.type? == "user_message"))
          | (.content? // .message? // .text? // "")
          | if type=="array" then (map(.text? // "") | join(" ")) else tostring end)' \
          "$f" 2>/dev/null | tr '\n\t' '  ' | sed 's/  */ /g' | cut -c1-54)
  printf "  %-14s  %4s msg  %s\n" "$when" "$msgs" "$prev"
done
echo ""
echo "  open/continue:  ic -r   (resume picker)   ·   ic -c   (most recent)"
echo ""
echo "  each file is JSONL, one JSON object per line. read with jq, e.g.:"
echo "    ssh <box> \"jq -rs '[.[]|.payload? // .]' FILE\""
RSCRIPT
    ;;

  kill-all)
    ssh "$BOX" "tmux -S $SOCK list-sessions -F '#{session_name}' 2>/dev/null | grep '^ic-' | xargs -I{} tmux -S $SOCK kill-session -t {} 2>/dev/null || true"
    echo "Killed all ic sessions."
    ;;

  kill-except)
    shift
    if [ $# -eq 0 ]; then
      echo "Usage: ic kill-except <id> [<id>...]   (kills all other sessions; see 'ic ls')"; exit 1
    fi
    keep=""
    for k in "$@"; do keep="$keep $(norm "$k")"; done
    ssh "$BOX" "SOCK='$SOCK' KEEP='$keep' bash -s" <<'RSCRIPT'
SOCK="${SOCK:-/tmp/cc-tmux.sock}"
live=$(tmux -S "$SOCK" list-sessions -F '#{session_name}' 2>/dev/null | grep '^ic-')
# refuse to run on a typo: every keep id must match a live session
for k in $KEEP; do
  printf '%s\n' "$live" | grep -qx "$k" || { echo "ic: keep target $k not found; nothing killed" >&2; exit 1; }
done
n=0
for s in $live; do
  case " $KEEP " in *" $s "*) echo "Kept   $s"; continue;; esac
  tmux -S "$SOCK" kill-session -t "$s" 2>/dev/null && { echo "Killed $s"; n=$((n+1)); }
done
echo "Killed $n session(s)."
RSCRIPT
    ;;

  kill|k)
    id="${2:-}"
    if [ -z "$id" ]; then
      echo "Usage: ic kill <id>   (see also: ic kill-all, ic kill-except <id> <id> ...)"; exit 1
    fi
    case "$id" in
      all|except) echo "ic: did you mean 'ic kill-$id'?" >&2; exit 1;;
    esac
    sess="$(norm "$id")"
    ssh "$BOX" "tmux -S $SOCK kill-session -t $sess 2>/dev/null || true"
    echo "Killed $sess."
    ;;

  *)
    # New session: create `codex <args>` in a fresh GUI-session tmux session and
    # attach in one step. Only simple flags are forwarded (no prompt forwarding),
    # so this stays quote-safe.
    # --dangerously-bypass-approvals-and-sandbox: the box is a throwaway sandbox,
    # so auto-approve everything (no approval prompts, no inner sandbox).
    sess="ic-$(date +%H%M%S)-$$"
    exec ssh "$BOX" -t "tmux -S $SOCK new-session -s $sess \"codex $YOLO $*\""
    ;;
esac
