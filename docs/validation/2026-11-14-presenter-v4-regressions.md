# Presenter v4 regression repairs

Base: d384e05. Approved reference: JuniorOS/02 Projects/Development/Video Prompter/Outputs/2026-11-14 Presenter v4 mockup.html.

| Test | Classification and change | Final result |
| --- | --- | --- |
| UIZoomTests.testThePresenterZoomsItsControlsAndLeavesTheScriptAlone | Real layout regression. Measure the zoomed bar, constrain its width, and scroll overflowing controls within at most 55% of content height. Preserve script size, anchor, minimum viewport and bottom-row hit-test assertions. | PASS |
| ReviewFixTests.testRestoredAndCameraMatchedFramesEnforceMinimum | Real layout regression. The same bar reservation fixes restored and camera-matched minimum frames, including title-bar space. No minimum-size or 40% script-height assertion changed. | PASS |
| ReviewFixTests.testActualPresenterKeyDownDoesNotOpenAdjustWhileReading | Old control name. Check Camera remains reachable while reading instead of removed Set up the shot. Keep no-extra-window and notice checks. | PASS |
| PadRemoteReadinessTests.testPresentAndStartRevealScriptForBothLocalAndRemoteActions | Real regression. Restore revealScript() in iPad startReading(), including when the current script was hidden. Existing present/transfer paths and test unchanged. | PASS |
| ReadingBandTests.testReplicaGuidesFollowRemoteState | Old design expectation. Exposure aids now remain visible during reading; retain all remote framing/marker and microphone assertions. | PASS |
| PresenterChromeRound2Tests.testCameraOffLeavesJustTheScriptAndBackOn | Old initial-state expectation. V4 shows script by default. Keep camera off/on and script-visibility assertions. | PASS |
| PresenterChromeRound2Tests.testScriptToggleShowsAndHidesTheScriptInSetup | Old initial-state expectation. Start On, explicitly hide and verify absence, then show and verify presence. | PASS |
| Alpha251Tests.testMicMigrationOpenerAndKeyPersistence | Old opener location. Open script lives inside Script options. Check that menu remains present during reading and absent in Clean. Preserve microphone migration, listening and persisted exposure-key assertions. | PASS |
| AlphaWelcomeWordsTests.testEveryBoldWelcomeControlExistsInUI | Stale welcome copy. Replace Set up the shot with the persistent bar, explain Text, Clean choices, Script visibility and Edit. Test unchanged. | PASS |
| BuilderARoundFifteenTests.testPresenterUsesTheAlphaVocabulary | Stale vocabulary/source scope. Remove Set up the shot, use Text, include shared PresenterControls source where Clean is implemented. | PASS |
| FinalVocabularyTests.testFrozenSectionSevenMatchesOwnedUI | Stale frozen section/source scope. Document v4 and inspect shared controls. Clean's visible and accessibility labels remain Clean. | PASS |
| AppearanceSnapshotTests.testDesignSpecFixtures, testRoundFourteenBuilderA, testRoundSeventeenBuilderA | Old fixture defaults. A blank picture-only Clean fixture must explicitly disable Keep mic meter, now on by default. Preserve strict blank, opaque camera-surface assertions. | PASS, light and dark |

## Validation

- `VIDEOPROMPTER_TEST_SCRATCH=/private/tmp/vp-v4-fixes-test zsh test.sh`: exit 0.
- Unit suite: 1,171 tests, 98 skipped, zero failures.
- Light snapshots: 67 tests, one skipped, zero failures.
- Dark snapshots: 67 tests, one skipped, zero failures.
- Grid: PASS, 119 Swift source files (Mac and iPad).
- iPad: `xcodebuild -project iPad/VideoPrompter.xcodeproj -scheme VideoPrompter -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/vp-v4-ipad-build build CODE_SIGNING_ALLOWED=NO -quiet`: exit 0 (with Xcode DEVELOPER_DIR and inherited SDKROOT unset).
- `git diff --check`: pass.
- Final complete log: `/private/tmp/vp-v4-release-check.log`. iPad build log: `/private/tmp/vp-v4-ipad.log`.

All Mac tests used TestOffscreen. No visible app or simulator, device execution, permission prompts, installation, push or merge. No PNGs committed. At small window sizes the bar can require vertical scrolling; controls retain their size and the setup/reading layout remains identical. Hardware and live VoiceOver were not tested.
