# Video Prompter Alpha: Sol round 5 regression review

**1 Important regression. 16 areas remain at 9 or above; 3 affected areas are 8.5.** The normal-size centring, Adjust and Settings changes hold up, but the compact setup column overlaps at 200% in the supplied minimum-size capture.

Reviewer: GPT-6.1 Sol. Reviewed revision `136dfa89583e397e1566b5eeb8748578da6c8c5f`, against round 4 at `2e733083fb35e0c12e497ac069e57a332710cceb`. Read-only source and supplied-image review; no edits, builds, tests, commits or application launches. Only this report and temporary image contact sheets were written.

## Grades

Grades are carried forward from round 4 unless the changed behaviour warrants a reduction. Repeated R1 references describe one defect, not three separate findings.

| Area | /10 | Regression check |
|---|---:|---|
| First launch | 9 | Unchanged. |
| Library | 9 | Unchanged. |
| Editor | 9 | Save/Cancel and enlarged text remain clear in `g1-editing-1000-200.png`. |
| Set up the shot | 8.5 | Centring works in g1 captures; compact setup column overlaps at minimum size, R1. |
| Reading | 9 | Setup-only layout changes preserve the reading surface and compact chip. |
| Clean | 9.5 | Setup column remains excluded; no changed Clean behaviour. |
| Bar and tiles | 9 | No new defect established; pre-existing clipping in the old 720 × 520 fixture is not charged to this diff. |
| Adjust panel | 9 | Five tabs fit one row; Close remains separate and visible at 100/200%. |
| Zebras | 9 | Explicit numeric button backgrounds remain readable; bounds/actions unchanged. |
| False colour and key | 8.5 | Shared bands and numeric controls preserved; compact key label obscured in R1. |
| Skin tone and grey card | 9 | Shared controls retain labels, selection and grey-card workflow. |
| Mic meter | 9 | Shared meter unchanged; normal-size setup captures retain it. |
| Camera and shot | 9 | Shot sheet has one correct heading and the three cards; Advanced has a larger labelled target. |
| Guides | 9 | Advanced sheet now uses shared Guides with named values and existing effective-state actions. |
| Settings | 9 | Done, numeric and Save shoot setup buttons are visible; scrolling retains lower controls. |
| Wording | 9 | No new incorrect or conflicting wording found. |
| Accessibility | 9 | Changed controls retain names/state; numeric targets remain 46 pt, above the 44 pt minimum. No live assistive-technology check. |
| Visual consistency | 9 | Shared buttons/Guides improve consistency; no separate regression beyond R1. |
| Responsiveness | 8.5 | 720 × 520 at 200% now overlaps setup controls, R1. |

## R1: compact exposure key overlaps camera identity

**Important.** Trigger: setup state, 720 × 520 content, interface size 200%, exposure aids on and no camera selected. This is a supported minimum size (`Sources/VideoPrompter/Presenter/PresenterController.swift:463–464`), not merely an arbitrarily tiny fixture.

**Evidence:** `/private/tmp/VideoPrompter-alpha-r5/r13-presenter-key-200-dark.png` shows the Exposure key icon/text drawn behind “No camera chosen”. The corresponding round 4 file under `/private/tmp/VideoPrompter-alpha-r4/` has no such overlap. The round 5 150% counterpart separates the controls, narrowing the failure to the vertically constrained enlarged state. The fixture is defined in `Tests/PrompterCoreTests/BuilderBRoundThirteenTests.swift:121`.

**Source:** `Sources/VideoPrompter/Presenter/PresenterView.swift:83–99` moves the zoomed key before the fixed-height source status inside a height-constrained, non-scrolling VStack. The full-key fit rule at line 78 only selects full versus compact; it does not ensure the compact key plus status can fit. `UIZoom` accepts a compressed proposed height (`App/VideoPrompterApp.swift:332–348`), while its scaled label can still paint beyond that allocation. The result obscures the key's purpose and merges two independent actions visually.

**Exact fix:** Put the setup column's existing VStack inside `ScrollView(.vertical)`, preserve intrinsic vertical sizing for its key and source-status children, and apply the existing fixed gutter width and stage-height constraint to the outer scroll view. Retain key-first order, symmetric gutters and the current full/compact width rule. This allows the combined column to scroll when it cannot fit instead of compressing its zoomed children into each other. Do not shrink text or remove camera identity. Recheck this exact 720 × 520/200% fixture and the g1 1000/1600 × 100/150/200% captures after the fix, including key and status frame non-overlap.

## Scope and verdict

Inspected the complete five-file Sources diff, its connected shared controls and relevant snapshot-test definitions. Visually inspected selected round 5 images via contact sheets/full-size views, covering g1 setup at 100/150/200%, reading/editing, g2 Adjust sections, g4 detail sheets, r3 lower/upper Settings states, h2 rotation and r13 compact setup; compared the disputed r13 200% state directly with round 4. This is sampling of the 1,037 supplied PNGs, not a claim to inspect every capture. Deleted `ExposurePictureLegend` has no remaining production reference.

Normal-size picture centring and key placement pass the supplied-image review. Shared Settings buttons, Shot heading, Camera Advanced target and Guides changes introduce no other demonstrated regression. Existing round 4 polish is not reopened.

**Verdict: fix R1 before claiming all 19 areas remain at 9 or above.** Source/screenshot review completed at the stated HEAD. Builds, automated tests, live camera/microphone, VoiceOver, pointer/keyboard operation and the proposed fix are **NOT RUN**, as required. Screenshots establish rendering, not live hardware behaviour.
