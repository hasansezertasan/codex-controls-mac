#!/usr/bin/env bash
#
# setup-codex-env.sh - configure an opinionated Codex CLI environment on a Mac.
#
# Items (1-6 are core defaults; 7-8 are opt-in, off by default):
#   1. Shell aliases: c, cs (--yolo), cr (resume), crl (resume --last)
#   2. config.toml: default model
#   3. config.toml: model_reasoning_effort = high
#   4. Git hygiene guidance in ~/.codex/AGENTS.md (no AI attribution; conventional
#      commits) - the Codex analog of Claude's "attribution off" setting
#   5. GitHub CLI (gh) into ~/.local/bin (auth separately with 'gh auth login')
#   6. Codex for Chrome guidance in ~/.codex/AGENTS.md (efficient browser use)
#   7. Playwright MCP (installs Node + Google Chrome, headed)
#   8. yt-dlp binary + a Codex prompt
#
# Always ensures `jq` (installs it if missing): the `ic` helper parses Codex's
# rollout JSONL with it for `ic history` / `ic ls`, so it is a hard dependency.
#
# Notes on the port from claude-controls-mac: a few Claude-only items have no
# Codex equivalent and were dropped (custom status line, prompt-suggestion and
# auto-updater toggles, the --fork-session alias). See codex-env-components.md.
#
# Selection:
#   - Run at a terminal with no flags -> interactive checklist (toggle any item;
#     core pre-checked, opt-ins unchecked).
#   - Piped / non-interactive with no flags -> core only (never hangs over SSH).
#   - Flags skip the menu:
#       --playwright   enable item 7
#       --yt-dlp       enable item 8
#       --all          enable items 7 and 8
#       --core         core only, no prompt
#
# Usage:
#   ./setup-codex-env.sh                 # interactive menu (terminal) / core only (piped)
#   ./setup-codex-env.sh --core          # core only, no prompt
#   ./setup-codex-env.sh --all           # core + every opt-in, no prompt
#
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[skip]\033[0m %s\n' "$*"; }

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CONFIG="$CODEX_HOME/config.toml"
AGENTS="$CODEX_HOME/AGENTS.md"
MODEL="${CODEX_MODEL:-gpt-5-codex}"   # override with CODEX_MODEL; names change over time

# Item labels (index 0..7 = items 1..8).
LABELS=(
  "Shell aliases (c / cs / cr / crl)"
  "Default model ($MODEL)"
  "High reasoning effort"
  "Git hygiene guidance (~/.codex/AGENTS.md)"
  "GitHub CLI (gh)"
  "Codex for Chrome guidance (~/.codex/AGENTS.md)"
  "Playwright MCP (heavy: Node + Chrome)"
  "yt-dlp binary + prompt"
)
# Default selection: core (1-6) on, opt-ins (7-8) off.
SEL=(1 1 1 1 1 1 0 0)

FLAGS_GIVEN=0
for arg in "$@"; do
  case "$arg" in
    --playwright) SEL[6]=1;  FLAGS_GIVEN=1 ;;
    --yt-dlp)     SEL[7]=1;  FLAGS_GIVEN=1 ;;
    --all)        SEL[6]=1; SEL[7]=1; FLAGS_GIVEN=1 ;;
    --core)       FLAGS_GIVEN=1 ;;
    -h|--help)    sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

