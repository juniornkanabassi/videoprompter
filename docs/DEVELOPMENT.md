# Developing Video Prompter

This is the technical reference for building Video Prompter from source, checking a build and controlling the app from scripts and AI tools. The public overview is in the [README](../README.md).

Video Prompter is a native Swift app for macOS 26. Markdown scripts are the source of truth, with a library/editor and a separate floating presenter. The source has no external package dependencies.

## Build and test

Requires macOS 26 or later, full Xcode with Swift 6.2 or later, and its command-line tools. `env.sh` selects the Xcode toolchain and SDK explicitly; the Command Line Tools alone cannot build the SwiftUI app. Accept Xcode's licence and finish its first-launch setup before building. MCP also needs Node 18 or later on PATH; the app and CLI do not need Node.

From the repository root (on my Mac, the `Source/` folder):

```sh
source env.sh
zsh test.sh
zsh mcp/check-mcp.sh
zsh build.sh
```

The build produces `../Outputs/Video Prompter <version>.zip`. Builds are staged outside file-provider folders, signed with the hardened runtime, and both the app and its helper are verified. With the Developer ID certificate in the keychain, `build.sh` signs with it (hardened runtime, secure timestamp), submits the app to Apple's notary service through the `JuniorOS` keychain profile, staples the ticket and checks the result with `spctl`. Set `VIDEOPROMPTER_LOCAL_SIGNING=1` for a quick local build signed with my optional local signing identity (ReadAlong Dev) if present, otherwise ad hoc, and not notarised.

To make a download disk image from an app bundle that has already been verified, run `checks/package-dmg.sh "/path/to/Video Prompter.app" /path/to/output-folder`. It stages in `/private/tmp`, adds the standard Applications shortcut and the install note, and reports the bundle's minimum macOS version and executable architectures. It requires arm64 in both the app and the CLI helper. It writes `Video Prompter <version>.dmg` and refuses to replace an existing DMG; a release upload must be named `VideoPrompter.dmg`. For a Developer ID build it also signs, notarises and staples the disk image.

Optional overrides: `VIDEOPROMPTER_BUILD_ROOT`, `VIDEOPROMPTER_TEST_SCRATCH` and `VIDEOPROMPTER_OUTPUT_ROOT` choose disposable cache and output paths. Use a short path you own outside Documents, such as `/private/tmp/vp-build`. Never test against a personal library.

## Install from source

From a source checkout, install with `zsh install.sh`. The guarded installer refuses to run while the app is open, verifies the archive and keeps the previous installation if anything fails. It also links `~/.local/bin/videoprompter`. Keep the previous archive so you can roll back.

A drag-installed app does not need this source tree, Xcode or `install.sh`. It includes the CLI at `Contents/Helpers/videoprompter` and the MCP adapter at `Contents/Resources/mcp/videoprompter-mcp.mjs`, but does not create a PATH link or configure an AI host.

App details: bundle ID `com.juniornkanabassi.VidPrompt` (kept from the earlier name so permissions and settings survive), data folder `~/Library/Application Support/Video Prompter`, default recordings folder `~/Movies/Video Prompter`.

## Checking a built app in a disposable location

```sh
work=$(mktemp -d /private/tmp/vp-check.XXXXXX)
ditto -x -k '../Outputs/Video Prompter <version>.zip' "$work"
source env.sh
python3 checks/check-built-app.py "$work/Video Prompter.app"
```

The checker creates its own `--data-directory`, runs the packaged CLI and MCP, and reads the app's accessibility state without sending input or changing focus. The terminal needs Accessibility permission for the GUI checks; if it is denied, the check fails rather than passes. Only the checker's own disposable process is stopped. Evidence is kept in the temporary folder it prints. `test.sh` separately builds and runs the XCTest bundle; six external and audio acceptance tests are opt-in and reported as skipped unless configured.

For a manual test with disposable data, launch the app executable with `--data-directory /private/tmp/vp-data`. This flag alone does not isolate all window restoration; use the packaged checker for its stronger disposable-home setup. `--agent-screen` uses an already-connected Agent Screen. `--capture-visible` lets the presenter be captured, for inspection only.

