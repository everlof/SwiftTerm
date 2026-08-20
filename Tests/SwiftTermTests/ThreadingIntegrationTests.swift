#if os(macOS)
import AppKit
import Foundation
import XCTest

@testable import SwiftTerm

final class ThreadingIntegrationTests: XCTestCase {
    private let queue = DispatchQueue(label: "SwiftTerm.ThreadingIntegrationTests")

    private func terminal(cols: Int = 80, rows: Int = 24, scrollback: Int = 100) -> Terminal {
        let headless = HeadlessTerminal(
            queue: queue,
            options: TerminalOptions(cols: cols, rows: rows, scrollback: scrollback)
        ) { _ in }
        return headless.terminal
    }

    func testResizeDoesNotMaterializeEmptyScrollbackCapacity() {
        let terminal = terminal(rows: 24, scrollback: 10_000)
        let allocatedBefore = terminal.normalBuffer.lines.getArray().compactMap { $0 }.count

        terminal.resize(cols: 120, rows: 24)

        XCTAssertEqual(terminal.normalBuffer.lines.count, 24)
        XCTAssertEqual(
            terminal.normalBuffer.lines.getArray().compactMap { $0 }.count,
            allocatedBefore
        )
    }

    func testAlternateScreenDefersNormalScrollbackReflowUntilReturn() {
        let terminal = terminal(scrollback: 10_000)
        terminal.feed(text: "normal buffer marker")
        terminal.feed(text: "\u{1b}[?1049h")

        terminal.resize(cols: 120, rows: 40)

        XCTAssertEqual(terminal.altBuffer.cols, 120)
        XCTAssertEqual(terminal.normalBuffer.cols, 80)
        terminal.feed(text: "\u{1b}[?1049l")
        XCTAssertEqual(terminal.normalBuffer.cols, 120)
        XCTAssertTrue(terminal.normalBuffer.lines.getArray().compactMap { $0 }.contains {
            $0.translateToString(trimRight: true).contains("normal buffer marker")
        })
    }

    func testRecentLogicalBufferJoinsWrapsAndPreservesHardBreaks() {
        let terminal = terminal(cols: 12, rows: 8)
        let path = "/tmp/a-very-long-render-name.png"
        terminal.feed(text: path + "\r\nnext")

        let text = terminal.getRecentLogicalBufferText(maximumUTF8Bytes: 4_096)

        XCTAssertTrue(text.contains(path))
        XCTAssertTrue(text.contains("\nnext"))
    }

    func testRecentLogicalBufferOmitsOversizedPartialLine() {
        let terminal = terminal(cols: 8, rows: 6)
        terminal.feed(text: "/tmp/this-logical-line-is-larger-than-the-budget.png")

        let text = terminal.getRecentLogicalBufferText(maximumUTF8Bytes: 16)

        XCTAssertLessThanOrEqual(text.utf8.count, 16)
        XCTAssertFalse(text.contains(".png"))
        XCTAssertFalse(text.contains("budget"))
    }

    func testMouseProtocolAndColorSchemeReportingArePublicContracts() {
        let delegate = CapturingTerminalDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 80, rows: 24))

        terminal.feed(text: "\u{1b}[?1006h\u{1b}[?2031h")
        XCTAssertEqual(terminal.mouseProtocol, .sgr)
        XCTAssertTrue(terminal.colorSchemeReportingEnabled)

        terminal.reportColorSchemeChange(dark: true)
        XCTAssertTrue(delegate.text.contains("\u{1b}[?997;1n"))
    }

    func testClassicWheelReportIsBoundedAndOptionKeepsLocalScrollbackReachable() throws {
        let view = CapturingTerminalView(
            frame: CGRect(origin: .zero, size: CGSize(width: 480, height: 240))
        )
        for line in 0..<200 {
            view.feed(text: "line \(line)\r\n")
        }
        view.feed(text: "\u{1b}[?1003h\u{1b}[?1006h")
        let bottom = view.terminal.displayBuffer.yDisp

        let forwarded = try XCTUnwrap(wheelEvent(modifiers: []))
        view.scrollWheel(with: forwarded)
        XCTAssertFalse(view.sentData.isEmpty)
        XCTAssertEqual(view.terminal.displayBuffer.yDisp, bottom)

        view.sentData.removeAll()
        let local = try XCTUnwrap(wheelEvent(modifiers: [.option]))
        view.scrollWheel(with: local)
        XCTAssertTrue(view.sentData.isEmpty)
        XCTAssertLessThan(view.terminal.displayBuffer.yDisp, bottom)
    }

    func testDiagnosticsAreStructuredAndRateLimited() {
        let events = DiagnosticEvents()
        SwiftTermDiagnostics.installHandler { events.append($0) }
        addTeardownBlock { SwiftTermDiagnostics.removeHandler() }

        SwiftTermDiagnostics.emit(.error, .ptyWriteFailed, facts: ["errno": 5])
        SwiftTermDiagnostics.emit(.error, .ptyWriteFailed, facts: ["errno": 6])
        SwiftTermDiagnostics.emit(.fault, .bufferWidthInvariant, facts: ["expectedColumns": 80])

        XCTAssertEqual(events.snapshot.map(\.code), [.ptyWriteFailed, .bufferWidthInvariant])
        XCTAssertEqual(events.snapshot.first?.facts, ["errno": 5])
    }

    private func wheelEvent(modifiers: NSEvent.ModifierFlags) -> NSEvent? {
        guard let event = CGEvent(scrollWheelEvent2Source: nil,
                                  units: .line,
                                  wheelCount: 1,
                                  wheel1: 1,
                                  wheel2: 0,
                                  wheel3: 0) else { return nil }
        event.flags = CGEventFlags(rawValue: UInt64(modifiers.rawValue))
        return NSEvent(cgEvent: event)
    }
}

private final class CapturingTerminalDelegate: TerminalDelegate {
    var data: [UInt8] = []
    var text: String { String(decoding: data, as: UTF8.self) }

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        self.data.append(contentsOf: data)
    }
}

private final class CapturingTerminalView: TerminalView {
    var sentData: [UInt8] = []

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        sentData.append(contentsOf: data)
    }
}

private final class DiagnosticEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SwiftTermDiagnosticEvent] = []

    func append(_ event: SwiftTermDiagnosticEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var snapshot: [SwiftTermDiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
#endif
