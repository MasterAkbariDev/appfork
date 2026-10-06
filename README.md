# appfork

Create **isolated second instances (profiles) of desktop applications** on macOS and Linux, each with its own user data, its own launcher, and (on macOS) its own Dock icon.

Run two Claude Desktop accounts side by side, keep a "work" and a "personal" Discord, or give any Electron/Chromium app a separate profile, without the second process being redirected into the first.

```text
╔══════════════════════════════════════════════╗
║              APPFORK              ║
║        Create isolated app instances         ║
╚══════════════════════════════════════════════╝

[1/7] Copying application          ✓
[2/7] Updating application ID      ✓
[3/7] Updating display name        ✓
[4/7] Copying icon                 ✓
[5/7] Creating launcher            ✓
[6/7] Signing application          ✓
[7/7] Validating installation      ✓
```

## Why this exists

Launching a second copy of many desktop apps with

```bash
open -n -a "Claude" --args --user-data-dir="..."
```

does not work: the app notices that it is "already running" (same bundle identifier) and hands control to the first instance. The fix that does work, and that this script automates, is:

1. Copy the original `.app`.
2. Give the copy a different `CFBundleIdentifier` and display name.
3. Re-sign the modified copy.
4. Launch the copy's real executable directly with a separate user-data directory.
5. Wrap that command in a small launcher `.app` so it can live in the Dock.

```text
/Applications/Claude.app                       <- untouched original
/Applications/Claude Work.app                 <- copy, bundle id com.anthropic.claude.work
/Applications/Claude Work Launcher.app        <- launcher you pin to the Dock
~/Library/Application Support/Claude-Work     <- separate profile
```

## Quick start (one line)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MasterAkbariDev/appfork/main/appfork.sh)
```

This opens the interactive menu (create / repair / remove / list) without installing anything. It runs the script straight from GitHub, so read it first if you want to be sure what it does. A `curl ... | bash` pipe is deliberately not used because the menu needs your keyboard.

## Requirements

- macOS or Linux, and `bash` (the macOS default 3.2 is fine). The script avoids bash-only features, so it also runs with `zsh appfork.sh`.
- **The target application must support a command-line option that relocates its user data.** For Electron/Chromium apps (Claude, Discord, Slack, VS Code, Chrome, …) that is `--user-data-dir`. Firefox uses `-profile`. Other apps differ. This tool wires up the plumbing; it cannot make an app isolate itself. If the app has no such option, the instance will share the original's data.
- macOS: `PlistBuddy`, `plutil` (both ship with macOS), and `codesign` from the Xcode Command Line Tools (`xcode-select --install`). On Apple Silicon `codesign` is mandatory.
- No Homebrew, GNU coreutils, `jq`, Python, Node or Docker needed.

## Installation

```bash
git clone https://github.com/MasterAkbariDev/appfork.git
cd appfork
chmod +x appfork.sh

# optional: put it on your PATH
mkdir -p ~/.local/bin && ln -s "$PWD/appfork.sh" ~/.local/bin/appfork
```

## Usage

### Interactive

```bash
./appfork.sh
```

A menu offers **Create**, **Repair**, **Remove** or **List**, all in this one script. For Create you are walked through: source app, new name, profile directory, runtime argument (and whether it takes `--arg value` or `--arg=value`), extra arguments, icon, and whether to add the launcher to the Dock. Anything already present on the command line is not asked again.

### Non-interactive

```bash
./appfork.sh \
  --source "/Applications/Claude.app" \
  --name "Claude Work" \
  --profile "Claude-Work" \
  --arg "--user-data-dir"
```

Add `--dry-run` to see exactly what would happen without changing anything.

### Commands and options

| Command | What it does |
| --- | --- |
| *(no arguments)* | Interactive setup |
| `--list` | List instances created by this tool |
| `--repair ["NAME"]` | Rebuild an existing instance from the current original (keeps settings and profile); without a name, pick from a list |
| `--remove ["NAME"]` | Remove an instance; without a name, pick one from a list. The profile is only deleted after explicit confirmation |
| `--dry-run`, `-n` | Show what would be done, change nothing |
| `--help`, `--version` | Help / version |

| Option | Meaning |
| --- | --- |
| `--source PATH` | macOS: source `.app`. Linux: executable (path or command name) |
| `--name NAME` | Name of the new app and launcher |
| `--profile NAME\|PATH` | Profile directory name, or an absolute path |
| `--arg ARG` | The app's data-directory option, e.g. `--user-data-dir` |
| `--arg-style equals\|separate` | `--arg=DIR` (default) or `--arg DIR` |
| `--extra ARG` | Extra launch argument (repeatable) |
| `--icon PATH` / `--no-icon` | Custom icon (`.icns` on macOS; `.png`/`.svg`/`.xpm` on Linux) / generic icon |
| `--desktop-file PATH` | Linux: the original app's `.desktop` file (name, icon, categories are reused) |
| `--dest-dir DIR` | macOS: install here instead of `/Applications` |
| `--dock` / `--no-dock` | macOS: add the launcher to the Dock (append only) or not |
| `--launch-test` | macOS: launch the new instance once and confirm it starts |
| `--on-conflict MODE` | If the instance exists: `abort` (default), `reconfigure`, `replace-app`, `recreate` |
| `--delete-profile` | Allow deleting profile data (with `--remove` or `--on-conflict recreate`) |
| `-y`, `--yes` | Answer yes to y/N questions. Never skips the `DELETE` confirmation |
| `--no-input` | Never prompt; fail if something is missing |
| `-v` / `-q` | Verbose / quiet |
| `--no-color` | Disable colors (also automatic when output is not a terminal, or `NO_COLOR` is set) |

## Examples

### Claude Desktop (macOS)

```bash
./appfork.sh \
  --source "/Applications/Claude.app" \
  --name "Claude Work" \
  --profile "Claude-Work" \
  --arg "--user-data-dir" \
  --dock

