# How to set up your spare Mac for Codex to fully control - a step-by-step guide

Here's a full step-by-step guide on how to turn your spare Mac into an always-on
machine OpenAI's Codex CLI can fully control, with computer use enabled. You'll
be able to talk to it from your phone through the ChatGPT app (ChatGPT Remote),
or from your main Mac over SSH.

This is a port of [ykdojo/claude-controls-mac](https://github.com/ykdojo/claude-controls-mac)
to Codex - same idea, mapped onto Codex CLI's own commands, config, and
features.

In case you're reading this on GitHub Pages, here's [the repo
version](https://github.com/hasansezertasan/codex-controls-mac).

## Why do this?

I wanted a separate environment Codex can control on its own, so I can delegate
tasks I don't necessarily want to run on my own machine - certain kinds of
research and development work.

Codex CLI, especially with `--dangerously-bypass-approvals-and-sandbox` (aka
`--yolo`), carries inherent risk when run on your main machine. You can
mitigate that by creating a separate environment on a spare Mac with everything
it needs and nothing you care about.

It has an added bonus: you can talk to Codex anytime, anywhere from your phone
via ChatGPT Remote, while the work actually runs on the box.

The guide assumes you have a main Mac plus a spare Mac to set up, but you can
adapt it to any two machines.

## Why this setup?

### Why not a container?

Containers still run on your main machine (network requests go out through it),
and can't reach Mac-only apps - which matters if you want Codex to drive GUI
apps through computer use (clicking, dragging, and so on).

### Why a dedicated Mac?

Running an agent with broad permissions is safer on a machine that has nothing
to lose - but you keep a full Mac instead of a container. The approach here:

- **Use an old/spare Mac**, not your main one.
- **Create a fresh local account with no personal data and no Apple ID** signed
  in, so the agent has nothing sensitive to reach.
- **Drive it over SSH** from your main Mac on your local network, and control it
  from your phone.

## What you'll need

- A spare Mac (the **target** / "the box").
- Your everyday Mac (the **source**), on the same Wi-Fi.
- A ChatGPT plan that includes Codex (for login on the box), and for the phone
  and browser steps, the ChatGPT desktop + mobile apps.

---

## 1. Start fresh on the target Mac

### Wipe it first (if it has any personal data)

You'll be giving the agent full access to this machine, so it can reach anything
stored on it. If there's existing data you don't want it to have, erase the
machine first:

- **Macs that support it:** System Settings -> General -> Transfer or Reset ->
  **Erase All Content and Settings**.
- **Older Intel Macs:** restart into Recovery (hold **Cmd-R** at boot), use
  **Disk Utility** to erase the internal drive, then reinstall macOS.

Optionally update to the latest macOS afterward (System Settings -> General ->
Software Update).

### Create a fresh, isolated account

- Create a **new local user account** (System Settings -> Users & Groups).
- **I recommend not signing into an Apple ID.** Skip it during setup.

### Make the account an admin

The account needs admin rights or `sudo` will refuse to run.

- System Settings -> Users & Groups -> set the account to **Allow this user to
  administer this computer**.
- To repair it from another admin account:
  `sudo dseditgroup -o edit -a <user> -t user admin`

---

## 2. Enable Remote Login (SSH) on the target Mac

On the **target**, turn on SSH so the source Mac can connect:

```bash
sudo systemsetup -setremotelogin on
```

If it fails with `Turning Remote Login on or off requires Full Disk Access
privileges`, give your terminal app Full Disk Access first:

- System Settings -> Privacy & Security -> **Full Disk Access**.
- Click **+**, then add **Applications -> Utilities -> Terminal**.
- Quit and reopen the terminal, then rerun the command.

---

## 3. Passwordless sudo for the target account

So the agent (and your SSH commands) can run admin tasks without a password
prompt each time. Run this once on the target. It asks for the login password
this one time:

```bash
echo "<user> ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/<user>-nopasswd >/dev/null
sudo chmod 440 /etc/sudoers.d/<user>-nopasswd
sudo visudo -cf /etc/sudoers.d/<user>-nopasswd   # validate - must print 'parsed OK'
```

- **line 1** writes the rule into `/etc/sudoers.d/`.
- **line 2** makes it read-only - sudo ignores the file otherwise.
- **line 3** validates the syntax; a typo in a sudoers file can lock you out of
  `sudo` entirely, so it must print `parsed OK`.

Test with `sudo -n true`, which succeeds silently if passwordless sudo works.

---

## 4. Find the target's address (hostname or IP)

You can reach the target by either a hostname or an IP. I recommend the
hostname: it stays the same, while the IP can change.

**Hostname (recommended).** Run on the target:

```bash
scutil --get LocalHostName      # prints the hostname, e.g. MacBook-Pro
```

Add `.local` to form the address: `<target-host>.local`.

> **Give the target a unique name.** Each Mac needs a `.local` name unique on
> your network. Rename if needed:
>
> ```bash
> sudo scutil --set LocalHostName codexbox   # -> codexbox.local
> ```

**IP address (not recommended).** Run on the target:

```bash
ipconfig getifaddr en0          # e.g. 192.168.1.80
```

Throughout the rest of the guide, replace `<user>` with the target account name
and `<target-host>` with the hostname, so the address is
`<user>@<target-host>.local`.

---

## 5. Set up passwordless SSH from the source Mac

On the source Mac, create an SSH key (skip if you already have one):

```bash
ssh-keygen -t ed25519
```

Install your public key on the target (asks for the target's login password
once). macOS doesn't ship `ssh-copy-id`, so append the key over plain `ssh`:

```bash
cat ~/.ssh/id_ed25519.pub | ssh <user>@<target-host>.local \
  "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

Test it - this should print the target username with no password prompt:

```bash
ssh <user>@<target-host>.local whoami
```

> **Tip:** add the box to `~/.ssh/config` now - it makes step 13 (phone control
> via Codex Remote SSH) a one-click add later:
>
> ```
> Host codexbox
>   HostName <target-host>.local
>   User <user>
>   IdentityFile ~/.ssh/id_ed25519
> ```

---

## 6. Keep the target awake

macOS sleeps after ~10 minutes idle, even when plugged in, which takes it off
the network. To make it never sleep, run this on the target (or over SSH):

```bash
sudo pmset -c sleep 0          # never system-sleep while plugged in (-c = on charger)
sudo pmset -c disablesleep 1   # also prevents sleep with the lid closed (clamshell)
sudo pmset -c displaysleep 0   # keep the display on too
```

Verify:

```bash
pmset -g | grep -iE 'sleep'
```

`sleep 0`, `SleepDisabled 1`, and `displaysleep 0` confirm it worked.

Stop the screen saver from ever starting so it never locks on its own:

```bash
defaults -currentHost write com.apple.screensaver idleTime 0
```

---

## 7. Clipboard sync over SSH

macOS ships `pbcopy` (write clipboard) and `pbpaste` (read clipboard). Piped
over SSH, they move the clipboard between machines - encrypted, peer-to-peer, no
Apple ID or third-party service.

[`clip.sh`](clip.sh) wraps this into one command with two subcommands, and adds
image support on top of `pbcopy`/`pbpaste` (which are text-only). Install it on
your PATH on the source Mac, and point it at the target with `IC_BOX` ("ic" =
"isolated codex"):

```bash
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/hasansezertasan/codex-controls-mac/main/clip.sh -o ~/.local/bin/clip
chmod +x ~/.local/bin/clip
export IC_BOX="<user>@<target-host>.local"   # add to ~/.zshrc
```

Usage:

- **`clip send`** - this Mac's clipboard → the target (text or image). For an
  image you can paste it straight into a Codex session on the target with
  Ctrl-V.
- **`clip get`** - the target's clipboard → this Mac (text or image).

---

## 8. Install Codex CLI on the target Mac

Install Codex on the box. Homebrew is the easiest to keep updated; npm and the
official install script also work:

```bash
# Homebrew (recommended)
ssh <user>@<target-host>.local 'brew install --cask codex'

# or npm
ssh <user>@<target-host>.local 'npm install -g @openai/codex'

# or the official install script
ssh <user>@<target-host>.local 'curl -fsSL https://chatgpt.com/codex/install.sh | sh'
```

Make sure `codex` is on PATH for non-interactive shells - add its directory to
`~/.zshenv` (read by *every* zsh, unlike `~/.zshrc`). For a Homebrew install on
Apple Silicon:

```bash
ssh <user>@<target-host>.local 'echo '\''export PATH="/opt/homebrew/bin:$PATH"'\'' >> ~/.zshenv'
```

(The `setup-computer-use.sh` script in step 11 also adds the right directories
to `~/.zshenv` for you.)

---

## 9. Set up an opinionated, Codex-friendly environment (optional)

This optional step applies opinionated defaults via
[`setup-codex-env.sh`](setup-codex-env.sh) - shell aliases, `config.toml` model
and reasoning defaults, `AGENTS.md` guidance, the GitHub CLI, and (opt-in)
Playwright MCP and yt-dlp. Every item is toggleable; see the full list in
[`codex-env-components.md`](codex-env-components.md).

Whatever you select, it also ensures `jq` on the box (installing it if missing) -
a hard dependency of the `ic` helper, which parses Codex's rollout JSONL with it
for `ic history` and `ic ls`. Run this step, or `brew install jq` yourself, so
those previews work.

**Interactively on the target** - shows a checklist (core pre-checked, opt-ins
unchecked):

```bash
ssh -t <user>@<target-host>.local \
  'curl -fsSL https://raw.githubusercontent.com/hasansezertasan/codex-controls-mac/main/setup-codex-env.sh -o setup-codex-env.sh && bash setup-codex-env.sh'
```

**Non-interactively** - installs core only by default, or pick with flags
(`--yt-dlp`, `--playwright`, `--all`, `--core`):

```bash
ssh <user>@<target-host>.local \
  'curl -fsSL https://raw.githubusercontent.com/hasansezertasan/codex-controls-mac/main/setup-codex-env.sh -o setup-codex-env.sh && bash setup-codex-env.sh --all'
```

The script is idempotent (OK to re-run).

---

## 10. Log in to Codex and GitHub

Both logins are interactive, so SSH in:

```bash
ssh <user>@<target-host>.local
```

Then run `codex` on the target and choose **Sign in with ChatGPT** (or use an
API key). Follow the prompts - a browser/device flow you can finish from a
browser on your main Mac. You can also start it explicitly with `codex login`.

GitHub - optional, but highly recommended so the agent can work with repos:

```bash
gh auth login
```

If you didn't install the GitHub CLI in
[step 9](#9-set-up-an-opinionated-codex-friendly-environment-optional), do so
first. I recommend a separate GitHub account, not your main one.

---

## 11. Computer use over SSH (optional)

This lets an interactive `codex` session on the target see (screenshots) and
control (mouse/keyboard) its own desktop, driven over SSH.

Codex CLI has no built-in computer-use tool, so we give it one as an MCP server:
[`computer-use-mcp`](https://github.com/zavora-ai/computer-use-mcp) exposes
screenshot / click / type / window tools over MCP and works with Codex CLI.

This doesn't work out of the box - SSH and macOS's permission model get in the
way, so the setup below routes around that.

**Why it needs a workaround:** macOS gates screen capture and input behind
Screen Recording and Accessibility permissions tied to the GUI login session, so
an SSH process can't reach the display. Fix: a LaunchAgent keeps a `tmux` server
alive *inside* the GUI session on a fixed socket; every `codex` session created
there lands on that server and inherits the GUI session, so it (and the MCP
server it spawns) can reach the display. You attach over SSH.

### Scriptable setup

Run [`setup-computer-use.sh`](setup-computer-use.sh) on the target:

```bash
ssh -t <user>@<target-host>.local \
  'curl -fsSL https://raw.githubusercontent.com/hasansezertasan/codex-controls-mac/main/setup-computer-use.sh -o setup-computer-use.sh && bash setup-computer-use.sh'
```

This installs the LaunchAgent (persistent `tmux` server with anchor session
`cc`) and registers `computer-use-mcp` in `~/.codex/config.toml`. Requires tmux
(`brew install tmux`) and Node/npx (for the MCP; `brew install node` or step 9
`--all`). Re-runnable; `--uninstall` to remove.

### Use it from your Mac

Install [`ic.sh`](ic.sh) (`ic` = "isolated codex") on the source Mac:

```bash
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/hasansezertasan/codex-controls-mac/main/ic.sh -o ~/.local/bin/ic
chmod +x ~/.local/bin/ic
echo 'export IC_BOX="<user>@<target-host>.local"' >> ~/.zshrc   # or edit the default in the script
```

Each `ic` spawns its own `codex` session on the box (run several at once) and
attaches:

```bash
ic               # new codex session
ic -c            # continue the most recent conversation (codex resume --last)
ic -r            # resume picker (codex resume)
ic sh            # a plain shell on the box, no codex (alias: ic shell)
ic vnc           # open Screen Sharing (VNC) to the box (see step 15)
ic rc            # how to drive the box from your phone (ChatGPT Remote; see step 13)
ic history       # stored conversations: count, location, recent (alias: hist)
ic ls            # list live sessions (state, age, proc)
ic attach <id>   # attach a running session (alias: ic a)
ic kill <id>     # kill a session (alias: ic k)
ic kill-all      # kill all sessions
ic kill-except <id> <id> ...   # kill all sessions except the listed ones
ic -h            # help
```

All `ic` sessions run with `--dangerously-bypass-approvals-and-sandbox` (the box
is an isolated sandbox, so approvals are auto-granted).

**Copying text out:** sessions run in tmux, and Terminal.app can't reliably
receive clipboard escape sequences, so mouse-selecting won't always reach your
Mac clipboard. Quick workaround: **Cmd-A then Cmd-C** copies the whole visible
screen.

### One-time grants (can't be scripted)

Screen Recording and Accessibility can only be granted in the GUI, and a human
has to do it at the machine (in person or via Screen Sharing) - macOS blocks
synthetic clicks on these prompts.

**The grants go on `tmux`, not `codex`.** macOS attributes capture/control to
the *responsible process* in the chain, which here is the `tmux` server (codex,
then node/npx, then the MCP tools all run as its descendants). So:

1. Grant `tmux` (`/opt/homebrew/bin/tmux` on Apple Silicon, or
   `/usr/local/bin/tmux` on Intel) under both **Screen Recording** and
   **Accessibility**.
2. **Restart the tmux server after granting** - a running process caches its
   permission state at launch:
   `tmux -S /tmp/cc-tmux.sock kill-server` (the LaunchAgent respawns the anchor
   within seconds). Codex sessions started after the restart pick up the grant.

To make the entries appear in System Settings, trigger a computer-use action
(`ic`, then ask Codex to take a screenshot) - macOS adds `tmux` to the list
(toggled off) so you can switch it on. On newer macOS, granting `tmux` **Full
Disk Access** as well suppresses the per-app "tmux would like to access data
from other apps" prompts. Restart the tmux server after any grant.

### Bonus: let your Mac's Codex drive the box's Codex

Because every `ic` session lives on the box's tmux server at a fixed socket, a
Codex session on your source Mac can prompt one directly over SSH - useful for
delegating work to the box and checking on it, agent to agent:

```bash
# find the session (ic ls prints the ids)
ic ls

# type a prompt into it, then confirm with a second Enter
ssh <user>@<target-host>.local "tmux -S /tmp/cc-tmux.sock send-keys -t <session> 'Switch to main and pull; PR #4 is merged.' Enter"
sleep 2
ssh <user>@<target-host>.local "tmux -S /tmp/cc-tmux.sock send-keys -t <session> Enter"

# read the reply (re-run / poll until it's done)
ssh <user>@<target-host>.local "tmux -S /tmp/cc-tmux.sock capture-pane -t <session> -p" | tail -30
```

---

## 12. Install a VPN, or any other app (optional)

I like to run a VPN on the box so its traffic goes out separately from my local
IP. You can just ask the box's Codex to do it once you've finished
[step 11](#11-computer-use-over-ssh-optional): `ic` in and say "install Proton
VPN". It'll download and install the app. The parts it can't do alone:

- **Credentials.** Signing in is yours to do. Send the password securely with
  `clip send` from [step 7](#7-clipboard-sync-over-ssh).
- **macOS permission prompts.** The first connect pops a system prompt to allow
  a VPN / network configuration - approve it at the machine.
- **Computer use for the GUI.** The app is GUI-only, so driving it relies on
  [step 11](#11-computer-use-over-ssh-optional). Once signed in, the agent can
  connect and switch servers itself.

This flow works for pretty much any Mac app, not just a VPN.

---

## 13. Control it from your phone (ChatGPT Remote)

**ChatGPT Remote** is Codex's official way to drive a session from your phone
while the work runs on the host machine (the box), not in the cloud. Your files,
credentials, and local setup stay on the box; your phone sends prompts,
approvals, and follow-ups, and gets back diffs, terminal output, and results.

Because the box is an SSH host (steps 2-5), the clean way to wire this up is
**Remote SSH** from the ChatGPT desktop app on your **source** Mac (the one with
a GUI and the app):

1. **On the source Mac**, make sure the box is in `~/.ssh/config` (see the tip
   in [step 5](#5-set-up-passwordless-ssh-from-the-source-mac)) and `ssh
   codexbox` works. Codex must be installed and on PATH on the box (step 8).
2. In the **ChatGPT desktop app** -> **Settings > Connections > SSH** -> **Add**
   -> pick your host (e.g. `codexbox`) -> choose the remote project folder.
3. Optionally enable **"Keep this Mac awake"** and **Computer Use** under the
   same Connections pane.
4. **On your phone's ChatGPT app** -> **Remote** tab -> pick the host -> start or
   continue a Codex thread. It runs on the box.

You can also pair directly (desktop app -> **Set up Remote** -> scan the QR code
with your phone) if you'd rather drive the desktop app's own session.

> **Note:** unlike Claude Code's `claude remote-control`, Codex's phone pairing
> is **not** started from the CLI - it's set up in the ChatGPT desktop app.
> `ic rc` just prints these steps for reference. Community tools
> (e.g. app-server + a LAN web-terminal bridge) exist if you want a fully
> self-hosted alternative, but ChatGPT Remote is the official path.

---

## 14. Set up Codex for Chrome (optional)

Computer use from [step 11](#11-computer-use-over-ssh-optional) can see the
screen but is a coarse way to drive a browser. **Codex for Chrome** (OpenAI's
official extension) gives proper browser control - navigating, clicking, filling
forms, reading console logs and network requests - and drives your regular
Chrome profile, so the agent can use any logged-in state you set up on the box.

It requires Chrome on the target and a Codex-enabled ChatGPT plan. (At launch it
was unavailable in the EU/UK - check current availability.)

Ask the box's Codex to install Chrome and open the extension. The parts it can't
do alone (do these at the machine, in person or via Screen Sharing):

- **Add the extension to Chrome** and approve its permissions.
- **Log into your account** in the extension. Send login info with `clip send`
  from [step 7](#7-clipboard-sync-over-ssh).

Enable it in Codex: **Codex -> Plugins -> add Chrome -> install extension ->
approve permissions**, then invoke browser tasks with `@Chrome` in a session.

The environment setup from
[step 9](#9-set-up-an-opinionated-codex-friendly-environment-optional) adds a
"Codex for Chrome" guidance section to `~/.codex/AGENTS.md` so browser use is
efficient (prefer the accessibility/DOM tree over screenshots). If you skipped
it, re-run the script - it's idempotent.

---

## 15. Enable Screen Sharing on the target Mac (optional)

This lets you see the target's screen live from the source Mac - and take over
its mouse and keyboard - using macOS's built-in Screen Sharing.

This has to be enabled in the GUI at the machine - since macOS 12.1 it
[can't be enabled from the command line](https://support.apple.com/guide/remote-desktop/enable-remote-management-apd8b1c65bd/mac).

On the target: **System Settings -> General -> Sharing -> Screen Sharing** on.
If **Remote Management** is on, the Screen Sharing toggle may be hidden - turn it
off first.

Connect from the source Mac (or use `ic vnc`):

```bash
open vnc://<user>@<target-host>.local
```

Log in with the target account's password and tick **Remember this password in
my keychain**.

---

## 16. Access it from anywhere with Tailscale (optional)

`.local` names only resolve on your LAN, so everything so far is local-network
only. [Tailscale](https://tailscale.com) fixes that: it connects your machines
with peer-to-peer, end-to-end encrypted
[WireGuard](https://www.wireguard.com) tunnels, so SSH, `ic`, `clip`, and Screen
Sharing work from any network with nothing exposed to the public internet. On
your home network it takes a direct LAN path, so local use stays fast.

Install on the target (the Homebrew formula works headless over SSH; sign in at
the URL the last command prints):

```bash
ssh <user>@<target-host>.local 'brew install tailscale'
ssh <user>@<target-host>.local 'sudo brew services start tailscale'
ssh <user>@<target-host>.local 'sudo tailscale up --operator=<user>'
```

Install on the source, then open the Tailscale app and log in **with the same
account**:

```bash
brew install --cask tailscale-app
```

With MagicDNS (on by default) the target is reachable by bare hostname from
anywhere - the same address, minus `.local`. Switch `IC_BOX` in `~/.zshrc`:

```bash
export IC_BOX="<user>@<target-host>"          # Tailscale - works remotely too
# export IC_BOX="<user>@<target-host>.local"  # original - local network only
```

Screen Sharing works the same way: `open vnc://<user>@<target-host>`.

Recommended, in the [admin console](https://login.tailscale.com/admin):
**device approval** (Settings -> Device management) and **disable key expiry** on
the target (Machines -> **...**), so the box doesn't drop off the network when
its key expires.

To confirm remote access works, put the source Mac on a different network (e.g. a
phone hotspot) and run `ic ls`.

---

## 17. Debloat the box for agent use (optional)

On a dedicated box you want CPU, RAM, and disk I/O going to Codex - not to
Spotlight indexing, Photos analysis, or other consumer features nobody's
watching. Two things are worth separating here:

- **Gatekeeper / `syspolicyd`** - the one that can bite agents. Codex spawns
  processes constantly (`node`, `bash`, `rg`, `git`, test runners). macOS runs a
  Gatekeeper assessment through `syspolicyd` on first launch and when a binary
  changes; results are cached for unchanged, already-seen code. A workload that
  keeps producing, downloading, or rebuilding executables can therefore make
  those assessments pile up until `syspolicyd` becomes a bottleneck - but
  measure before assuming it (below). See
  [#3](https://github.com/hasansezertasan/codex-controls-mac/issues/3).
- **General bloat** - background services that are pointless on a headless
  agent box.

### Tame Gatekeeper (`syspolicyd`)

First confirm it's actually the culprit while Codex is busy by checking
`syspolicyd` CPU directly (`fs_usage` shows file/exec *activity*, not CPU, and
can look quiet even while the daemon is busy):

```bash
# in another SSH session while an agent task runs
top -l 0 -stats pid,cpu,command | grep -i syspolicyd     # CPU %  - Ctrl-C to stop
sudo fs_usage -w -f exec 2>/dev/null | grep -i syspolicy # what it's touching
```

Then reduce the assessment load. On a throwaway box with nothing to lose, the
aggressive options are defensible in a way they wouldn't be on your main Mac:

```bash
# Add the terminal app to Privacy & Security -> Developer Tools, so binaries it
# launches can run unsigned/unnotarized without a per-launch Gatekeeper prompt
# (you still approve it there afterwards). NOTE: this attaches to the terminal
# *app*, so it only helps sessions you start in a local terminal - Codex run
# over SSH or from the step-11 tmux LaunchAgent is not that app's child.
sudo spctl developer-mode enable-terminal

# Strip the quarantine flag from a specific, reviewed checkout - not a broad
# tree, and never a directory of untrusted binaries or nested clones.
xattr -dr com.apple.quarantine <your-repo-dir>
```

If a tool later fails specifically on a protected path (Desktop, Documents,
Downloads, removable volumes), grant the terminal **Full Disk Access** in System
Settings -> Privacy & Security -> Full Disk Access.

> **Nuclear option:** `sudo spctl --master-disable` used to turn Gatekeeper off
> entirely (check current state first with `spctl --status`). On macOS Sequoia
> (15) and later Apple gutted the disable - the command only *surfaces* the
> "Anywhere" option under System Settings -> Privacy & Security -> "Allow
> applications from", which you must then select and authenticate manually (and
> it auto-resets after 30 days). It disables a real security control, so only
> consider it on a disposable box - and note this box isn't truly isolated: it's
> reachable over SSH/Tailscale and runs a persistent tmux LaunchAgent (step 11).
> Re-enable with `sudo spctl --master-enable`.

### Trim background services

[`debloat-mac.sh`](debloat-mac.sh) scripts everything in this section - an
interactive checklist (safe items pre-checked, Gatekeeper/SIP-gated ones opt-in),
idempotent and reversible with `--undo`:

```bash
ssh -t <user>@<target-host>.local \
  'curl -fsSL https://raw.githubusercontent.com/hasansezertasan/codex-controls-mac/main/debloat-mac.sh -o debloat-mac.sh && bash debloat-mac.sh'
```

Or apply the pieces by hand. Every item below is reversible; the "off" command
is shown, with the "on" command in a comment so you can undo it.

```bash
# Spotlight indexing - agents use rg/grep, not Spotlight
sudo mdutil -a -i off                 # on:  sudo mdutil -a -i on

# Photos analysis LaunchAgent - persist the override, then stop the running one
# (disable only blocks future launches; macOS/Photos may re-enable it later)
launchctl disable "user/$(id -u)/com.apple.photoanalysisd"   # enable: swap disable->enable
launchctl bootout "gui/$(id -u)/com.apple.photoanalysisd" 2>/dev/null || true

# Reduce animations / transparency (marginal, but free on a headless box).
# Needs a logout/restart to take effect, and Terminal needs Full Disk Access.
defaults write com.apple.universalaccess reduceMotion -bool true        # restore: -bool false
defaults write com.apple.universalaccess reduceTransparency -bool true  # restore: -bool false
```

`launchctl disable` only blocks *future* launches - it doesn't stop a running
service, which is why the `bootout` line above kills the live `photoanalysisd`.

The CPU-hungry half of media analysis (Visual Look Up / Live Text) is the
**system daemon**, not the per-user agent - so disabling it needs the system
domain, sudo, and SIP turned off (`csrutil disable` from Recovery). Only worth
it on a disposable box:

```bash
sudo launchctl disable system/com.apple.mediaanalysisd   # SIP must be disabled
# re-enable: sudo launchctl enable system/com.apple.mediaanalysisd
```

Also worth a look in **System Settings**, but not cleanly scriptable:

- **iCloud / Apple ID** - keep it signed out (you already did this in
  [step 1](#1-start-fresh-on-the-target-mac)).
- **Siri & Spotlight suggestions** - off.
- **General -> Login Items** - remove unrelated auto-launch items, but keep the
  computer-use LaunchAgent from
  [step 11](#11-computer-use-over-ssh-optional) (its tmux service / MCP server)
  if you set that up.
- **Time Machine** - off unless you're intentionally backing the box up.
- **General -> Software Update** - keep security updates, but disabling
  auto-download avoids background churn.

Sleep and display sleep are handled separately in
[step 6](#6-keep-the-target-awake).

### Hybrid option: containers for headless work

If a task is pure headless compute (builds, tests, research - no GUI), running
it in a Linux container keeps that workload's process churn off the macOS host:
it `exec()`s inside a Linux VM, so it never reaches the host's `syspolicyd`. The
container tooling itself (CLI, API daemon, VM helpers) still runs natively on
macOS - it's only the workload that's isolated.

[`apple/container`](https://github.com/apple/container) runs each Linux
container in its own lightweight VM and is the most native option, with some
constraints to know: it needs **Apple Silicon**, officially targets **macOS 26
(Tahoe)** (it runs on macOS 15 but with networking limitations), and you start
its service with `container system start` before first use. Containers **can't**
drive Mac GUI apps, so keep computer-use tasks
([step 11](#11-computer-use-over-ssh-optional)) on the bare host and
containerize the rest.

---

Credit: this guide is a Codex port of
[ykdojo/claude-controls-mac](https://github.com/ykdojo/claude-controls-mac).
