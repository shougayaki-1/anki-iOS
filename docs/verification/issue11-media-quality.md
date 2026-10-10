# Issue #11 — media fidelity and storage policy

## Current policy (new imports)

- Input: supported still-image formats decoded by ImageIO (iOS 17+), **at most 20,000,000 bytes and 40,000,000 pixels**. Reject missing/incomplete pixel data and multi-frame images; do not trust extensions.
- Uncropped, already-upright JPEG and PNG: **byte-for-byte preserve** source, including PNG alpha, JPEG compression and metadata. No background migration/recompression of existing assets.
- Crops or orientation fixes: normalize upright through UIKit, honoring EXIF axis swaps, then crop in pixel coordinates derived from the normalized bitmap. PNG and alpha-bearing source images remain lossless PNG. Other supported images become JPEG at 0.92 quality.
- Resizing: **no automatic downscaling**. If the result exceeds the existing cap, surface an actionable error asking for user-initiated resizing. This is a deliberate quality-first decision until resizing consent/UI can be designed.
- Storage: unique `images/<UUID>.jpg` or `.png` files, atomic write before SwiftData metadata, SHA-256 of actual stored bytes. On SwiftData save failure, remove the new file. Save failures report disk-space guidance.
- Existing `MediaAsset` fields remain unchanged. `mediaType` now correctly records JPEG or PNG; existing JPEG rows, paths, notes, masks, review logs and editor drafts remain untouched.
- OCR reads original stored bytes; neither text recognition nor masks trigger recompression. Mask rectangles are normalized (0...1), so display-relative geometry remains stable.
- Cleanup retains paths for **every** metadata-backed asset and checks references from notes and drafts before removing rows; both `images` and `restored` directories handle PNG, skip symlinks, and never delete referenced filenames.
- ZIP backup schema stays version 1. JPEG entries remain `media/<UUID>.jpg`; PNG entries are `media/<UUID>.png`. Validation checks declared media type, decoder type, dimensions, hashes and 20 MB cap. Restore writes matching extensions and preserves exact bytes. Old JPEG-only backups remain readable.
- The media format selection is implemented in `ImageEncodingPolicy` without persistence or SwiftUI dependencies, suitable for future #22 ZIP import reuse; #22 remains out of scope.

## Comparison against main (behavioral, not a device benchmark)

| Scenario | Old | New |
|---|---|---|
| Uncropped PNG diagram/screenshot | JPEG 0.9 (lossy, no alpha) | exact original PNG bytes and alpha |
| Uncropped JPEG photo | recompressed JPEG 0.9 | exact original JPEG bytes |
| PNG crop/mask source | JPEG 0.9, alpha lost | lossless PNG crop with preserved alpha |
| JPEG crop / other non-alpha format | JPEG 0.9 | JPEG 0.92 |
| Exceeds 20 MB / 40 Mpixels | reject | reject with clearer instructions |
| Backup | JPEG only | mixed PNG and JPEG, old JPEG supported |

Do **not** interpret byte preservation as a universal storage saving: PNG files can be larger than JPEG. This preserves diagrams and typography rather than silently trading away quality. Pixel quality, size ratios, runtime, OCR success rates and disk-full behavior on real devices have **not been measured**.

## Verification checklist

Added unit tests for JPEG/PNG ZIP entry naming and the encoding policy's limits. Added integration tests for exact JPEG/PNG round-trip; transparent PNG crop; normalized mask geometry; input size; truncated/corrupted file; failed atomic write; draft-referenced PNG retained during cleanup; orphan removed; mixed-format ZIP export/restore; legacy JPEG filenames; and OCR text equality for a stored screenshot. Tests require macOS/Xcode and have not yet been executed.

### Executed

- Source inspection and static review of the changed files / format-path consistency: done.
- Xcode build, unit/integration/UI suite, iOS simulator, performance and actual device measurements: **not executed** (this execution environment has no Xcode, UIKit runtime or iOS simulator).
- Disk-full and interruption/crash injection at filesystem level: **not executed**. An unwritable destination and failed model save are covered by integration test cases, pending execution on macOS.

### Required before marking ready

On macOS, run `xcodebuild test -project AnkiIOS.xcodeproj -scheme AnkiIOS -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO` with an available simulator. Capture representative actual photos, screenshots, text notes and maps, record old/new bytes, dimensions, PNG alpha, OCR correctness, masks before/after crop, duration/memory for import, backup and restore. Check insufficient storage and interrupted restore on device. Keep this PR Draft until measurements and test outcomes are recorded.

## Parallel change boundaries

No edits to `DeckManagerView`, deck hierarchy, statistics, session progress, learning queue, FSRS or review logging. Common-file changes are restricted to `MediaStore`, media metadata initialization, backup encode/decode/validation/restore and orphan cleanup. #40 and #9 should have no direct file overlap; #55 PR #58 touches learning/session code rather than these files. Should any parallel PR start editing backup or media models, rebase and test integration before merging.
