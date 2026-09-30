# JuniorPrompter source

Native Swift macOS 26 development beta. Ordinary Markdown scripts are the source of truth, with a native library/editor and a separate floating presenter.

Run `zsh build.sh` to build, stage outside file-provider folders, sign with the existing local identity and hardened runtime and verify the app. The versioned ZIP is written to `../Outputs/`. Run `zsh install.sh` to install the matching archive in `/Applications/JuniorOS Apps/JuniorPrompter.app`. The guarded installer refuses to replace a running app and preserves the previous installation on failure. Local installation is authorised by the Development workstation instructions.

For disposable testing, launch with `--data-directory /private/tmp/juniorprompter-test-data --agent-screen` after connecting Agent Screen. Both the library and saved preferences are isolated from normal user data. An explicitly injected UserDefaults suite takes precedence in tests. `--capture-visible` disables presenter capture exclusion for visual inspection only; omit it for normal use or capture-exclusion testing.

Run `swift test --scratch-path /private/tmp/JuniorPrompter-primary-tests` for the regression suite. Set `JUNIORPROMPTER_RUN_SPEECH_INTEGRATION=1` to include the paced synthetic bilingual recording through the production on-device provider and session tracker. That test uses the existing research fixture linked in project memory.

The installed 0.1.0 development beta passed 47 tests and native launch/close checks. Current evidence and remaining acceptance are recorded in `../00 Project State/Validation.md` and the project memory. Synthetic speech success does not establish representative live microphone accuracy.

OBS integration and iPhone/iCloud editing are deferred. Native capture exclusion still needs workflow-specific acceptance; do not claim universal invisibility from a window flag. User instructions are in `../Outputs/Getting started.md`.

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
ln -s "/Applications/JuniorOS Apps/JuniorPrompter Alpha.app/Contents/Helpers/juniorprompter" ~/.local/bin/juniorprompter-alpha
claude mcp add juniorprompter -- node "/Applications/JuniorOS Apps/JuniorPrompter.app/Contents/Resources/mcp/juniorprompter-mcp.mjs"
```

In `~/.codex/config.toml` (the installer prints your actual Node path):

```toml
[mcp_servers.juniorprompter]
command = "node"
args = ["/Applications/JuniorOS Apps/JuniorPrompter.app/Contents/Resources/mcp/juniorprompter-mcp.mjs"]
```

The socket is `control.sock` in the app's data directory: folder 0700, socket 0600, same-user peers only. Stable, Alpha and disposable data roots remain separate. Creation request IDs are idempotent within one app session. There are no delete, edit or recording actions. Markdown imports link the original both ways, as in the GUI; converted formats stay unlinked. Resuming Voice requires microphone access already granted in the app. Token savings have not been measured and are not claimed.
