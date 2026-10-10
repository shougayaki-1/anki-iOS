# Issue #54 — Fixed review actions

## Implementation

- The question, answer, explanations, hint, ordering controls and optional swipe pad continue scrolling in `ReviewView`.
- The reveal and FSRS grading controls live in a separate private `ReviewActionBar` component attached through `safeAreaInset(edge: .bottom)`. They cannot be scrolled out of view; the inset also reserves content space.
- At ordinary Dynamic Type sizes, `ViewThatFits(in: .horizontal)` chooses a four-button row only if labels and 72pt minimum button widths fit. At accessibility text sizes, or when the row cannot fit, the bar uses two rows of two buttons. All buttons retain 56pt minimum height, full VoiceOver labels and explanations, and the existing `grade-1` through `grade-4` identifiers.
- The keyboard can be dismissed interactively by scrolling. Reveal remains in the keyboard-adjusted safe area; opening the answer dismisses the keyboard. The existing four grade values, FSRS logic, Undo, navigation, and `ReviewSwipeGate` are unchanged.
- The no-card completion action remains the sole bottom control for a finished/exhausted session.

## Isolation and merge plan

This change is deliberately stacked on the head of PR #58 (`codex/issue-55-session-progress`) because #58 modifies `ReviewView.swift`, the review progress UI, and `StudyUITests.swift`. **Review and merge PR #58 first**, then retarget this PR to `main` (or verify GitHub's automatic retargeting) and recheck for conflicts. Do not merge #54 before #58.

No `StudyStore`, domain model, persistence, statistics, deck hierarchy, media, App Shortcuts or Xcode project file was changed.

## Verification

Added UI regressions for (1) the permanent bottom controls during content scrolling and Undo, (2) two-column accessibility-size grade layout and readable accessibility labels, and (3) reveal while keyboard is open, keyboard dismissal, and subsequent rating.

Still required on macOS with Xcode: run the iOS build and `StudyUITests`, and manually test 320pt/375pt class layouts, regular/largest text, VoiceOver, light/dark mode, image occlusion, ordering answers, reduced motion, keyboard, swipe pad, card changes and resume. These checks have not been performed in the current environment.
