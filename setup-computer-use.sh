#!/usr/bin/env bash
#
# setup-computer-use.sh - enable "computer use" for an SSH-driven Codex CLI on a
# Mac (step 11 in the README). Lets an interactive `codex` session attached over
# SSH both see (screenshots) and control (mouse/keyboard) the Mac's desktop.
#
# Codex CLI has no built-in computer-use tool, so we give it one as an MCP server:
# computer-use-mcp (https://github.com/zavora-ai/computer-use-mcp) exposes
# screenshot / click / type / window tools over MCP. This script registers it in
# ~/.codex/config.toml and stands up the GUI-session plumbing it needs.
#
# Why the plumbing is needed: macOS ties Screen Recording + Accessibility to the
# GUI login session, so a process launched over SSH can't reach the display. This
# installs a LaunchAgent that keeps a `tmux` *server* alive *inside* the GUI
# session, pinned to a fixed socket. Because tmux is one server per socket, every
# session the `ic` helper (ic.sh) creates over SSH - `tmux -S <sock> new-session
# ...` - is born on that GUI-session server, so codex (and the MCP server it
# spawns) runs inside the GUI session and can reach the display.
#
# Why tmux (not screen): macOS's system `screen` is the ancient 4.00.03 (2006),
# which can't render emoji, and even Homebrew screen 5.x replaces astral-plane
# emoji with a placeholder. tmux renders them correctly, and its single-server
# model removes screen's "spawn through an anchor" dance.
#
# Socket pinning: tmux's default socket lives under $TMPDIR, which on macOS
# differs between the GUI login session and an incoming SSH session - so the two
# would not share a server. We pin a fixed path ($SOCK) on every invocation
# (here and in ic.sh) so SSH and the GUI session always reach the same server.
#
# PREREQUISITES (one-time, manual - macOS blocks scripting these):
#   System Settings > Privacy & Security. The grants attach to the *responsible
#   process*, which for an MCP server spawned inside tmux is the `tmux` server
#   (codex -> node/npx -> the MCP tools all run as its descendants). So grant tmux:
#     - Screen Recording -> tmux -> on   (covers screenshots)
#     - Accessibility    -> tmux -> on   (covers mouse/keyboard control)
#   Restart the tmux server after granting (a running process caches its
#   permission state at launch): tmux -S /tmp/cc-tmux.sock kill-server
#   Plus a ChatGPT plan that includes Codex, with `codex` already logged in.
#
# Usage:
#   ./setup-computer-use.sh              # install
#   ./setup-computer-use.sh --uninstall  # remove the LaunchAgent + server
#
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

LABEL="com.boxcodex"
SESSION="cc"                 # the persistent anchor session that keeps the server alive
SOCK="/tmp/cc-tmux.sock"     # fixed socket shared by the GUI session and SSH (ic.sh)
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CONFIG="$CODEX_HOME/config.toml"
GUI_UID=$(id -u)

# Prefer Homebrew tmux; fall back to anything on PATH. macOS does not ship tmux.
TMUX_BIN=$(command -v /opt/homebrew/bin/tmux 2>/dev/null \
  || command -v /usr/local/bin/tmux 2>/dev/null \
  || command -v tmux \
  || true)
TMUX_DIR=$(dirname "$TMUX_BIN")

uninstall() {
  log "Removing LaunchAgent and tmux server (socket '$SOCK')"
  launchctl bootout "gui/$GUI_UID/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  "$TMUX_BIN" -S "$SOCK" kill-server 2>/dev/null || true
  log "Done. (The computer-use MCP stays registered in $CONFIG; remove the"
  log " [mcp_servers.computer-use] block there if you want it gone.)"
}

[ "${1:-}" = "--uninstall" ] && { uninstall; exit 0; }
[ "${1:-}" = "" ] || { echo "Unknown option: $1 (use --uninstall or no args)" >&2; exit 1; }

command -v codex >/dev/null || { echo "codex not found on PATH"; exit 1; }
[ -x "$TMUX_BIN" ] || { echo "tmux not found (brew install tmux)"; exit 1; }

# 0. ~/.zshenv (read by *every* zsh, unlike ~/.zshrc which is interactive-only):
#    - PATH so `codex` is found when `ic` spawns it in a fresh tmux session.
#    - PATH so `ic`'s bare `tmux` calls resolve to the same brew tmux the anchor
#      runs (the socket path is fixed, but keep one binary to avoid surprises).
#    - LANG so codex's TUI renders UTF-8 (launchd gives the session no locale).
CODEX_DIR=$(dirname "$(command -v codex)")
for d in "$HOME/.local/bin" "$CODEX_DIR" "$TMUX_DIR"; do
  case "$d" in
    /usr/bin|/bin|/usr/sbin|/sbin) continue ;;  # already on the default PATH
  esac
  path_export="export PATH=\"$d:\$PATH\""
  if ! grep -qFx "$path_export" "$HOME/.zshenv" 2>/dev/null; then
    log "Adding $d to ~/.zshenv (so 'ic' finds codex/tmux in a fresh session)"
    echo "$path_export" >> "$HOME/.zshenv"
  fi
