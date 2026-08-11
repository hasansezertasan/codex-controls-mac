# Codex CLI environment components

The full list of what [`setup-codex-env.sh`](setup-codex-env.sh) can install.
Core items (1-6) are on by default; opt-ins (7-8) are off by default. In
interactive mode you can toggle any combination.

Regardless of selection, the script also ensures **`jq`** (installs it via
Homebrew, or the official static binary into `~/.local/bin`). It is a hard
dependency of the `ic` helper: `ic history` and `ic ls` parse Codex's rollout
JSONL with `jq` to show each conversation's first prompt.

## Core (on by default)

1. **Shell aliases** - `c` = `codex`, `cs` = `codex
   --dangerously-bypass-approvals-and-sandbox`, `cr` = `codex resume`, and
   `crl` = `codex resume --last`. Added to `~/.zshrc`.
2. **Default model** - `config.toml`: `model = "gpt-5-codex"`. Override the value
   with `CODEX_MODEL=<name> ./setup-codex-env.sh` (model names change over time).
3. **High reasoning effort** - `config.toml`: `model_reasoning_effort = "high"`.
4. **Git hygiene guidance** - appends a marker-delimited block to
   `~/.codex/AGENTS.md`: don't add AI attribution/co-authored-by trailers to
   commits or PRs, use Conventional Commits, keep messages concise. This is the
   Codex analog of Claude's "attribution off" `settings.json` keys (Codex does
   not add attribution on its own, so this is guidance rather than a toggle).
5. **GitHub CLI (gh)** - installs `gh` via Homebrew if available, otherwise
   downloads the binary into `~/.local/bin` (plus the Command Line Tools for
   git); the version is resolved without `jq`. Authenticate separately with
   `gh auth login`.
6. **Codex for Chrome guidance** - appends a marker-delimited block to
   `~/.codex/AGENTS.md` so browser use is efficient: prefer the accessibility/DOM
   tree over screenshots, interact by stable element reference instead of
   coordinates, and only screenshot when asked. Harmless without the extension;
   it only matters once the Codex for Chrome tools are present
   (see [step 14](README.md#14-set-up-codex-for-chrome-optional)).

Items 2-3 are written as a single managed block at the **top** of
`config.toml` (top-level TOML keys must precede any `[table]` section). Re-runs
replace the block. If you set `model` elsewhere in `config.toml`, remove the
duplicate - the managed block is authoritative.

## Opt-in (off by default)

7. **Playwright MCP** - browser automation. Installs Node (if missing) and
   Google Chrome, then registers the MCP with
   `codex mcp add playwright -- npx -y @playwright/mcp@latest --browser chrome`
   (headed). Enable with `--playwright`.
8. **yt-dlp** - the `yt-dlp` binary plus a Codex prompt at
   `~/.codex/prompts/yt-dlp.md`, for downloading video/audio from YouTube and
   other sites. Enable with `--yt-dlp`.

## Dropped from the Claude Code original (no Codex equivalent)

These items in the upstream `setup-claude-env.sh` have no faithful Codex
counterpart and were left out rather than faked:

- **Custom status line** (`context-bar.sh`) - Codex's TUI has no status-line
  command hook.
- **Disable auto-updater + prompt suggestions** - Codex has no matching
  `settings.json` keys.
- **Disable auto-compact** - not a documented Codex config key.
- **Plugin marketplace install (the `dx` plugin)** - Codex has a plugin
  marketplace (`codex plugin marketplace add <org/repo>` +
  `codex plugin install <name>@<marketplace>`), but there is no Codex `dx`
  plugin to install by default. Add marketplaces yourself when you want them.
- **`--fork-session` alias** - not a Codex flag.