## Command line and AI control

Video Prompter exposes its existing app actions through a private Unix socket, a bundled CLI and an MCP shim. It requires macOS 26; MCP requires Node 18 or later and uses protocol version 2025-06-18. The source installer links `~/.local/bin/videoprompter` after a verified local install. A downloaded app does not create that link.

For a standard drag installation, set the real app path and use the bundled helper directly:

```sh
VIDEOPROMPTER_APP="/Applications/Video Prompter.app"
"$VIDEOPROMPTER_APP/Contents/Helpers/videoprompter" --help
"$VIDEOPROMPTER_APP/Contents/Helpers/videoprompter" status --json
```

The short `videoprompter` examples below assume the optional command link exists and `~/.local/bin` is on PATH. Otherwise, replace `videoprompter` with the full helper path. These CLI commands do not need Node.

| Command | Example |
|---|---|
| Report state (never launches) | `videoprompter status --json` |
| List scripts | `videoprompter script list` |
| Import, with retry protection | `videoprompter script import ./script.md --request-id take1` |
| Select by ID or exact title | `videoprompter script open 'My Script'` |
| Present the selection or a named script | `videoprompter present 'My Script'` |
| Pause | `videoprompter pause` |
| Resume | `videoprompter resume` |
| Reset reading position | `videoprompter back-to-start` |
| Set tracking (`voice` or `manual`) | `videoprompter set-mode manual` |
| Set interface zoom (100, 110, 125, 150, 175 or 200) | `videoprompter set-zoom 150` |
| MCP tools manifest | `videoprompter mcp-manifest` |
| Full help | `videoprompter --help` |

Options can go before or after the command words. `--json` prints one response line. `--show` brings the library or presenter forward, and only works with `script open` or `present`. Other commands launch the app in the background if needed and wait up to 10 seconds. Exit codes: 0 success, 1 action or connection error, 2 usage error. A bundled helper uses its own app's identity. `--data-directory /private/tmp/vpc-test` isolates app data and preferences (keep the socket path under 104 UTF-8 bytes). On its own it does not isolate the whole account or window restoration; the packaged checker also uses an isolated home folder and restoration arguments.

Claude Code:

```sh
claude mcp add videoprompter -- node "/Applications/Video Prompter.app/Contents/Resources/mcp/videoprompter-mcp.mjs"
```

Codex, in `~/.codex/config.toml` (use the absolute path from `command -v node` if the host cannot find Node):

```toml
[mcp_servers.videoprompter]
command = "node"
args = ["/Applications/Video Prompter.app/Contents/Resources/mcp/videoprompter-mcp.mjs"]
```

Change these example paths to match where you installed the app. Any other stdio MCP host needs the command `node` with the matching bundled shim path as its argument; add `--data-directory /private/tmp/vpc-test` to isolate a test connection. The shim finds its own bundled helper. You set up the host yourself; the app does not run any setup command.

The socket is `control.sock` in the app's data folder: folder permissions 0700, socket 0600, and only processes from the same user can connect. Video Prompter data and disposable test data stay separate. Creation request IDs are idempotent within one app session. There are no delete, edit or recording actions. Markdown imports are linked to the original both ways, as in the app; converted formats are not linked. Resuming Voice may ask for microphone permission if access has not been decided yet. Token savings have not been measured and are not claimed.

## Release status

Release builds are Developer ID signed, notarised and stapled, and so is the disk image. Gatekeeper acceptance is checked with `spctl` on the build Mac; the full install and removal workflow for a new user on another Mac remains unverified. Sparkle, a signed appcast and a one-command publish pipeline are not shipped yet, so updates are manual.

If notarisation times out, the build retains its staged bundle or disk image and submission log in the printed temporary folder. Use the printed submission ID with `xcrun notarytool info` and the printed staple, verification and archive commands after Apple reports Accepted. Do not resubmit the same pending upload.