interactive_menu() {
  while true; do
    echo
    echo "Codex CLI environment - choose what to install:"
    echo
    local i mark
    for i in "${!LABELS[@]}"; do
      mark="[ ]"; [ "${SEL[$i]}" = 1 ] && mark="[x]"
      printf "  %2d. %s %s\n" "$((i + 1))" "$mark" "${LABELS[$i]}"
    done
    echo
    printf "Toggle by number (space-separated, e.g. \"7 8\"), or Enter to accept: "
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
    echo "(non-interactive, no flags: installing core only - pass --all/--yt-dlp/--playwright for opt-ins)"
  fi
fi

command -v codex >/dev/null || { echo "codex not found on PATH"; exit 1; }

mkdir -p "$CODEX_HOME"

# --- Xcode Command Line Tools (provides git; needed by gh) ------------------
ensure_clt() {
  if xcode-select -p >/dev/null 2>&1; then return 0; fi
  log "Installing Xcode Command Line Tools (git is a non-functional stub without them)"
  sudo touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  local label
  # BSD sort on macOS has no GNU sort's -V flag. Prefix each label with its
  # numeric Xcode version, then sort the individual version components.
  label=$(softwareupdate -l 2>/dev/null | sed -n 's/.*Label: \(Command Line Tools.*\)/\1/p' \
    | sed -E 's/.*[^0-9]([0-9]+(\.[0-9]+)*)$/\1\t&/' \
    | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n \
    | tail -1 | cut -f2-)
  if [ -n "$label" ]; then
    sudo softwareupdate -i "$label" --verbose || warn "CLT install failed; run 'xcode-select --install' manually"
  else
    warn "No Command Line Tools update found; run 'xcode-select --install' manually"
  fi
  sudo rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
}

# --- jq (hard dependency: 'ic history' / 'ic ls' parse rollout JSONL with it) --
# macOS does not preinstall jq, so provision it. Homebrew first (matches the rest
# of the guide); otherwise drop the official static macOS binary into ~/.local/bin.
ensure_jq() {
  if command -v jq >/dev/null; then log "jq already installed"; return 0; fi
  log "jq (required by 'ic history' / 'ic ls' conversation previews)"
  if command -v brew >/dev/null; then
    brew install jq && return 0
    warn "brew install jq failed; falling back to direct download"
  fi
  local arch
  arch=amd64; [ "$(uname -m)" = "arm64" ] && arch=arm64
  mkdir -p "$HOME/.local/bin"
  curl -fsSL "https://github.com/jqlang/jq/releases/latest/download/jq-macos-${arch}" -o "$HOME/.local/bin/jq"
  chmod +x "$HOME/.local/bin/jq"
  log "jq installed to ~/.local/bin/jq"
}

# --- 1. Shell aliases -------------------------------------------------------
setup_aliases() {
  log "Shell aliases (c / cs / cr / crl) -> ~/.zshrc"
  local zshrc="$HOME/.zshrc"
  touch "$zshrc"
  if grep -qF "# >>> codex-env >>>" "$zshrc"; then
    sed -i '' '/# >>> codex-env >>>/,/# <<< codex-env <<</d' "$zshrc"
  fi
  cat >> "$zshrc" <<'EOF'
# >>> codex-env >>>
alias c='codex'
alias cs='codex --dangerously-bypass-approvals-and-sandbox'
alias cr='codex resume'
alias crl='codex resume --last'
# <<< codex-env <<<
EOF
}

# --- 2-3. config.toml (managed block, prepended so top-level keys precede any
#          [table] section - a TOML requirement). Re-runs replace the block. ---
apply_config() {
  local block=""
  [ "${SEL[1]}" = 1 ] && block+="model = \"$MODEL\"\n"
  [ "${SEL[2]}" = 1 ] && block+="model_reasoning_effort = \"high\"\n"
  touch "$CONFIG"
  local rest
  rest=$(awk '/# >>> codex-env >>>/{s=1} /# <<< codex-env <<</{s=0;next} !s' "$CONFIG")
  if [ -z "$block" ]; then
    if grep -qF "# >>> codex-env >>>" "$CONFIG"; then
      log "Removing managed config.toml keys from $CONFIG"
      printf '%s\n' "$rest" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
    fi
    return
  fi
  log "config.toml (managed keys) -> $CONFIG"
  {
    echo "# >>> codex-env >>>"
    printf "%b" "$block"
    echo "# <<< codex-env <<<"
    [ -n "$rest" ] && { echo ""; printf '%s\n' "$rest"; }
  } > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
}

# --- 4. Git hygiene guidance -> ~/.codex/AGENTS.md --------------------------
setup_git_hygiene() {
  log "Git hygiene guidance -> $AGENTS"
  touch "$AGENTS"
  if grep -qF "<!-- >>> codex-env git >>> -->" "$AGENTS"; then
    sed -i '' '/<!-- >>> codex-env git >>> -->/,/<!-- <<< codex-env git <<< -->/d' "$AGENTS"
  fi
  cat >> "$AGENTS" <<'EOF'
<!-- >>> codex-env git >>> -->
# Git hygiene

- Do NOT add any "generated with AI"/co-authored-by trailer or footer to commits or PRs.
- Use Conventional Commits for commit messages.
- Keep commit messages and PR descriptions concise.
<!-- <<< codex-env git <<< -->
EOF
}

# --- 5. GitHub CLI ----------------------------------------------------------
setup_gh() {
  log "GitHub CLI (gh)"
  if command -v gh >/dev/null; then log "gh already installed"; return 0; fi
  # Homebrew is the simplest, most robust path (this guide already uses brew for
  # codex/tmux). Fall back to a direct download if brew isn't present.
  if command -v brew >/dev/null; then
    brew install gh && { log "gh installed - run 'gh auth login' to authenticate"; return 0; }
    warn "brew install gh failed; falling back to direct download"
  fi
  ensure_clt   # gh repo clone / pr checkout shell out to git
  local arch ver tmp
  arch=amd64; [ "$(uname -m)" = "arm64" ] && arch=arm64
  # Resolve the latest tag from the releases/latest redirect - no jq needed
  # (jq is not preinstalled on a fresh macOS account).
  ver=$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/cli/cli/releases/latest \
        | sed -n 's#.*/tag/v##p')
  [ -n "$ver" ] || { warn "could not resolve latest gh version"; return 0; }
  tmp=$(mktemp -d)
  curl -fsSL "https://github.com/cli/cli/releases/download/v${ver}/gh_${ver}_macOS_${arch}.zip" -o "$tmp/gh.zip"
  unzip -oq "$tmp/gh.zip" -d "$tmp"
  mkdir -p "$HOME/.local/bin"
  cp "$tmp/gh_${ver}_macOS_${arch}/bin/gh" "$HOME/.local/bin/gh"
  rm -rf "$tmp"
  log "gh ${ver} installed - run 'gh auth login' to authenticate"
}

