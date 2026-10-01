# VidPrompt source

Native Swift macOS 26 app, version **1.2.0**, build **35**. Markdown scripts are the source of truth, with a library/editor and a separate floating presenter. Camera recording and advanced script settings are available. Source has no external package dependencies.

## Build and test

Requires macOS 26+, full Xcode with Swift 6.2+, and its command-line tools. `env.sh` selects the Xcode toolchain and SDK explicitly; Command Line Tools alone cannot build the SwiftUI app. Accept Xcode's licence and finish its first-launch setup before building. MCP additionally requires Node 18+ on PATH; the GUI and CLI do not require Node.

From this `Source/` directory:

```sh
source env.sh
zsh test.sh
zsh mcp/check-mcp.sh
zsh build.sh
```

The build produces `../Outputs/VidPrompt 1.2.0.zip`. Builds stage outside file-provider folders, sign with hardened runtime and verify both app and helper. The existing local ReadAlong Dev identity is used if available, otherwise ad hoc signing. These are local development archives, not Developer ID signed or notarised releases for other Macs.

To prepare a simple download disk image from an already verified app bundle, run `checks/package-dmg.sh /path/to/VidPrompt.app /path/to/output-folder`. It stages in `/private/tmp`, adds the standard Applications shortcut and reports the bundle's macOS minimum and executable architectures. It refuses to replace an existing DMG. This does not sign or notarise the app.

Optional overrides: `VIDPROMPT_BUILD_ROOT`, `VIDPROMPT_TEST_SCRATCH` and `VIDPROMPT_OUTPUT_ROOT` select disposable cache/output paths. Use a short, owned path outside Documents, such as `/private/tmp/vp-build`. Never test against a personal library.

## Install and first use

Install with `zsh install.sh`. The guarded installer refuses a running app, verifies the archive and preserves the previous installation on failure. It also links `~/.local/bin/vidprompt`. Keep the previous archive for rollback.

Open VidPrompt, import a script or choose New Script, choose Voice or Manual in Script settings, then press Present. Voice follows your spoken words on device; Manual scrolls at the speed you choose. Press Start in the presenter, Pause to stop following, or Back to start to return to the first word. New libraries start with simple controls; Show advanced settings reveals detailed appearance, voice and saved settings without changing saved choices. Allow camera/microphone permissions when using those features. Recording is in the Camera toolbar and uses the pinned preview format, at most 1920×1080; live hardware acceptance remains pending.

## Relationship to JuniorPrompter 0.17.0

VidPrompt is the renamed app; it uses bundle id `com.juniornkanabassi.VidPrompt`, data folder `~/Library/Application Support/VidPrompt` and recordings folder `~/Movies/VidPrompt`, so it can be installed beside the old JuniorPrompter.app; scripts are not copied across automatically.

## Disposable built-app verification

```sh
work=$(mktemp -d /private/tmp/vp-check.XXXXXX)
ditto -x -k '../Outputs/VidPrompt 1.2.0.zip' "$work"
source env.sh
python3 checks/check-built-app.py "$work/VidPrompt.app"
```

The checker creates its own `--data-directory`, runs the packaged CLI/MCP and reads GUI accessibility state without input or focus changes. The terminal needs Accessibility permission for the GUI assertions; denial is a failed check, not a pass. Only the checker-owned disposable process is terminated. Evidence is retained in the printed temporary folder. `test.sh` separately compiles/runs the XCTest bundle; six external/audio acceptance tests are opt-in and reported as skipped unless configured.

For manual isolated use, launch the app executable with `--data-directory /private/tmp/vp-data`. `--agent-screen` uses an already-connected Agent Screen; `--capture-visible` allows presenter captures for inspection only. Ordinary launches exclude the presenter from capture, but named recording/sharing workflows still need acceptance. OBS integration and iPhone/iCloud editing remain deferred.

## AI control

VidPrompt 1.2.0 exposes its existing GUI actions through a private Unix socket, a bundled CLI and an MCP shim. Requires macOS 26; MCP requires Node 18+ and uses protocol 2025-06-18. `install.sh` links `~/.local/bin/vidprompt` after a verified install.

| Command | Example |
|---|---|
| Report state (never launches) | `vidprompt status --json` |
| List scripts | `vidprompt script list` |
| Import, with retry protection | `vidprompt script import ./script.md --request-id take1` |
| Select by id or exact title | `vidprompt script open 'My Script'` |
| Present selection or named script | `vidprompt present 'My Script'` |
| Pause | `vidprompt pause` |
| Resume | `vidprompt resume` |
| Reset reading position | `vidprompt back-to-start` |
| Set tracking | `vidprompt set-mode manual` |
| Set interface zoom | `vidprompt set-zoom 150` |
| MCP tools manifest | `vidprompt mcp-manifest` |
| Complete help | `vidprompt --help` |

Options work before or after command words. `--json` emits one response line; `--show` explicitly brings the library/presenter forward for `script open` or `present`. Other commands launch the app in the background if necessary and wait up to 10 seconds. Exit codes: 0 success, 1 action/connection error, 2 usage error. A bundled helper uses its own bundle identity. `--data-directory /private/tmp/vpc-test` isolates data and preferences (keep the socket path under 104 UTF-8 bytes).

```sh
claude mcp add vidprompt -- node "/Applications/JuniorOS Apps/VidPrompt.app/Contents/Resources/mcp/vidprompt-mcp.mjs"
```

In `~/.codex/config.toml` (use the absolute path from `command -v node` if the host cannot resolve Node):

```toml
[mcp_servers.vidprompt]
command = "node"
args = ["/Applications/JuniorOS Apps/VidPrompt.app/Contents/Resources/mcp/vidprompt-mcp.mjs"]
```

A generic stdio MCP host needs command `node` and the matching bundled shim path as its argument; add `--data-directory /private/tmp/vpc-test` to isolate a test connection. The shim locates its own bundled helper. Host configuration is manual; no setup command is run by the app.

The socket is `control.sock` in the app's data directory: folder 0700, socket 0600, same-user peers only. VidPrompt and disposable data roots remain separate. Creation request IDs are idempotent within one app session. There are no delete, edit or recording actions. Markdown imports link the original both ways, as in the GUI; converted formats stay unlinked. Resuming Voice may request microphone permission if access has not been decided. Token savings have not been measured and are not claimed.
