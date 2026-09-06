# JuniorPrompter source

Native Swift macOS 26 development beta. Ordinary Markdown scripts are the source of truth, with a native library/editor and a separate floating presenter.

Run `zsh build.sh` to build, stage outside file-provider folders, ad-hoc sign and verify the app. The versioned ZIP is written to `../Outputs/`. Run `zsh install.sh` to install the matching archive in `/Applications/JuniorPrompter.app`. The guarded installer refuses to replace a running app and preserves the previous installation on failure. Local installation is authorised by the Development workstation instructions.

For disposable testing, launch with `--data-directory /private/tmp/juniorprompter-test-data --agent-screen` after connecting Agent Screen. Both the library and saved preferences are isolated from normal user data. An explicitly injected UserDefaults suite takes precedence in tests. `--capture-visible` disables presenter capture exclusion for visual inspection only; omit it for normal use or capture-exclusion testing.

Run `swift test --scratch-path /private/tmp/JuniorPrompter-primary-tests` for the regression suite. Set `JUNIORPROMPTER_RUN_SPEECH_INTEGRATION=1` to include the paced synthetic bilingual recording through the production on-device provider and session tracker. That test uses the existing research fixture linked in project memory.

The installed 0.1.0 development beta passed 47 tests and native launch/close checks. Current evidence and remaining acceptance are recorded in `../00 Project State/Validation.md` and the project memory. Synthetic speech success does not establish representative live microphone accuracy.

OBS integration and iPhone/iCloud editing are deferred. Native capture exclusion still needs workflow-specific acceptance; do not claim universal invisibility from a window flag. User instructions are in `../Outputs/Getting started.md`.
