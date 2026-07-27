//
//  MouseReportingTests.swift
//
//  The exact bytes written back for a mouse event, in SGR mode (1006).
//
//  These assert escape sequences rather than decoded intent because the format is the whole
//  contract with the program on the other end of the PTY: reporting a hovering pointer as a
//  button release is well-formed, so a client cannot defend against it.
//
#if os(macOS)
import Foundation
import XCTest

@testable import SwiftTerm

final class SwiftTermMouseReporting: XCTestCase {

    /// Captures what the terminal sends upstream.
    private final class Recorder: TerminalDelegate {
        var written: [UInt8] = []

        func send (source: Terminal, data: ArraySlice<UInt8>) {
            written.append (contentsOf: data)
        }

        var text: String { String (decoding: written, as: UTF8.self) }
    }

    /// A terminal in any-event tracking (1003) reporting in SGR (1006).
    private func makeTerminal () -> (Terminal, Recorder) {
        let recorder = Recorder ()
        let terminal = Terminal (delegate: recorder)
        terminal.feed (text: "\u{1b}[?1003h\u{1b}[?1006h")
        XCTAssertEqual (terminal.mouseMode, .anyEvent)
        recorder.written.removeAll ()
        return (terminal, recorder)
    }

    /// What `TerminalView.mouseMoved` encodes for a pointer with no button held.
    private func hoverFlags (_ terminal: Terminal) -> Int {
        terminal.encodeButton (button: 0, release: true, shift: false, meta: false, control: false)
    }

    func testHoverReportsMotionNotRelease ()
    {
        let (terminal, recorder) = makeTerminal ()

        terminal.sendMotion (buttonFlags: hoverFlags (terminal), x: 12, y: 7, pixelX: 0, pixelY: 0)

        // Cb 35 = motion (32) + no button (3), with an uppercase final byte. Deciding release
        // from `Cb & 3 == 3` alone wrote `<32;13;8m` — a left-button release under the pointer.
        XCTAssertEqual (recorder.text, "\u{1b}[<35;13;8M")
    }

    func testDragReportsMotionWithButton ()
    {
        let (terminal, recorder) = makeTerminal ()
        let held = terminal.encodeButton (button: 0, release: false, shift: false, meta: false, control: false)

        terminal.sendMotion (buttonFlags: held, x: 3, y: 4, pixelX: 0, pixelY: 0)

        XCTAssertEqual (recorder.text, "\u{1b}[<32;4;5M")
    }

    func testButtonPressReportsPress ()
    {
        let (terminal, recorder) = makeTerminal ()
        let press = terminal.encodeButton (button: 0, release: false, shift: false, meta: false, control: false)

        terminal.sendEvent (buttonFlags: press, x: 2, y: 5)

        XCTAssertEqual (recorder.text, "\u{1b}[<0;3;6M")
    }

    /// The other direction: a real release must keep its lowercase final byte and its flattened
    /// button bits, or clicking stops working entirely.
    func testButtonReleaseReportsRelease ()
    {
        let (terminal, recorder) = makeTerminal ()
        let release = terminal.encodeButton (button: 0, release: true, shift: false, meta: false, control: false)

        terminal.sendEvent (buttonFlags: release, x: 2, y: 5)

        XCTAssertEqual (recorder.text, "\u{1b}[<0;3;6m")
    }

    /// Modifier bits share the low byte with the button number, so the distinction has to
    /// survive them.
    func testHoverWithModifiersStaysMotion ()
    {
        let (terminal, recorder) = makeTerminal ()
        let flags = terminal.encodeButton (button: 0, release: true, shift: true, meta: false, control: true)

        terminal.sendMotion (buttonFlags: flags, x: 0, y: 0, pixelX: 0, pixelY: 0)

        // 32 motion + 3 no-button + 4 shift + 16 control.
        XCTAssertEqual (recorder.text, "\u{1b}[<55;1;1M")
    }

    static var allTests = [
        ("testHoverReportsMotionNotRelease", testHoverReportsMotionNotRelease),
        ("testDragReportsMotionWithButton", testDragReportsMotionWithButton),
        ("testButtonPressReportsPress", testButtonPressReportsPress),
        ("testButtonReleaseReportsRelease", testButtonReleaseReportsRelease),
        ("testHoverWithModifiersStaysMotion", testHoverWithModifiersStaysMotion),
    ]
}
#endif
