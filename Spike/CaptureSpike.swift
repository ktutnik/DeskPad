import AppKit
import CoreGraphics
import ScreenCaptureKit

// MARK: - Coordinate helpers

// Cocoa global (bottom-left origin, y up) <-> CG global (top-left of primary, y down)
func cocoaToCG(_ p: NSPoint) -> CGPoint {
    let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens[0]
    return CGPoint(x: p.x, y: primary.frame.height - p.y)
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as! CGDirectDisplayID
    }
}

func log(_ msg: String) {
    print("[spike] \(msg)")
    fflush(stdout)
}

// MARK: - Main controller

class StreamOutput: NSObject, SCStreamOutput {
    weak var targetView: NSView?

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }
        DispatchQueue.main.async { [weak self] in
            self?.targetView?.layer?.contents = surface
        }
    }
}

class SpikeController: NSObject, NSWindowDelegate {
    var window: NSWindow!
    var display: CGVirtualDisplay!
    var stream: SCStream?
    let streamOutput = StreamOutput()
    let resolution = CGSize(width: 1920, height: 1080)

    var isCaptured = false
    var captureTimer: Timer?
    var pushAccumulator: CGFloat = 0
    var recaptureBlockedUntil = Date.distantPast

    func start() {
        // 1. Virtual display
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "CaptureSpike Display"
        descriptor.maxPixelsWide = 5120
        descriptor.maxPixelsHigh = 2160
        descriptor.sizeInMillimeters = CGSize(width: 1600, height: 1000)
        descriptor.productID = 0x1235
        descriptor.vendorID = 0x3457
        descriptor.serialNum = 0x0002

        display = CGVirtualDisplay(descriptor: descriptor)
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [CGVirtualDisplayMode(width: 1920, height: 1080, refreshRate: 60)]
        let applied = display.apply(settings)
        log("virtual display created id=\(display.displayID) applied=\(applied)")

        // 2. Mirror window (scaled down so it fits comfortably)
        let contentSize = CGSize(width: resolution.width / 2, height: resolution.height / 2)
        let view = NSView(frame: NSRect(origin: .zero, size: contentSize))
        view.wantsLayer = true
        view.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(didClick)))

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CaptureSpike — click inside to capture, push edge to escape"
        window.contentView = view
        window.contentAspectRatio = resolution
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)

        // 3. Whenever display config changes: un-mirror if needed, then stream once extended
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.ensureExtendedThenStream(view: view) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.ensureExtendedThenStream(view: view) }
    }

    var streamStarted = false

    func ensureExtendedThenStream(view: NSView) {
        let id = display.displayID
        guard CGDisplayIsActive(id) != 0 || CGDisplayIsInMirrorSet(id) != 0 else {
            log("display \(id) not active yet")
            return
        }

        // Un-mirror: detach any display mirroring us, and us mirroring anyone
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetOnlineDisplayList(16, &ids, &count)
        let mirrorPeers = ids.prefix(Int(count)).filter {
            CGDisplayMirrorsDisplay($0) == id || ($0 == id && CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay)
        }
        if !mirrorPeers.isEmpty {
            var config: CGDisplayConfigRef?
            CGBeginDisplayConfiguration(&config)
            for peer in mirrorPeers {
                CGConfigureDisplayMirrorOfDisplay(config, peer, kCGNullDirectDisplay)
            }
            // place virtual display to the right of the built-in
            let builtIn = ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
            let anchor = CGDisplayBounds(builtIn)
            CGConfigureDisplayOrigin(config, id, Int32(anchor.maxX), 0)
            let err = CGCompleteDisplayConfiguration(config, .forSession)
            log("un-mirrored peers \(mirrorPeers), origin right of display \(builtIn), err=\(err.rawValue)")
            return // notification will fire again once config settles
        }

        if !streamStarted, CGDisplayIsActive(id) != 0 {
            streamStarted = true
            log("display \(id) active & extended at \(CGDisplayBounds(id)) — starting stream")
            startStream(into: view)
        }
    }

    func startStream(into view: NSView, attempt: Int = 1) {
        streamOutput.targetView = view
        let displayID = display.displayID
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self else { return }
            guard let scDisplay = content?.displays.first(where: { $0.displayID == displayID }) else {
                let seen = content?.displays.map(\.displayID) ?? []
                log("stream attempt \(attempt): SCDisplay \(displayID) not in \(seen) (error=\(String(describing: error)))")
                if attempt < 10 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        self.startStream(into: view, attempt: attempt + 1)
                    }
                }
                return
            }
            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(self.resolution.width)
            config.height = Int(self.resolution.height)
            config.showsCursor = true
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            do {
                try stream.addStreamOutput(self.streamOutput, type: .screen, sampleHandlerQueue: .main)
                stream.startCapture { err in
                    log("stream started, err=\(String(describing: err))")
                }
                self.stream = stream
            } catch {
                log("stream setup failed: \(error)")
            }
        }
    }

    // MARK: Capture

    var virtualScreen: NSScreen? {
        NSScreen.screens.first { $0.displayID == display.displayID }
    }

    @objc func didClick(_ g: NSGestureRecognizer) {
        guard !isCaptured, Date() >= recaptureBlockedUntil, let view = window.contentView else { return }
        let liveSize = virtualScreen?.frame.size ?? resolution
        let p = g.location(in: view)
        let mapped = CGPoint(
            x: p.x / view.frame.width * liveSize.width,
            y: (view.frame.height - p.y) / view.frame.height * liveSize.height // display-local, top-left origin
        )
        enterCapture(at: mapped)
    }

    func enterCapture(at displayPoint: CGPoint) {
        guard virtualScreen != nil else {
            log("capture aborted: virtual NSScreen not found")
            return
        }
        isCaptured = true
        pushAccumulator = 0
        _ = CGGetLastMouseDelta() // drain stale delta
        let err = CGDisplayMoveCursorToPoint(display.displayID, displayPoint)
        log("CAPTURE at display-local \(displayPoint) warp err=\(err.rawValue)")
        window.backgroundColor = .systemBlue

        // Poll at 60Hz: no event delivery needed, no permissions.
        captureTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.pollCapturedCursor()
        }
    }

    func pollCapturedCursor() {
        guard isCaptured, let vFrame = virtualScreen?.frame else { return }
        let loc = NSEvent.mouseLocation // Cocoa global
        let delta = CGGetLastMouseDelta() // y-down, hardware delta since last call
        let dx = delta.x
        let dy = delta.y

        // Case 1: cursor flowed across an arrangement edge onto a neighbor display
        if !vFrame.insetBy(dx: -1, dy: -1).contains(loc) {
            log("escape: crossed arrangement edge at \(loc)")
            escape(from: loc, frame: vFrame)
            return
        }

        // Case 2: pinned against a non-adjacent edge — accumulate outward push deltas.
        // Decay (not reset) on non-outward frames so hand jitter can't wipe a steady push.
        let edgeInset: CGFloat = 5
        var outward: CGFloat = 0
        if loc.x <= vFrame.minX + edgeInset, dx < 0 { outward += CGFloat(-dx) }
        if loc.x >= vFrame.maxX - edgeInset, dx > 0 { outward += CGFloat(dx) }
        if loc.y <= vFrame.minY + edgeInset, dy > 0 { outward += CGFloat(dy) }
        if loc.y >= vFrame.maxY - edgeInset, dy < 0 { outward += CGFloat(-dy) }

        if outward > 0 {
            pushAccumulator += outward
            if pushAccumulator > 35 {
                log("escape: pushed through edge (accumulated \(pushAccumulator))")
                escape(from: loc, frame: vFrame)
            }
        } else if abs(dx) + abs(dy) > 0 {
            pushAccumulator /= 2
        }
    }

    func escape(from exitPoint: NSPoint, frame vFrame: NSRect) {
        isCaptured = false
        recaptureBlockedUntil = Date().addingTimeInterval(0.3)
        captureTimer?.invalidate()
        captureTimer = nil
        window.backgroundColor = .windowBackgroundColor

        // Map exit point fraction onto the window frame, pushed 12px outside the nearest edge
        let fx = max(0, min(1, (exitPoint.x - vFrame.minX) / vFrame.width))
        let fy = max(0, min(1, (exitPoint.y - vFrame.minY) / vFrame.height))
        let wFrame = window.frame // Cocoa global
        var target = NSPoint(x: wFrame.minX + fx * wFrame.width, y: wFrame.minY + fy * wFrame.height)

        let margin: CGFloat = 12
        let dLeft = exitPoint.x - vFrame.minX
        let dRight = vFrame.maxX - exitPoint.x
        let dBottom = exitPoint.y - vFrame.minY
        let dTop = vFrame.maxY - exitPoint.y
        let minD = min(dLeft, dRight, dBottom, dTop)
        if minD == dLeft { target.x = wFrame.minX - margin }
        else if minD == dRight { target.x = wFrame.maxX + margin }
        else if minD == dBottom { target.y = wFrame.minY - margin }
        else { target.y = wFrame.maxY + margin }

        let err = CGWarpMouseCursorPosition(cocoaToCG(target))
        log("ESCAPE -> window-edge point \(target) warp err=\(err.rawValue)")
    }

    func windowWillClose(_: Notification) {
        NSApp.terminate(nil)
    }
}

// MARK: - Bootstrap

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = SpikeController()

class SpikeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        controller.start()
        NSApp.activate(ignoringOtherApps: true)
    }
}

let delegate = SpikeAppDelegate()
app.delegate = delegate
app.run()
