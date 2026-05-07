#!/usr/bin/env swift
import Cocoa
import AVFoundation
import UniformTypeIdentifiers

let initialURL: URL? = {
    if CommandLine.arguments.count > 1 {
        let path = CommandLine.arguments[1]
        if FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        FileHandle.standardError.write(Data("warning: file not found: \(path) — use Open… to pick one\n".utf8))
        return nil
    }
    if let last = Persistence.load().lastVideoPath,
       FileManager.default.fileExists(atPath: last) {
        return URL(fileURLWithPath: last)
    }
    return nil
}()

func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    guard let num = screen.deviceDescription[key] as? NSNumber else { return nil }
    return CGDirectDisplayID(num.uint32Value)
}

func isBuiltIn(_ screen: NSScreen) -> Bool {
    guard let id = displayID(for: screen) else { return false }
    return CGDisplayIsBuiltin(id) != 0
}

func stableID(for screen: NSScreen) -> String {
    guard let id = displayID(for: screen) else {
        return "name:\(screen.localizedName)"
    }
    let v = CGDisplayVendorNumber(id)
    let m = CGDisplayModelNumber(id)
    let s = CGDisplaySerialNumber(id)
    if v != 0 || m != 0 || s != 0 {
        return "edid:\(v):\(m):\(s)"
    }
    return "name:\(screen.localizedName)"
}

struct PersistedConfig: Codable {
    var displayOrder: [String] = []
    var lastVideoPath: String? = nil
}