done
if ! grep -q '^export LANG=' "$HOME/.zshenv" 2>/dev/null; then
  log "Adding LANG=en_US.UTF-8 to ~/.zshenv (UTF-8 rendering in the session)"
  echo 'export LANG=en_US.UTF-8' >> "$HOME/.zshenv"
fi

# 1. LaunchAgent: keep a tmux server alive in the GUI login session.
#    tmux daemonizes, so launchd cannot supervise the server process directly.
#    Instead the job runs a zsh wrapper that (re)creates the anchor session, sets
#    server options (C-] prefix - unused by Codex and zsh; no status bar), then
#    blocks in the foreground while the anchor lives. If the server dies the
#    wrapper returns and KeepAlive restarts it. A tmux server with zero sessions
#    exits, so the always-present `cc` anchor is what keeps it alive between ic
#    sessions.
log "Installing LaunchAgent ($PLIST)"
mkdir -p "$HOME/Library/LaunchAgents"
#    The after-load-buffer hook mirrors tmux buffers into the Mac pasteboard, so
#    anything copied inside a session (tmux load-buffer) is visible to `clip get`
#    from the source Mac. Harmless if unused.
WRAP="$TMUX_BIN -S $SOCK has-session -t $SESSION 2>/dev/null || $TMUX_BIN -S $SOCK new-session -d -s $SESSION; $TMUX_BIN -S $SOCK set -g prefix C-]; $TMUX_BIN -S $SOCK set -g status off; $TMUX_BIN -S $SOCK set-hook -g after-load-buffer 'run-shell \"$TMUX_BIN -S $SOCK save-buffer - | pbcopy\"'; while $TMUX_BIN -S $SOCK has-session -t $SESSION 2>/dev/null; do sleep 5; done"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/zsh</string><string>-c</string><string>$WRAP</string></array>
  <key>EnvironmentVariables</key><dict><key>SHELL</key><string>/bin/zsh</string><key>TERM</key><string>xterm-256color</string><key>LANG</key><string>en_US.UTF-8</string></dict>
  <key>WorkingDirectory</key><string>$HOME</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>1</integer>
</dict></plist>
PLISTEOF
plutil -lint "$PLIST" >/dev/null
# Load only if it isn't already loaded. Re-bootstrapping on every run trips
# launchd's restart throttle and the session takes ~10s to reappear. To apply a
# changed plist, run --uninstall first.
if launchctl print "gui/$GUI_UID/$LABEL" >/dev/null 2>&1; then
  log "LaunchAgent already loaded (run --uninstall first to apply plist changes)"
else
  launchctl bootstrap "gui/$GUI_UID" "$PLIST" 2>/dev/null \
    || warn "Could not load the LaunchAgent - run this while logged into the Mac's GUI session."
fi
# The server is up once the anchor session answers on the pinned socket.
up=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if "$TMUX_BIN" -S "$SOCK" has-session -t "$SESSION" 2>/dev/null; then up=1; break; fi
  sleep 1
done
if [ "$up" = 1 ]; then
  log "tmux anchor session '$SESSION' is running (socket $SOCK)"
else
  warn "tmux anchor '$SESSION' not up yet - check: launchctl print gui/$GUI_UID/$LABEL"
fi

# 2. Register the computer-use MCP server for Codex.
#    `codex mcp add` writes a [mcp_servers.computer-use] block into config.toml.
#    npx fetches/caches the package on first use; --prefer-offline keeps later
#    launches fast. Requires Node (npx) on PATH - see setup-codex-env.sh --all or
#    `brew install node`.
log "Registering computer-use MCP in $CONFIG"
mkdir -p "$CODEX_HOME"
if ! command -v npx >/dev/null; then
  warn "npx (Node) not found - install Node first, then re-run. Skipping MCP registration."
else
  codex mcp remove computer-use >/dev/null 2>&1 || true
  codex mcp add computer-use -- npx --yes --prefer-offline @zavora-ai/computer-use-mcp \
    || warn "codex mcp add failed - add [mcp_servers.computer-use] to $CONFIG by hand."
fi

log "Computer use configured."
echo
echo "Next:"
echo "  1. One-time grants (if not done) in System Settings > Privacy & Security,"
echo "     for the 'tmux' entry (grants attach to the responsible process, which"
echo "     is the tmux server - codex and the MCP tools run as its children):"
echo "       Screen Recording -> tmux -> on"
echo "       Accessibility    -> tmux -> on"
echo "     Then restart the server:  tmux -S $SOCK kill-server   (it respawns)"
echo "  2. On your Mac, install the 'ic' helper and run codex (needs a Codex plan):"
echo "       curl -fsSL https://raw.githubusercontent.com/hasansezertasan/codex-controls-mac/main/ic.sh -o ~/.local/bin/ic && chmod +x ~/.local/bin/ic"
echo "       export IC_BOX=<user>@<host>.local   # then:  ic   (new)   ic -c   ic ls   ic a <id>"
