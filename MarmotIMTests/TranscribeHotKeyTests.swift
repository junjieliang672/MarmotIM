import XCTest
import Cocoa
@testable import MarmotIM

/// Tests for TranscribeHotKey (right-Command hold via global flagsChanged).
///
/// Everything here is driven by synthesised (keyCode, rawFlags) pairs and an explicit
/// deadline call, so no NSApplication, no real timer and no human thumb is involved.
/// The rawFlags values are the ones the spike actually observed (findings §5 / Q3).
final class TranscribeHotKeyTests: XCTestCase {

    // MARK: - Observed flag values

    /// 0x100000 command + 0x10 right-device bit + 0x100 non-coalesced
    private let rightCommandDownFlags: UInt = 0x100110
    /// 0x100000 command + 0x08 left-device bit + 0x100 non-coalesced
    private let leftCommandDownFlags: UInt = 0x100108
    /// every modifier released
    private let noModifierFlags: UInt = 0x100
    /// right Command still held while Shift goes down
    private let rightCommandPlusShiftFlags: UInt = 0x120112

    private let rightCommand = TranscribeHotKey.rightCommandKeyCode   // 0x36
    private let leftCommand = TranscribeHotKey.leftCommandKeyCode     // 0x37
    private let shiftKeyCode: UInt16 = 0x38

    // MARK: - Fake monitor

    /// Counts install/uninstall so start/stop idempotency and leak-freedom are assertable
    /// without touching AppKit.
    private final class FakeMonitor: TranscribeEventMonitoring {
        var installCount = 0
        var uninstallCount = 0
        var isInstalled = false

        func install(handler: @escaping (UInt16, UInt) -> Void) {
            installCount += 1
            isInstalled = true
        }

        func uninstall() {
            uninstallCount += 1
            isInstalled = false
        }
    }

    // MARK: - Harness

    private final class Harness {
        let monitor = FakeMonitor()
        let hotKey: TranscribeHotKey
        var beginCount = 0
        var endReasons: [TranscribeHoldEndReason] = []

        init(holdMilliseconds: Int = 250) {
            var config = TranscribeConfig.default
            config.holdThresholdMilliseconds = holdMilliseconds
            hotKey = TranscribeHotKey(monitor: monitor, config: { config })
            hotKey.onBegin = { [weak self] in self?.beginCount += 1 }
            hotKey.onEnd = { [weak self] reason in self?.endReasons.append(reason) }
        }
    }

    private func makeHarness(holdMilliseconds: Int = 250) -> Harness {
        Harness(holdMilliseconds: holdMilliseconds)
    }

    // MARK: - Left vs right discrimination

    // 0x36 is the only keyCode that can ever start a hold.
    func testRightCommandDownDecodesAsRightCommandDown() {
        XCTAssertEqual(TranscribeHotKey.signal(keyCode: rightCommand, rawFlags: rightCommandDownFlags),
                       .rightCommandDown)
        XCTAssertEqual(TranscribeHotKey.signal(keyCode: rightCommand, rawFlags: noModifierFlags),
                       .rightCommandUp)
    }

    // Left Command must be provably incapable of starting a recording.
    func testLeftCommandNeverProducesARightCommandSignal() {
        let down = TranscribeHotKey.signal(keyCode: leftCommand, rawFlags: leftCommandDownFlags)
        let up = TranscribeHotKey.signal(keyCode: leftCommand, rawFlags: noModifierFlags)
        XCTAssertNotEqual(down, .rightCommandDown)
        XCTAssertNotEqual(up, .rightCommandDown)

        let harness = makeHarness()
        harness.hotKey.handle(keyCode: leftCommand, rawFlags: leftCommandDownFlags)
        harness.hotKey.handleHoldDeadline()
        harness.hotKey.handle(keyCode: leftCommand, rawFlags: noModifierFlags)
        XCTAssertEqual(harness.beginCount, 0, "left Command must never begin a recording")
        XCTAssertTrue(harness.endReasons.isEmpty)
    }

