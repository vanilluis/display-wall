#!/usr/bin/env swift
import Cocoa

let defaultInput = "/Users/kjartan/.euneo-code/worktrees/euneo/feature/dagur-sjukrathjalfunnar/apps/video/out/Master.mp4"
let defaultOutput = "/Users/kjartan/.euneo-code/worktrees/euneo/feature/dagur-sjukrathjalfunnar/apps/video/out/Master_prores.mov"
let ffmpegPath = "/opt/homebrew/bin/ffmpeg"
let totalDuration: Double = 239.445
let sourceFPS: Double = 50

let input = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : defaultInput
let output = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : defaultOutput

let ffmpegArgs: [String] = [
    "-y", "-i", input,
    "-c:v", "prores_videotoolbox", "-profile:v", "2",
    "-c:a", "copy",
    "-progress", "pipe:1", "-nostats",
    output
]

func fmtTime(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "—" }
    let i = Int(s.rounded())
    return String(format: "%d:%02d", i / 60, i % 60)
}
func fmtBytes(_ b: Int64) -> String {
    let f = ByteCountFormatter(); f.countStyle = .file
    return f.string(fromByteCount: b)
}

class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var titleLabel: NSTextField!
    var bar: NSProgressIndicator!
    var statusLabel: NSTextField!
    var detailLabel: NSTextField!
    var actionButton: NSButton!
    var process: Process?
    var startedAt = Date()
    var lastFrame = 0
    var lastFps: Double = 0
    var lastSize: Int64 = 0
    var lastOutTimeMicro: Int64 = 0
    var totalFrames: Int { Int(totalDuration * sourceFPS) }
    var done = false
    var stdoutBuffer = ""

    func applicationDidFinishLaunching(_ note: Notification) {
        buildWindow()
        startProcess()
        NSApp.activate(ignoringOtherApps: true)
    }

    func buildWindow() {
        let size = NSSize(width: 620, height: 210)
        let scr = NSScreen.main!.frame
        window = NSWindow(
            contentRect: NSRect(x: scr.midX - size.width / 2,
                                y: scr.midY - size.height / 2,
                                width: size.width, height: size.height),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Encode to ProRes 422"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let cv = window.contentView!

        let title = NSTextField(labelWithString: "Encoding to ProRes 422")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.frame = NSRect(x: 20, y: 168, width: size.width - 40, height: 22)
        cv.addSubview(title)
        titleLabel = title

        let path = NSTextField(labelWithString: "→ \((output as NSString).lastPathComponent)")
        path.font = .systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        path.frame = NSRect(x: 20, y: 148, width: size.width - 40, height: 16)
        path.lineBreakMode = .byTruncatingMiddle
        cv.addSubview(path)

        let b = NSProgressIndicator(frame: NSRect(x: 20, y: 110, width: size.width - 40, height: 18))
        b.isIndeterminate = false
        b.minValue = 0
        b.maxValue = 1
        b.style = .bar
        cv.addSubview(b)
        bar = b

        let status = NSTextField(labelWithString: "Starting…")
        status.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        status.textColor = .labelColor
        status.frame = NSRect(x: 20, y: 80, width: size.width - 40, height: 20)
        cv.addSubview(status)
        statusLabel = status

        let detail = NSTextField(labelWithString: "")
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .tertiaryLabelColor
        detail.frame = NSRect(x: 20, y: 58, width: size.width - 40, height: 18)
        cv.addSubview(detail)
        detailLabel = detail

        let btn = NSButton(title: "Cancel", target: self, action: #selector(actionTapped))
        btn.bezelStyle = .rounded
        btn.frame = NSRect(x: size.width - 100, y: 14, width: 80, height: 28)
        cv.addSubview(btn)
        actionButton = btn

        window.makeKeyAndOrderFront(nil)
    }

    func startProcess() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpegPath)
        p.arguments = ffmpegArgs
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { return }
            if let s = String(data: d, encoding: .utf8) {
                self?.ingestProgress(s)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { _ in /* discard */ }

        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.finished(code: proc.terminationStatus)
            }
        }

        do {
            try p.run()
            process = p
            startedAt = Date()
        } catch {
            statusLabel.stringValue = "Failed to start ffmpeg: \(error.localizedDescription)"
            actionButton.title = "Close"
        }
    }

    func ingestProgress(_ chunk: String) {
        stdoutBuffer.append(chunk)
        // ffmpeg emits blocks ending with "progress=continue\n" or "progress=end\n"
        var snapshot: [String: String] = [:]
        var lastEnd: String.Index? = nil
        var i = stdoutBuffer.startIndex
        while let lineEnd = stdoutBuffer[i...].firstIndex(of: "\n") {
            let line = stdoutBuffer[i..<lineEnd]
            i = stdoutBuffer.index(after: lineEnd)
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let k = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let v = String(parts[1]).trimmingCharacters(in: .whitespaces)
                snapshot[k] = v
                if k == "progress" {
                    lastEnd = i
                    DispatchQueue.main.async { [weak self, snapshot] in
                        self?.applyProgress(snapshot)
                    }
                    snapshot.removeAll(keepingCapacity: true)
                }
            }
        }
        if let e = lastEnd {
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<e)
        }
    }

    func applyProgress(_ d: [String: String]) {
        if let v = d["frame"].flatMap(Int.init) { lastFrame = v }
        if let v = d["fps"].flatMap(Double.init) { lastFps = v }
        if let v = d["total_size"].flatMap(Int64.init) { lastSize = v }
        if let v = d["out_time_us"].flatMap(Int64.init) { lastOutTimeMicro = v }
        else if let v = d["out_time_ms"].flatMap(Int64.init) { lastOutTimeMicro = v }

        let curSec = Double(lastOutTimeMicro) / 1_000_000.0
        let pct = min(1.0, max(0, curSec / totalDuration))
        bar.doubleValue = pct

        let remainingFrames = max(0, totalFrames - lastFrame)
        let eta = lastFps > 0 ? Double(remainingFrames) / lastFps : -1
        let pctStr = String(format: "%.0f%%", pct * 100)
        let fpsStr = String(format: "%.0f fps", lastFps)
        let etaStr = eta > 0 ? "ETA \(fmtTime(eta))" : "ETA —"
        statusLabel.stringValue = "\(fmtTime(curSec)) / \(fmtTime(totalDuration))   •   \(fpsStr)   •   \(etaStr)   •   \(pctStr)"
        let elapsed = Date().timeIntervalSince(startedAt)
        detailLabel.stringValue = "Output: \(fmtBytes(lastSize))   •   Elapsed: \(fmtTime(elapsed))   •   Frame \(lastFrame) / \(totalFrames)"
    }

    func finished(code: Int32) {
        done = true
        if code == 0 {
            bar.doubleValue = 1
            statusLabel.stringValue = "Done"
            detailLabel.stringValue = "Output: \(fmtBytes(lastSize))   •   Total time: \(fmtTime(Date().timeIntervalSince(startedAt)))"
        } else {
            statusLabel.stringValue = "Failed (exit \(code))"
        }
        actionButton.title = "Close"
    }

    @objc func actionTapped() {
        if !done, let p = process, p.isRunning {
            p.terminate()
        } else {
            NSApp.terminate(nil)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !done, let p = process, p.isRunning { p.terminate() }
        NSApp.terminate(nil)
        return false
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = Controller()
app.delegate = controller
app.run()
