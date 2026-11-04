# Fast-streaming performance

## Cause and fix

The 80 ms coalescer did not own its sleeping task. An immediate flush cleared the
`flushing` boolean without cancelling that task. A subsequent delta scheduled
another task; when the older task woke it cleared the newer task's flag. Repeated
interruptions could leave overlapping timer chains for the rest of the stream.

A second problem made busy sessions trigger this path unnecessarily: every
non-patch message flushed pending text **before** checking its session or computer.
An unrelated session summary therefore copied pending text into `items`, invalidated
the transcript, and bypassed the isolated `LiveText` route.

Evidence in baseline `cf65efd`:

- `apps/Sources/ShedKit/SessionStore.swift:364–365`: unconditional non-patch flush.
- `SessionStore.swift:405–411`: discarded task, 80 ms sleep, and a boolean guard.
- `SessionStore.swift:418–436`: clears that guard, then either publishes `live.texts`
  or copies changes into `items`. It does **not** rebuild `itemIndex` here.
- `apps/Sources/ShedKit/Views/SessionView.swift:68–79`: `items` feeds the equatable
  transcript; changed text makes that value unequal.
- `apps/Sources/ShedKit/Views/TranscriptView.swift:309–314`: a transcript update
  regroups its items and computes the visible block window.

The fix retains one task through an append burst. Forced flushes, replacement
snapshots and session switches cancel it. A cancelled sleeper returns without
clearing another task. This remains a **throttle**, not a debounce: normal deltas
never push its deadline back. The interval remains **80 ms**.

Summary updates now commit pending text only when the selected session's status
changes. A new item commits it only after checking the selected session. Full item
sets, tool state changes, loading older history and the end of a reply still
commit immediately. Snapshots and selection changes discard the old pending data
and cancel its timer. No text is dropped.

## Measurements

Native `swift test -c release`, Apple M1 Max, macOS 26.2, Xcode 27.0. These are
Mac measurements of the shared app code, **not iPhone frame-rate measurements**.
The synthetic busy-session stress sends an unrelated summary after each delta;
it is not a claim that DeepSeek emits a summary per token.

| Workload | Before | After |
| --- | ---: | ---: |
| 200 deltas + 200 unrelated summaries, 1,001 transcript items: whole `items` publications during streaming | 200 | 0 |
| Regrouping caused by those publications (`Activity.blocks`) | 107.1 ms | 0 ms |
| Final committed text | All 200 chunks | Identical |

The 1,000-delta burst regression also interleaves 1,000 unrelated summaries. It
checks that `items` remains unchanged during the burst, that the scheduled flush
publishes all 1,000 chunks through `live.texts`, and that a final idle status commits
the identical text and clears the live cache. The timer regression lets an old
sleeping task become ready while the main actor is occupied, then forces a flush
and starts a new batch. An actual Observation notification must not arrive before
the new 80 ms deadline. This tests cancellation even when the old sleeper has
already resumed, without adding an injectable clock to production code. Against
`cf65efd` (with only `apply` made internal for testing), the old task published the
new batch after **0.795 ms**, failing the required **80 ms** lower bound. The
summary/burst regressions also fail against that baseline.

Additional temporary release benchmarks informed what **not** to change:

- 100 append updates to a 269,190-byte reply with 301 blocks: full block equality
  plus the changed-block walk took **0.186 ms total** (1.86 µs/update). The incremental
  splitter reuses historical blocks' String storage; equality is not a whole-reply
  byte comparison on this path.
- Splitting 100 growing 20.6 KB tails: **401 ms** with one block versus **411 ms**
  with a 269 KB reply. The growing tail, not total history, is the principal cost.
- Foundation inline parsing for the fade tracker: **1,308 ms / 100 updates** of a
  20.6 KB block. MarkdownUI parse + plain-text rendering: **90 ms / 100 updates**.
- Simulated 80 ms arrivals, 100 historical paragraphs, 100 growing updates:
  a roughly 1 KB tail had splitter+fade median **1.11 ms**, p95 **1.46 ms**;
  a pathological single 20 KB tail had median **17.43 ms**, p95 **18.23 ms**.
- Native `NSHostingView` layout at 360 pt, 40 updates: **531 ms** with one 1 KB
  paragraph versus **740 ms** with 30 paragraphs and only the last growing.
  This exercises Mac layout at phone width, not UIKit or phone hardware.

Print-only benchmarks were temporary and are not CI tests. Their sources and raw
logs remain in this working clone under ignored `apps/.build/perf/`. The committed
regressions exercise the actual store; no separate mock coalescer is used.

## Validation

- `cd apps && swift build`
- `cd apps && swift test -c release`
- `cd apps/iOS && xcodebuild -project Shed.xcodeproj -scheme Shed -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath ../build/perf-ios CODE_SIGNING_ALLOWED=NO build`

The iPhone target compiles successfully without signing. No available iOS Simulator
runtime was installed, and no phone run or frame-rate claim is made. Existing
Swift 6 isolation and iOS orientation warnings are unrelated and unchanged.

`SessionStore.apply` is now internal rather than private so `@testable` tests can
drive the real incoming-message path. It is not public API. A SwiftPM test target
was added; no dependencies were added.

## Deliberately unchanged

- **Splitter and fade parser.** They already work on changed blocks, and realistic
  tails are inexpensive at the restored cadence. The large-paragraph timings are
  not evidence of dropped iPhone frames. Incremental suffix parsing or raw-text
  approximations could change Markdown/fade behaviour and are outside this fix.
- **MarkdownUI and syntax highlighting.** `StreamingMarkdown.swift:110–117` wraps
  each Markdown block in an equatable view. Unchanged blocks are not reparsed for
  every delta. Prose does not call `Syntax.highlight`.
- **LiveText dictionary.** Observation is dictionary-property-wide, but
  `StreamingMarkdown.swift:23–25` reads it only for the streaming reply, and
  `TranscriptView.swift:338–349` marks only the last busy block as streaming.
  There is no current all-history reader fanout to fix.
- **Bridge rate and protocol.** `bridge/src/session.rs:426–445,1394–1396` forwards
  each transcript change immediately. `bridge/src/transcript.rs:339–367` sends
  append deltas, not the entire reply per token. In DeepSeek, job summaries arise
  from lifecycle events (`bridge/src/dsh.rs:849–854`), not text deltas. Transport
  batching, decoding and String ownership are separate concerns.
- **Media/files and transcript layout.** Media requests are keyed tasks and images
  use the session cache; there is no evidence that they refetch on each text delta.
  Stable block identity, existing equatable boundaries and history windowing stay
  as they are.

No rendering constants or user-visible formatting changed. The performance claim
is reduced invalidation and a bounded shared-store update cadence. How much this
improves scrolling/typing on a particular iPhone still needs a device run.
