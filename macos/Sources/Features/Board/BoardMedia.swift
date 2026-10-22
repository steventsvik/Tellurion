#if os(macOS)
import AppKit
import AVKit
import UniformTypeIdentifiers

/// A media tile: video or audio files from your Mac playing on the board, one after another
/// (shuffled if you like). It pauses whenever the board's window is hidden.
enum BoardMedia {
    static let size = CGSize(width: 640, height: 400)

    static func isMedia(_ url: URL) -> Bool {
        guard ExtremeSettings.isOn(.media), let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audiovisualContent) || type.conforms(to: .audio) || type.conforms(to: .movie)
    }
}

extension BoardController {
    /// A media tile playing these files, in order.
    @discardableResult
    func addMedia(_ urls: [URL], at point: CGPoint? = nil) -> UUID? {
        let files = urls.filter(BoardMedia.isMedia)
        guard let first = files.first else { return nil }
        let id = addCard(.media, at: point, edit: false)
        updateCard(id) { card in
            card.tabs = files.map(\.path)
            card.tab = 0
            card.title = first.deletingPathExtension().lastPathComponent
        }
        return id
    }

    func chooseMedia(at point: CGPoint? = nil) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audiovisualContent, .audio, .movie]
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.addMedia(panel.urls, at: point)
        }
    }
}

/// The player, with previous, next and shuffle.
final class MediaContent: CardContent {
    private let player = AVPlayer()
    private let view = AVPlayerView()
    private let controls = NSStackView()
    private var files: [String] = []
    private var index = 0
    private var shuffled = false
    private var observers: [NSObjectProtocol] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        addSubview(view)
        controls.orientation = .horizontal
        controls.spacing = 4
        for (symbol, help, action) in [("backward.fill", "Previous", #selector(previous)), ("forward.fill", "Next", #selector(next)),
                                       ("shuffle", "Shuffle", #selector(toggleShuffle))] as [(String, String, Selector)] {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help) ?? NSImage(), target: self, action: action)
            button.isBordered = false
            button.toolTip = help
            button.contentTintColor = .secondaryLabelColor
            controls.addArrangedSubview(button)
        }
        addSubview(controls)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
            self.advance()
        })
        observers.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
            self.advance()
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        player.pause()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in observers.dropFirst(2) { NotificationCenter.default.removeObserver(observer) }
        observers = Array(observers.prefix(2))
        guard let window else {
            player.pause()
            return
        }
        // Hidden windows do no work: pause when the board can't be seen.
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            if !window.occlusionState.contains(.visible) { self?.player.pause() }
        })
    }

    override func viewDidHide() {
        super.viewDidHide()
        player.pause()
    }

    override func apply(_ card: BoardCard) {
        let files = card.tabs ?? []
        guard files != self.files else { return }
        self.files = files
        index = min(card.tab ?? 0, max(files.count - 1, 0))
        load()
    }

    override func layout() {
        super.layout()
        let bar: CGFloat = files.count > 1 ? 26 : 0
        view.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - bar)
        controls.isHidden = bar == 0
        controls.frame = CGRect(x: 8, y: bounds.height - bar, width: bounds.width - 16, height: bar)
    }

    /// The end of a file: the next one, or stop after the last of a single file.
    private func advance() {
        guard files.count > 1 else { return }
        next()
    }

    private func load() {
        guard files.indices.contains(index) else {
            player.replaceCurrentItem(with: nil)
            return
        }
        // A file that's gone: skip it (once round the list at most).
        if !FileManager.default.fileExists(atPath: files[index]) {
            if let other = files.indices.first(where: { FileManager.default.fileExists(atPath: files[$0]) }), other != index {
                index = other
            } else {
                player.replaceCurrentItem(with: nil)
                board?.updateCard(cardID) { $0.title = "File missing" }
                return
            }
        }
        player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: files[index])))
        let title = URL(fileURLWithPath: files[index]).deletingPathExtension().lastPathComponent
        board?.updateCard(cardID) { card in
            card.tab = self.index
            card.title = title
        }
        needsLayout = true
    }

    @objc private func next() {
        guard !files.isEmpty else { return }
        index = shuffled && files.count > 1 ? (index + Int.random(in: 1..<files.count)) % files.count : (index + 1) % files.count
        load()
        player.play()
    }

    @objc private func previous() {
        guard !files.isEmpty else { return }
        index = (index - 1 + files.count) % files.count
        load()
        player.play()
    }

    @objc private func toggleShuffle(_ sender: NSButton) {
        shuffled.toggle()
        sender.contentTintColor = shuffled ? .controlAccentColor : .secondaryLabelColor
    }

    /// For tests: playing, and where.
    var testState: String {
        "playing=\(player.rate > 0) control=\(player.timeControlStatus.rawValue) item=\(player.currentItem?.status.rawValue ?? -1) "
            + "error=\(player.currentItem?.error?.localizedDescription ?? "-") visible=\(window?.occlusionState.contains(.visible) ?? false) "
            + "time=\(String(format: "%.1f", player.currentTime().seconds)) file=\(files.indices.contains(index) ? URL(fileURLWithPath: files[index]).lastPathComponent : "-")"
    }

    func play() { player.play() }
}
#endif