enum Persistence {
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("display-wall", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("config.json")
    }
    static var legacyOrderURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("display-wall/order.json")
    }
    static func load() -> PersistedConfig {
        if let data = try? Data(contentsOf: fileURL),
           let cfg = try? JSONDecoder().decode(PersistedConfig.self, from: data) {
            return cfg
        }
        if let data = try? Data(contentsOf: legacyOrderURL),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            return PersistedConfig(displayOrder: arr)
        }
        return PersistedConfig()
    }
    static func save(_ cfg: PersistedConfig) {
        if let data = try? JSONEncoder().encode(cfg) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

let externals = NSScreen.screens.filter { !isBuiltIn($0) }
                                .sorted { $0.frame.origin.x < $1.frame.origin.x }
let builtIn = NSScreen.screens.first(where: isBuiltIn) ?? NSScreen.main!

guard !externals.isEmpty else {
    FileHandle.standardError.write(Data("error: no external displays connected\n".utf8))
    exit(1)
}

func fmt(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00" }
    let i = Int(s)
    return String(format: "%d:%02d", i / 60, i % 60)
}

class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var player: AVQueuePlayer
    var looper: AVPlayerLooper?
    var controlWindow: NSWindow!
    var slider: NSSlider!
    var playPauseButton: NSButton!
    var openButton: NSButton!
    var timeLabel: NSTextField!
    var fileLabel: NSTextField!
    var reorderRow: NSStackView!
    var durationSeconds: Double = 0
    var lastScrubAt: Date = .distantPast
    var timeObserver: Any?

    struct WallEntry { let window: NSWindow; let layer: AVPlayerLayer }
    var displayOrder: [NSScreen] = []
    var wallByScreen: [ObjectIdentifier: WallEntry] = [:]

    let initialURL: URL?

    init(initialURL: URL?) {
        self.player = AVQueuePlayer()
        self.player.isMuted = true
        self.initialURL = initialURL
        super.init()
    }

    func build(externals: [NSScreen], control: NSScreen) {
        displayOrder = restoredOrder(externals: externals)
        for s in externals {
            let entry = makeWall(screen: s)
            wallByScreen[ObjectIdentifier(s)] = entry
        }
        controlWindow = makeControl(screen: control)
        applySliceLayout()
        rebuildReorderRow()
        if let url = initialURL {
            loadVideo(url: url)
        } else {
            updateFileLabel(nil)
        }
    }

    func loadVideo(url: URL) {
        if let t = timeObserver {
            player.removeTimeObserver(t)
            timeObserver = nil
        }
        player.pause()
        player.removeAllItems()

        let asset = AVURLAsset(url: url)
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset))
        for entry in wallByScreen.values {
            entry.layer.player = player
        }

        durationSeconds = 0
        slider?.minValue = 0
        slider?.maxValue = 1
        slider?.doubleValue = 0
        updateTimeLabel(0)
        updateFileLabel(url)

        Task { [weak self] in
            if let dur = try? await asset.load(.duration) {
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.durationSeconds = dur.seconds
                    self.slider?.maxValue = dur.seconds
                    self.updateTimeLabel(0)
                }
            }
        }

        addPeriodicObserver()
        player.play()
        playPauseButton?.title = "Pause"
        persistLastVideo(url)
    }

    @objc func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.message = "Choose a video to play across the display wall"
        panel.prompt = "Open"
        panel.beginSheetModal(for: controlWindow) { [weak self] resp in
            if resp == .OK, let url = panel.url {
                self?.loadVideo(url: url)
            }
        }
    }

    func updateFileLabel(_ url: URL?) {
        if let u = url {
            fileLabel?.stringValue = u.lastPathComponent
            fileLabel?.toolTip = u.path
        } else {
            fileLabel?.stringValue = "No video loaded — click Open…"
            fileLabel?.toolTip = nil
        }
    }

    func restoredOrder(externals: [NSScreen]) -> [NSScreen] {
        let saved = Persistence.load().displayOrder
        let byID = Dictionary(uniqueKeysWithValues: externals.map { (stableID(for: $0), $0) })
        var result: [NSScreen] = []
        var seen = Set<String>()
        for id in saved {
            if let s = byID[id], !seen.contains(id) {
                result.append(s); seen.insert(id)
            }
        }
        for s in externals {
            let id = stableID(for: s)
            if !seen.contains(id) {
                result.append(s); seen.insert(id)
            }
        }
        return result
    }

    func persistOrder() {
        var cfg = Persistence.load()
        cfg.displayOrder = displayOrder.map(stableID(for:))
        Persistence.save(cfg)
    }

    func persistLastVideo(_ url: URL) {
        var cfg = Persistence.load()
        cfg.lastVideoPath = url.path
        Persistence.save(cfg)
    }

    func makeWall(screen: NSScreen) -> WallEntry {
        let frame = screen.frame
        let win = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        win.level = .mainMenu + 1
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.backgroundColor = .black
        win.isOpaque = true
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.setFrame(frame, display: true)

        let host = NSView(frame: NSRect(origin: .zero, size: frame.size))
        host.wantsLayer = true
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        root.frame = host.bounds
        root.masksToBounds = true
        host.layer = root

        let videoLayer = AVPlayerLayer(player: player)
        videoLayer.videoGravity = .resize
        root.addSublayer(videoLayer)

        win.contentView = host
        win.makeKeyAndOrderFront(nil)
        return WallEntry(window: win, layer: videoLayer)
    }

    func applySliceLayout() {
        let total = displayOrder.count
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, screen) in displayOrder.enumerated() {
            guard let entry = wallByScreen[ObjectIdentifier(screen)] else { continue }
            let f = entry.window.frame
            let w = f.size.width
            let h = f.size.height
            entry.layer.frame = CGRect(x: -CGFloat(i) * w, y: 0, width: w * CGFloat(total), height: h)
        }
        CATransaction.commit()
    }

    func rebuildReorderRow() {
        guard let row = reorderRow else { return }
        for v in row.arrangedSubviews {
            row.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for (i, screen) in displayOrder.enumerated() {
            row.addArrangedSubview(makeTile(screen: screen, index: i, total: displayOrder.count))
        }
    }

    func makeTile(screen: NSScreen, index: Int, total: Int) -> NSView {
        let tile = NSView()
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 6
        tile.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        tile.layer?.borderWidth = 1
        tile.layer?.borderColor = NSColor.separatorColor.cgColor
        tile.translatesAutoresizingMaskIntoConstraints = false

        let leftBtn = NSButton(title: "◀", target: self, action: #selector(moveLeft(_:)))
        leftBtn.bezelStyle = .rounded
        leftBtn.tag = index
        leftBtn.isEnabled = index > 0

        let rightBtn = NSButton(title: "▶", target: self, action: #selector(moveRight(_:)))
        rightBtn.bezelStyle = .rounded
        rightBtn.tag = index
        rightBtn.isEnabled = index < total - 1

        let name = NSTextField(labelWithString: "\(index + 1). \(screen.localizedName)")
        name.font = .systemFont(ofSize: 11, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [leftBtn, name, rightBtn])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            tile.heightAnchor.constraint(equalToConstant: 44),
            tile.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        return tile
    }

    @objc func moveLeft(_ sender: NSButton) {
        let i = sender.tag
        guard i > 0, i < displayOrder.count else { return }
        displayOrder.swapAt(i, i - 1)
        applySliceLayout()
        rebuildReorderRow()
        persistOrder()
    }

    @objc func moveRight(_ sender: NSButton) {
        let i = sender.tag
        guard i >= 0, i < displayOrder.count - 1 else { return }
        displayOrder.swapAt(i, i + 1)
        applySliceLayout()
        rebuildReorderRow()
        persistOrder()
    }

    func makeControl(screen: NSScreen) -> NSWindow {
        let size = NSSize(width: 820, height: 230)
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2)
        let win = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false, screen: screen
        )
        win.title = "Display Wall"
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.delegate = self

        let cv = win.contentView!

        // Top row: Open + Pause + slider + time label  (y ~178)
        let topRowY: CGFloat = 178
        let openBtn = NSButton(title: "Open…", target: self, action: #selector(openFile))
        openBtn.bezelStyle = .rounded
        openBtn.keyEquivalent = "o"
        openBtn.keyEquivalentModifierMask = [.command]
        openBtn.frame = NSRect(x: 16, y: topRowY - 16, width: 80, height: 32)
        cv.addSubview(openBtn)
        openButton = openBtn

        let button = NSButton(title: "Pause", target: self, action: #selector(togglePlay))
        button.bezelStyle = .rounded
        button.keyEquivalent = " "
        button.frame = NSRect(x: 104, y: topRowY - 16, width: 90, height: 32)
        cv.addSubview(button)
        playPauseButton = button

        let s = NSSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(didScrub))
        s.isContinuous = true
        s.frame = NSRect(x: 208, y: topRowY - 8, width: size.width - 348, height: 20)
        s.autoresizingMask = [.width]
        cv.addSubview(s)
        slider = s

        let label = NSTextField(labelWithString: "0:00 / 0:00")
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: size.width - 130, y: topRowY - 8, width: 120, height: 20)
        label.autoresizingMask = [.minXMargin]
        label.alignment = .right
        cv.addSubview(label)
        timeLabel = label

        // Filename row, just below the controls
        let fl = NSTextField(labelWithString: "")
        fl.font = .systemFont(ofSize: 11)
        fl.textColor = .secondaryLabelColor
        fl.lineBreakMode = .byTruncatingMiddle
        fl.frame = NSRect(x: 16, y: 138, width: size.width - 32, height: 16)
        fl.autoresizingMask = [.width]
        cv.addSubview(fl)
        fileLabel = fl

        // Section header
        let header = NSTextField(labelWithString: "Display order  (left → right):")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.frame = NSRect(x: 16, y: 110, width: size.width - 32, height: 16)
        header.autoresizingMask = [.width]
        cv.addSubview(header)

        // Reorder row (auto-layout stack inside frame-sized container)
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: cv.topAnchor, constant: size.height - 100),
            row.heightAnchor.constraint(equalToConstant: 50),
        ])
        reorderRow = row

        let hint = NSTextField(labelWithString: "Space: play/pause   ⌘O: open video   ◀ ▶: reorder displays   ⌘Q or Esc: quit")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: 16, y: 14, width: size.width - 32, height: 16)
        hint.autoresizingMask = [.width]
        cv.addSubview(hint)

        win.makeKeyAndOrderFront(nil)
        return win
    }

    func addPeriodicObserver() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            if Date().timeIntervalSince(self.lastScrubAt) > 0.3 {
                self.slider.doubleValue = time.seconds
            }
            self.updateTimeLabel(time.seconds)
        }
    }

    func updateTimeLabel(_ current: Double) {
        timeLabel?.stringValue = "\(fmt(current)) / \(fmt(durationSeconds))"
    }

    @objc func togglePlay() {
        if player.rate == 0 {
            player.play()
            playPauseButton.title = "Pause"
        } else {
            player.pause()
            playPauseButton.title = "Play"
        }
    }

    @objc func didScrub(_ sender: NSSlider) {
        lastScrubAt = Date()
        let t = CMTime(seconds: sender.doubleValue, preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        updateTimeLabel(sender.doubleValue)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == 53 { NSApp.terminate(nil); return nil }
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "q" {
                NSApp.terminate(nil); return nil
            }
            if event.keyCode == 49,
               !(event.window?.firstResponder is NSText) {
                self.togglePlay()
                return nil
            }
            return event
        }
    }
}

let controller = Controller(initialURL: initialURL)
controller.build(externals: externals, control: builtIn)
NSApp.setActivationPolicy(.regular)
NSApp.delegate = controller
NSApp.run()
