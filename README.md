# JuniorPrompter source

Native Swift macOS 26 app, version **1.0.0**. Markdown scripts are the source of truth, with a library/editor and a separate floating presenter. Alpha also has camera recording and a Simple inspector toggle. Source has no external package dependencies.

## Build and test

Requires macOS 26+, full Xcode with Swift 6.2+, and its command-line tools. `env.sh` selects the Xcode toolchain and SDK explicitly; Command Line Tools alone cannot build the SwiftUI app. Accept Xcode's licence and finish its first-launch setup before building. MCP additionally requires Node 18+ on PATH; the GUI and CLI do not require Node.

From this `Source/` directory:

```sh
source env.sh
zsh test.sh
zsh mcp/check-mcp.sh
zsh build-alpha.sh
# For the stable channel instead:
zsh build.sh
```

Archives go to `../Outputs/JuniorPrompter Alpha 1.0.0.zip` or `../Outputs/JuniorPrompter 1.0.0.zip`. The Alpha builder refuses to overwrite an existing archive; move it aside before rebuilding. Builds stage outside file-provider folders, sign with hardened runtime and verify both app and helper. The existing local ReadAlong Dev identity is used if available, otherwise ad hoc signing. These are local development archives, not Developer ID signed or notarised releases for other Macs.

Optional overrides: `JUNIORPROMPTER_BUILD_ROOT`, `JUNIORPROMPTER_TEST_SCRATCH` and `JUNIORPROMPTER_OUTPUT_ROOT` select disposable cache/output paths. Use a short, owned path outside Documents, such as `/private/tmp/jp-build`. Never test against a personal library.

## Install and first use

Keep the stable and Alpha channels separate. Install only after the matching app is closed; never overwrite a running bundle. For Alpha, extract and copy with `ditto`:

```sh
work=$(mktemp -d /private/tmp/jp-install.XXXXXX)
ditto -x -k "../Outputs/JuniorPrompter Alpha 1.0.0.zip" "$work"
codesign --verify --deep --strict "$work/JuniorPrompter Alpha.app"
# Check the Alpha bundle id without activating or quitting any app.
source env.sh
if "$SWIFT" -e 'import AppKit; import Darwin; exit(NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.juniornkanabassi.JuniorPrompter.alpha" } ? 1 : 0)'; then
  ditto "$work/JuniorPrompter Alpha.app" "/Applications/JuniorOS Apps/JuniorPrompter Alpha.app"
else
  echo "Alpha is running; leave its installation untouched."
fi
```

Keep the previous archive for rollback and back up the closed app bundle before replacing it. For stable, `zsh install.sh '../Outputs/JuniorPrompter 1.0.0.zip'` is the separate guarded installer; it refuses a running app, verifies the archive and preserves the previous installation on failure. It also links `~/.local/bin/juniorprompter`. Do not use that installer to install Alpha.

Open the installed channel, import a Markdown script and press Present. Choose Voice for on-device speech tracking or Manual for timed scrolling. Allow camera/microphone permissions when using those features. Alpha recording is in the Camera toolbar and uses the pinned preview format, at most 1920×1080; live hardware acceptance remains pending.

## Disposable built-app verification

```sh
work=$(mktemp -d /private/tmp/jp-check.XXXXXX)
ditto -x -k '../Outputs/JuniorPrompter Alpha 1.0.0.zip' "$work"
source env.sh
python3 checks/check-built-app.py "$work/JuniorPrompter Alpha.app"
```

The checker creates its own `--data-directory`, runs the packaged CLI/MCP and reads GUI accessibility state without input or focus changes. The terminal needs Accessibility permission for the GUI assertions; denial is a failed check, not a pass. Only the checker-owned disposable process is terminated. Evidence is retained in the printed temporary folder. `test.sh` separately compiles/runs the XCTest bundle; six external/audio acceptance tests are opt-in and reported as skipped unless configured.

For manual isolated use, launch the app executable with `--data-directory /private/tmp/jp-data`. `--agent-screen` uses an already-connected Agent Screen; `--capture-visible` allows presenter captures for inspection only. Ordinary launches exclude the presenter from capture, but named recording/sharing workflows still need acceptance. OBS integration and iPhone/iCloud editing remain deferred.

## AI control

JuniorPrompter 1.0.0 exposes its existing GUI actions through a private Unix socket, a bundled CLI and an MCP shim. Requires macOS 26; MCP requires Node 18+ and uses protocol 2025-06-18. `install.sh` links `~/.local/bin/juniorprompter` after a verified install.

| Command | Example |
|---|---|
| Report state (never launches) | `juniorprompter status --json` |
| List scripts | `juniorprompter script list` |
| Import, with retry protection | `juniorprompter script import ./script.md --request-id take1` |
| Select by id or exact title | `juniorprompter script open 'My Script'` |
| Present selection or named script | `juniorprompter present 'My Script'` |
| Pause | `juniorprompter pause` |
| Resume | `juniorprompter resume` |
| Reset reading position | `juniorprompter back-to-start` |
| Set tracking | `juniorprompter set-mode manual` |
| Set interface zoom | `juniorprompter set-zoom 150` |
| MCP tools manifest | `juniorprompter mcp-manifest` |
| Complete help | `juniorprompter --help` |

Options work before or after command words. `--json` emits one response line; `--show` explicitly brings the library/presenter forward for `script open` or `present`. Other commands launch the app in the background if necessary and wait up to 10 seconds. Exit codes: 0 success, 1 action/connection error, 2 usage error. `--alpha` chooses Alpha for a development CLI; a bundled helper uses its own bundle identity. `--data-directory /private/tmp/jpc-test` isolates data and preferences (keep the socket path under 104 UTF-8 bytes).

For a separate Alpha command:

```sh
mkdir -p ~/.local/bin
ln -s "/Applications/JuniorOS Apps/JuniorPrompter Alpha.app/Contents/Helpers/juniorprompter" ~/.local/bin/juniorprompter-alpha
# Run the absolute helper path if ~/.local/bin is not on PATH.
juniorprompter-alpha --help
claude mcp add juniorprompter-alpha -- node "/Applications/JuniorOS Apps/JuniorPrompter Alpha.app/Contents/Resources/mcp/juniorprompter-mcp.mjs"
```

In `~/.codex/config.toml` (use the absolute path from `command -v node` if the host cannot resolve Node):

```toml
[mcp_servers.juniorprompter_alpha]
command = "node"
args = ["/Applications/JuniorOS Apps/JuniorPrompter Alpha.app/Contents/Resources/mcp/juniorprompter-mcp.mjs"]
```

For stable MCP, use `JuniorPrompter.app` in place of `JuniorPrompter Alpha.app` and a separate host server name. A generic stdio MCP host needs command `node` and the matching bundled shim path as its argument; add `--data-directory /private/tmp/jpc-test` to isolate a test connection. The shim locates its own channel's bundled helper. Host configuration is manual; no setup command is run by the app.

The socket is `control.sock` in the app's data directory: folder 0700, socket 0600, same-user peers only. Stable, Alpha and disposable data roots remain separate. Creation request IDs are idempotent within one app session. There are no delete, edit or recording actions. Markdown imports link the original both ways, as in the GUI; converted formats stay unlinked. Resuming Voice may request microphone permission if access has not been decided. Token savings have not been measured and are not claimed.