# --- 6. Codex for Chrome guidance -> ~/.codex/AGENTS.md ---------------------
setup_chrome_agents() {
  log "Codex for Chrome guidance -> $AGENTS"
  touch "$AGENTS"
  if grep -qF "<!-- >>> codex-env chrome >>> -->" "$AGENTS"; then
    sed -i '' '/<!-- >>> codex-env chrome >>> -->/,/<!-- <<< codex-env chrome <<< -->/d' "$AGENTS"
  fi
  cat >> "$AGENTS" <<'EOF'
<!-- >>> codex-env chrome >>> -->
# Codex for Chrome

- Prefer the accessibility/DOM tree over screenshots to locate elements.
- Interact with elements by their stable reference, not raw coordinates.
- Only take screenshots when explicitly asked.
<!-- <<< codex-env chrome <<< -->
EOF
}

# --- 7. Playwright MCP (Google Chrome, headed) ------------------------------
setup_playwright() {
  log "Playwright MCP (installs Node if missing, then Google Chrome)"
  if ! command -v node >/dev/null; then
    local nv arch tarball
    nv="v22.14.0"
    arch="x64"; [ "$(uname -m)" = "arm64" ] && arch="arm64"
    tarball="node-${nv}-darwin-${arch}.tar.gz"
    log "Installing Node ${nv} (${arch}) into ~/.local"
    mkdir -p "$HOME/.local"   # not guaranteed to exist on a fresh account
    curl -fsSL "https://nodejs.org/dist/${nv}/${tarball}" | tar -xz -C "$HOME/.local" --strip-components=1
  fi
  command -v npx >/dev/null || { warn "npx still not on PATH; Playwright aborted"; return 0; }
  npx --yes playwright install chrome || warn "Chrome install failed; install it later with 'npx playwright install chrome'"
  codex mcp remove playwright >/dev/null 2>&1 || true
  codex mcp add playwright -- npx -y @playwright/mcp@latest --browser chrome \
    || warn "codex mcp add playwright failed - add [mcp_servers.playwright] to $CONFIG by hand."
}

# --- 8. yt-dlp --------------------------------------------------------------
setup_ytdlp() {
  log "yt-dlp binary + Codex prompt"
  mkdir -p "$HOME/.local/bin" "$CODEX_HOME/prompts"
  curl -fsSL -o "$HOME/.local/bin/yt-dlp" \
    https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos
  chmod +x "$HOME/.local/bin/yt-dlp"
  cat > "$CODEX_HOME/prompts/yt-dlp.md" <<'EOF'
Download video/audio from a URL with yt-dlp.

- Best video+audio: `yt-dlp -f "bv*+ba/b" -o "%(title)s.%(ext)s" <URL>`
- Audio only (m4a): `yt-dlp -x --audio-format m4a -o "%(title)s.%(ext)s" <URL>`
- List formats first: `yt-dlp -F <URL>`

Ask for the URL and desired format if not provided.
EOF
}

# --- run the selected items -------------------------------------------------
ensure_jq                                        # hard dependency for ic history/ls
[ "${SEL[0]}" = 1 ] && setup_aliases
apply_config                                     # items 2-3, internally gated
[ "${SEL[3]}" = 1 ] && setup_git_hygiene
[ "${SEL[4]}" = 1 ] && setup_gh
[ "${SEL[5]}" = 1 ] && setup_chrome_agents
if [ "${SEL[6]}" = 1 ]; then setup_playwright; fi
[ "${SEL[7]}" = 1 ] && setup_ytdlp

log "Done. Open a new shell (or 'source ~/.zshrc') to pick up the aliases."