    // With left Command also held, the right-key release still decodes as an UP —
    // the shared .command bit alone would get this wrong, the device bit does not.
    func testRightReleaseWhileLeftCommandStillHeld() {
        let bothHeld: UInt = 0x100118            // command + both device bits
        let onlyLeftHeld = leftCommandDownFlags  // right device bit cleared
        XCTAssertEqual(TranscribeHotKey.signal(keyCode: rightCommand, rawFlags: bothHeld),
                       .rightCommandDown)
        XCTAssertEqual(TranscribeHotKey.signal(keyCode: rightCommand, rawFlags: onlyLeftHeld),
                       .rightCommandUp)
    }

    // MARK: - Hold threshold

    func testQuickTapProducesNothing() {
        let harness = makeHarness()
        harness.hotKey.handle(keyCode: rightCommand, rawFlags: rightCommandDownFlags)
        harness.hotKey.handle(keyCode: rightCommand, rawFlags: noModifierFlags)
        // the timer would fire after the release; it must be inert by then
        harness.hotKey.handleHoldDeadline()
        XCTAssertEqual(harness.beginCount, 0)
        XCTAssertTrue(harness.endReasons.isEmpty, "no end may fire without a begin")
    }

    func testHoldPastThresholdBeginsAndReleaseEnds() {
        let harness = makeHarness()
        harness.hotKey.handle(keyCode: rightCommand, rawFlags: rightCommandDownFlags)
        harness.hotKey.handleHoldDeadline()
        XCTAssertEqual(harness.beginCount, 1)
        XCTAssertTrue(harness.endReasons.isEmpty)

        harness.hotKey.handle(keyCode: rightCommand, rawFlags: noModifierFlags)
        XCTAssertEqual(harness.endReasons, [.released])
    }

    // The threshold is config-driven, never hard-coded.
    func testHoldThresholdComesFromConfig() {
        XCTAssertEqual(makeHarness().hotKey.holdThreshold, 0.25, accuracy: 0.0001)
        XCTAssertEqual(makeHarness(holdMilliseconds: 600).hotKey.holdThreshold, 0.6, accuracy: 0.0001)
    }

    // MARK: - Abort rule

    // A modifier chord during the pending window cancels the attempt outright:
    // no begin, and therefore no end.
    func testOtherModifierDuringPendingCancelsTheAttempt() {
        let harness = makeHarness()
        harness.hotKey.handle(keyCode: rightCommand, rawFlags: rightCommandDownFlags)
        harness.hotKey.handle(keyCode: shiftKeyCode, rawFlags: rightCommandPlusShiftFlags)
        harness.hotKey.handleHoldDeadline()
        XCTAssertEqual(harness.beginCount, 0, "⌘⇧ chord must not start a recording")
        XCTAssertTrue(harness.endReasons.isEmpty)

        // and the eventual release just returns to idle, silently
        harness.hotKey.handle(keyCode: shiftKeyCode, rawFlags: rightCommandDownFlags)
        harness.hotKey.handle(keyCode: rightCommand, rawFlags: noModifierFlags)
        XCTAssertEqual(harness.beginCount, 0)
        XCTAssertTrue(harness.endReasons.isEmpty)
    }

    // Left Command pressed mid-hold counts as "another modifier" and aborts an
    // already-running recording, so the audio is discarded rather than transcribed.
    func testOtherModifierDuringRecordingAborts() {
        let harness = makeHarness()
        harness.hotKey.handle(keyCode: rightCommand, rawFlags: rightCommandDownFlags)
        harness.hotKey.handleHoldDeadline()
        harness.hotKey.handle(keyCode: leftCommand, rawFlags: 0x100118)
        XCTAssertEqual(harness.beginCount, 1)
        XCTAssertEqual(harness.endReasons, [.aborted])
    }

    // Documented residual of the recorded decision: .flagsChanged cannot see a plain
    // letter, so ⌘C held past the threshold DOES start a recording. It cannot break the
    // shortcut — a passive monitor consumes nothing — it can only produce a near-silent
    // clip, which the downstream minimum-length guard drops. If this ever becomes a real
    // annoyance the fix is a .keyDown monitor, which costs the Accessibility grant.
    func testTypedLetterDuringHoldIsNotObservable() {
        let harness = makeHarness()
        harness.hotKey.handle(keyCode: rightCommand, rawFlags: rightCommandDownFlags)
        // pressing "C" generates no flagsChanged event at all — nothing to feed in
        harness.hotKey.handleHoldDeadline()
        XCTAssertEqual(harness.beginCount, 1, "known and accepted: no event exists to abort on")
        harness.hotKey.handle(keyCode: rightCommand, rawFlags: noModifierFlags)
        XCTAssertEqual(harness.endReasons, [.released])
    }