open "/Applications/Claude Work Launcher.app"
```

The generated launcher runs:

```bash
exec '/Applications/Claude Work.app/Contents/MacOS/Claude' \
     '--user-data-dir=/Users/you/Library/Application Support/Claude-Work'
```

### Another macOS application

```bash
./appfork.sh \
  --source "/Applications/Discord.app" \
  --name "Discord Work" \
  --profile "Discord-Work" \
  --arg "--user-data-dir" \
  --icon ~/Pictures/work.icns
```

If an app wants the directory as a separate argument (`--profile /path`) rather than `--profile=/path`, add `--arg-style separate`.

### Linux

Linux has no `.app` bundles, so nothing is copied. The tool creates a launcher script and a `.desktop` entry that start the same executable with a different data directory:

```bash
./appfork.sh \
  --source /usr/bin/chromium \
  --name "Chromium Work" \
  --profile chromium-work \
  --arg "--user-data-dir"
```

This creates:

```text
~/.local/share/appfork/launchers/chromium-work.sh
~/.local/share/applications/appfork-chromium-work.desktop
~/.local/share/chromium-work                      (profile)
```

Pass `--desktop-file /usr/share/applications/chromium.desktop` to reuse the original's icon and categories.

### Repairing an instance

If an instance stops starting, or the original app updated, rebuild it. All stored settings and your profile data are kept:

```bash
./appfork.sh --repair "Claude Work"   # or pick from the menu / list
```

### Removing an instance safely

```bash
./appfork.sh --remove "Claude Work"   # or without a name to pick from a list
./appfork.sh --list                    # see what exists
```

Removal deletes the generated app, launcher and metadata (a backup of the metadata is kept), but **keeps your profile** unless you type `DELETE` when asked (or pass `--delete-profile` in scripts). Before deleting an app it verifies that the app still has the bundle identifier recorded at creation time, so it cannot be tricked into deleting something unrelated. If you pinned the launcher to the Dock, remove it with right-click → Options → Remove from Dock.

## If the instance already exists

The tool checks the destination app, launcher, profile, bundle identifier, `.desktop` entry and its own metadata *before* creating anything, then offers:

1. **Abort**
2. **Reconfigure**: rebuild with new answers (stored values offered as defaults)
3. **Replace application only**: rebuild the app and launcher from the current original (e.g. after the original updated), reusing all stored settings
4. **Remove everything and recreate**

The profile is never deleted automatically. Existing items that were *not* created by this tool are never overwritten.

## How it stays safe

- `set -euo pipefail`, quoted paths, spaces in names supported, no `eval`, user input is never executed (paths are single-quote-escaped into generated scripts).
- All deletions go through one guarded function that refuses system/home directories, relative paths and `..` components.
- If anything fails (or you press Ctrl-C), partial output is removed and any previous version is restored.
- Never uses `sudo`. If `/Applications` is not writable it offers `~/Applications`.
- Dock changes only *append* one entry; the Dock is never reset or rewritten.
- The original application is only read, never modified.

## State

Metadata for each instance is kept in `~/.config/appfork/instances/<slug>.meta` as plain `key=value` lines (source, generated app, name, bundle id, profile, launcher, creation date, platform, script version). Previous versions are copied to `backups/` before being overwritten or removed. No passwords, tokens or cookies are stored. Set `APPFORK_CONFIG_DIR` to use another location.

## Known limitations

- **The app must support a data-directory argument.** No such option, no isolation.
- **Ad-hoc re-signing** replaces the developer signature, so the copy is not notarized and loses entitlements tied to the developer identity (iCloud, push notifications, Sign in with Apple, shared keychain groups, …). Apps that depend on those may behave differently.
- **Mac App Store apps** usually fail receipt validation after copying and re-signing.
- **Auto-updaters** update the *original*. Run `--repair` to refresh the copy.
- **Dock icon:** the pinned launcher starts the real app, so macOS may show the running copy as a second Dock icon next to the pinned launcher.
- Apps that keep icons only in an asset catalog (`Assets.car`) give the launcher no icon; pass `--icon your.icns`.
- Electron apps look up their helper apps by `CFBundleName`, so for those the tool leaves `CFBundleName` unchanged (only the display name and bundle id change).
- Apps with their own single-instance logic keyed on something other than bundle id and data directory may still redirect.
- Copying large apps takes disk space (a full copy per instance).
- Linux: sandboxed apps (Flatpak/Snap) may not allow arbitrary data directories.
- Extra arguments cannot contain newlines; names cannot contain `/ \ : * ? " ' < > | $ ; \``.
- Adding to the Dock restarts the Dock process once. If it fails you are told to drag the launcher there manually.

## Troubleshooting

| Problem | Try |
| --- | --- |
| The app opens the original profile / jumps to the first instance | Check the app really honors the argument you passed; try `--arg-style separate` |
| "can't be opened" / damaged | `codesign --verify --deep --strict -vv "/Applications/<Name>.app"`; make sure the Command Line Tools are installed |
| Launcher has no icon | Pass `--icon file.icns` and run `--repair` |
| `/Applications` not writable | Use `--dest-dir ~/Applications` |

## Verification status

The script has been exercised on macOS (bash 3.2 and zsh) against a synthetic app bundle, covering creation, signing, duplicate handling, rollback, listing and removal, and with a simulated Linux environment for the launcher/`.desktop` path. It has not been run against real third-party apps such as Claude Desktop here, and the Dock integration has not been exercised live. Try `--dry-run` first on a new app.

## License

[MIT](LICENSE)
