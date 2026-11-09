# Package E implementation report

Branch: `alpha-redesign/e-shell`.

Implemented setup, reading and Clean states; the 470 pt Adjust panel; full-size wrapping tiles; camera/shot status pills; shared exposure key and microphone meter; right-click and long-press adjustment routes; Escape ordering; exact-word Clean pause; and the two-second Clean exit pill. Preserved the editor save/cancel route and Command-Return shortcut.

Removed the old HUD/sliver controls, Tools section picker and contents, zebraControls, duplicate PresenterMicLevel, old transport/status/output UI, and their obsolete presenter assertions. Shared Camera, Zebra and False colour components are hosted rather than copied. ExposureLegend.swift and CameraGuides.swift were not edited.

## Files changed

- `DESIGN-SPEC.md`
- `Sources/VideoPrompter/Presenter/AdjustPanel.swift`
- `Sources/VideoPrompter/Presenter/PresenterController.swift`
- `Sources/VideoPrompter/Presenter/PresenterShell.swift`
- `Sources/VideoPrompter/Presenter/PresenterView.swift`
- `Tests/PrompterCoreTests/AppearanceSnapshotTests.swift`
- `Tests/PrompterCoreTests/BuilderARoundFifteenTests.swift`
- `Tests/PrompterCoreTests/BuilderARoundSeventeenTests.swift`
- `Tests/PrompterCoreTests/BuilderARoundSixteenTests.swift`
- `Tests/PrompterCoreTests/BuilderARoundThirteenTests.swift`
- `Tests/PrompterCoreTests/BuilderBRoundThirteenTests.swift`
- `Tests/PrompterCoreTests/ExposureOrientationRegressionTests.swift`
- `Tests/PrompterCoreTests/FinalFooterTests.swift`
- `Tests/PrompterCoreTests/Fixtures/presenter-clean.png`
- `Tests/PrompterCoreTests/Fixtures/presenter-zebras.png`
- `Tests/PrompterCoreTests/PresenterBarTests.swift`
- `Tests/PrompterCoreTests/PresenterPopoverContrastTests.swift`
- `Tests/PrompterCoreTests/PresenterShellTests.swift`
- `Tests/PrompterCoreTests/QAFindingsRound7Tests.swift`
- `Tests/PrompterCoreTests/ReferenceMonitorBuildTests.swift`
- `Tests/PrompterCoreTests/ReviewFixTests.swift`
- `Tests/PrompterCoreTests/ReviewTwoTests.swift`
- `Tests/PrompterCoreTests/RoundNineteenTests.swift`
- `Tests/PrompterCoreTests/SimpleInterfaceTests.swift`
- `Tests/PrompterCoreTests/UIZoomTests.swift`

## Visual evidence

See [snapshot notes](README.md). Nine PNGs and their offscreen metadata are in this directory. All nine were opened with the image tool and compared against mockups 01, 02, 03, 05 and 06. The final 200% view retains every tile label; the meter stays at the right edge.

## Validation

The focused PresenterShellTests run passed all four tests, covering Escape ordering, exact-word Clean pause and exit-pill timeout, setup labels at 100/125/150/200%, opener accessibility values, and reading transport. The nine-snapshot package fixture passed. The main acceptance suite completed 831 tests with 72 existing skips and zero failures. The 44 pt reading controls and compact warning retain a usable script viewport at 200%; the dedicated UIZoom regression also passed. The full `zsh test.sh` command exited 0. Both light and dark snapshot suites passed: 41 tests each, one existing skip each, zero failures. The grid check passed across 94 Swift files. No timing-flake rerun was needed on the final run.

Live device capture and native Liquid Glass rendering were not exercised. Tests use the existing invisible-window guard, disposable libraries/preferences, still-image fixtures and no capture permissions.

Validation used `VIDEOPROMPTER_TEST_SCRATCH=/private/tmp/VideoPrompter-test-cache-pkgE` for every build/test. See `test-results.txt` for the final summaries.