    // MARK: - No stuck-recording state

    // Losing the release event (focus change, modifier wedge) still ends the recording.
    func testMissedReleaseIsRecoveredFromFlagState() {
        let harness = makeHarness()
        harness.hotKey.handle(keyCode: rightCommand, rawFlags: rightCommandDownFlags)
        harness.hotKey.handleHoldDeadline()
        // next event we see is some other modifier, and Command is already gone
        harness.hotKey.handle(keyCode: shiftKeyCode, rawFlags: 0x20102)
        XCTAssertEqual(harness.endReasons, [.aborted])
    }

    func testStopWhileRecordingEndsTheRecording() {
        let harness = makeHarness()
        harness.hotKey.start()
        harness.hotKey.handle(keyCode: rightCommand, rawFlags: rightCommandDownFlags)
        harness.hotKey.handleHoldDeadline()
        harness.hotKey.stop()
        XCTAssertEqual(harness.endReasons, [.aborted], "teardown must not leave a recording running")
    }

    func testEndNeverFiresWithoutBegin() {
        let harness = makeHarness()
        harness.hotKey.start()
        harness.hotKey.handle(keyCode: rightCommand, rawFlags: rightCommandDownFlags)
        harness.hotKey.stop()   // torn down while still pending
        XCTAssertEqual(harness.beginCount, 0)
        XCTAssertTrue(harness.endReasons.isEmpty)
    }

    // A second DOWN without an intervening UP restarts the attempt instead of wedging.
    func testDownAfterAbortStartsAFreshAttempt() {
        let harness = makeHarness()
        harness.hotKey.handle(keyCode: rightCommand, rawFlags: rightCommandDownFlags)
        harness.hotKey.handle(keyCode: shiftKeyCode, rawFlags: rightCommandPlusShiftFlags)
        harness.hotKey.handle(keyCode: rightCommand, rawFlags: rightCommandDownFlags)
        harness.hotKey.handleHoldDeadline()
        XCTAssertEqual(harness.beginCount, 1)
    }

    // MARK: - Start / stop idempotency

    func testStartAndStopAreIdempotent() {
        let harness = makeHarness()
        harness.hotKey.start()
        harness.hotKey.start()
        XCTAssertTrue(harness.hotKey.isMonitoring)
        XCTAssertEqual(harness.monitor.installCount, 1, "double start must not stack monitors")

        harness.hotKey.stop()
        harness.hotKey.stop()
        XCTAssertFalse(harness.hotKey.isMonitoring)
        XCTAssertEqual(harness.monitor.uninstallCount, 1)
        XCTAssertFalse(harness.monitor.isInstalled)
    }

    func testDeallocUninstallsTheMonitor() {
        let monitor = FakeMonitor()
        do {
            let hotKey = TranscribeHotKey(monitor: monitor, config: { .default })
            hotKey.start()
            XCTAssertTrue(monitor.isInstalled)
        }
        XCTAssertFalse(monitor.isInstalled, "monitor must not outlive the hot key")
    }

    // MARK: - State machine invariants

    // Whatever order the signals arrive in, .begin and .end stay balanced —
    // there is no path that leaves the recorder started.
    func testBeginAndEndStayBalancedUnderArbitrarySignalOrder() {
        let signals: [TranscribeHoldStateMachine.Signal] = [
            .rightCommandDown, .holdDeadline, .otherModifierChanged, .rightCommandUp,
            .teardown, .rightCommandLost, .holdDeadline, .rightCommandDown,
            .rightCommandDown, .teardown, .holdDeadline, .rightCommandUp
        ]
        var machine = TranscribeHoldStateMachine()
        var recording = false
        for signal in signals {
            switch machine.handle(signal) {
            case .begin:
                XCTAssertFalse(recording, "begin while already recording")
                recording = true
            case .end:
                XCTAssertTrue(recording, "end without a begin")
                recording = false
            default:
                break
            }
        }
        XCTAssertEqual(machine.handle(.teardown), .none)
        XCTAssertFalse(recording, "signal sequence left the recorder running")
    }
}
