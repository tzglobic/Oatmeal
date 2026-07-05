# Crash: SIGSEGV on button click (macOS 26 + Swift 6.2.x)

## Symptom

The app crashed with `EXC_BAD_ACCESS (SIGSEGV)` the moment any SwiftUI button was
clicked (e.g. the Record button). The faulting stack was entirely in Apple frameworks:

```
lookUpImpOrForward                                  (libobjc)
swift_getObjectType                                 (libswiftCore)
swift_task_isMainExecutorImpl                       (libswift_Concurrency)
SerialExecutorRef::isMainExecutor()
swift_task_isCurrentExecutorWithFlagsImpl
MainActor.assumeIsolated<A>(_:file:line:)           (SwiftUI)
closure #1 … in _ButtonGesture.internalBody.getter  (SwiftUI)
```

## Root cause

The crash is **not in Oatmeal's logic**. SwiftUI wraps every button action in
`MainActor.assumeIsolated`, which asks the Swift concurrency runtime "am I on the
main executor?". On macOS 26 that check dereferences the main thread's
executor-tracking record. If that record has been **corrupted earlier**, the check
reads a garbage pointer (`0x0f00…` in our crash) and segfaults. The button click is
just the first executor check after the corruption — the detonator, not the cause.

The corruption is a **Swift 6.2.x compiler regression** (`OptimizeHopToExecutor`, a
mandatory SIL pass that runs even in debug / language-mode-5 builds). It elides
main-actor executor hops that were actually required, which on macOS 26's stricter
executor-checking path leaves the tracking record dangling. It is fixed in Swift 6.3
(swiftlang/swift#88687). Our machine's Command Line Tools ship Swift 6.2.3, which
carries the bug. This is a recognized macOS 26 crash family — see the still-open
upstream issue swiftlang/swift#89197 and app-level reports (Detto #10, MarkEdit #1281,
ai-service-usage #16), all with this exact stack.

Things that were ruled out:
- Not our recording/audio code — it crashed from the empty meeting list before any
  recording started, and a headless probe showed our startup path does not self-corrupt.
- `SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE=legacy` does **not** help — it only
  suppresses `fatalError`-style aborts, not this identity-dereference SIGSEGV.
- Swift 6 *language mode* is not the issue (and doesn't even compile — the
  KeychainAccess dependency isn't Sendable-clean); the fix is the compiler *version*.

## Fix

1. **Build with Swift 6.3+.** A `swift-6.3.2-RELEASE` toolchain is installed at
   `~/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain`.
   `Scripts/build-app.sh` auto-detects and uses any `swift-6.3*` toolchain there,
   falling back to the system Swift with a warning. This addresses the compiler
   regression directly — the primary fix.
2. **Startup crash diagnostics** (`AppDelegate.swift`): an
   `NSSetUncaughtExceptionHandler` records any swallowed main-thread Objective-C
   exception (the other documented path to this corruption) to
   `~/Library/Application Support/Oatmeal/last-exception.log`, so a recurrence is
   diagnosable instead of invisible.
3. **LaunchServices registration** of the bundle in the build script, so macOS
   treats the ad-hoc build as a real app and does less startup framework thrash.

## Verification status

Verified in this environment: clean compile with 6.3.2, clean launch, no crash on
startup, correct runtime linkage. The click-crash itself could **not** be reproduced
headlessly here — macOS blocks synthetic HID events without Accessibility permission,
and SwiftUI's gesture path can't be faithfully driven from `sendEvent`. Final
confirmation is a manual click test (rebuild, launch, click Record). If it ever
recurs, check `last-exception.log` for the captured throw site.
