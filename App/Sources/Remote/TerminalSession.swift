import Citadel
import NIOCore
import NIOSSH
import Observation
import SwiftTerm
import SwiftUI

/// Receives keystrokes and size changes from the terminal view. A plain class so it can sit between UIKit and async code.
final class TerminalBridge: NSObject, TerminalViewDelegate, @unchecked Sendable {
    var onSend: (@Sendable (ArraySlice<UInt8>) -> Void)?
    var onResize: (@Sendable (Int, Int) -> Void)?
    var onTitle: (@Sendable (String) -> Void)?

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { onResize?(newCols, newRows) }
    func setTerminalTitle(source: TerminalView, title: String) { onTitle?(title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { onSend?(data) }
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) { Task { @MainActor in UIApplication.shared.open(url) } }
    }
    func bell(source: TerminalView) {}
    /// Ignored on purpose: a remote program could otherwise overwrite your clipboard (OSC 52) with a hostile command.
    func clipboardCopy(source: TerminalView, content: Data) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

private final class WriterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _writer: TTYStdinWriter?
    var writer: TTYStdinWriter? { get { lock.withLock { _writer } } set { lock.withLock { _writer = newValue } } }
    /// Keystrokes go through one queue so they reach the shell in the order they were typed.
    let input: AsyncStream<[UInt8]>
    let send: AsyncStream<[UInt8]>.Continuation
    init() { (input, send) = AsyncStream.makeStream(of: [UInt8].self) }
}

/// One interactive SSH shell with a real terminal (colours, vim, tmux, htop).
@MainActor @Observable
final class TerminalSession {
    enum State: Equatable { case connecting, connected, closed(String?) }

    let host: SSHHostSnapshot
    var state: State = .connecting
    var title = ""
    weak var view: TerminalView?
    let bridge = TerminalBridge()
    @ObservationIgnored private let box = WriterBox()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cols = 80
    @ObservationIgnored private var rows = 24

    init(host: SSHHostSnapshot) {
        self.host = host
        bridge.onSend = { [box] data in box.send.yield(Array(data)) }
        Task { [box] in for await bytes in box.input { try? await box.writer?.write(ByteBuffer(bytes: bytes)) } }
        bridge.onResize = { [weak self, box] cols, rows in
            Task { @MainActor in self?.cols = cols; self?.rows = rows }
            Task { try? await box.writer?.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0) }
        }
        bridge.onTitle = { [weak self] title in Task { @MainActor in self?.title = title } }
    }

    func start() {
        guard task == nil else { return }
        state = .connecting
        let host = host, box = box
        let (cols, rows) = (self.cols, self.rows)
        let feed: @Sendable ([UInt8]) -> Void = { [weak self] bytes in Task { @MainActor in self?.view?.feed(byteArray: ArraySlice(bytes)) } }
        task = Task { [weak self] in
            do {
                let client = try await SSHService.connect(host)
                await MainActor.run { self?.state = .connected }
                let request = SSHChannelRequestEvent.PseudoTerminalRequest(wantReply: true, term: "xterm-256color", terminalCharacterWidth: cols,
                                                                           terminalRowHeight: rows, terminalPixelWidth: 0, terminalPixelHeight: 0,
                                                                           terminalModes: SSHTerminalModes([.ECHO: 1]))
                defer { SSHService.closeLater(client) }
                try await client.withPTY(request) { @Sendable inbound, outbound in
                    box.writer = outbound
                    for try await event in inbound {
                        switch event {
                        case .stdout(let buffer), .stderr(let buffer): feed(Array(buffer.readableBytesView))
                        }
                    }
                }
                await MainActor.run { self?.state = .closed(nil) }
            } catch {
                await MainActor.run { self?.state = .closed(error.localizedDescription) }
            }
            box.writer = nil
        }
    }

    func stop() { task?.cancel(); task = nil; box.writer = nil }

    func reconnect() { stop(); view?.feed(text: "\u{1b}c"); start() }

    /// Types text at the prompt without pressing Return, so a person reviews it first.
    func type(_ text: String) {
        box.send.yield(Array(text.utf8))
    }
}

struct TerminalRepresentable: UIViewRepresentable {
    let session: TerminalSession
    let theme: TerminalTheme
    let fontSize: CGFloat

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = session.bridge
        session.view = view
        apply(to: view)
        DispatchQueue.main.async { view.becomeFirstResponder() }
        session.start()
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) { apply(to: view) }

    private func apply(to view: TerminalView) {
        view.nativeBackgroundColor = theme.background
        view.nativeForegroundColor = theme.foreground
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if view.font.pointSize != fontSize { view.font = font }
    }
}
