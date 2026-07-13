import AppKit

class CursorCaptureMonitor {
    private var timer: Timer?
    private var pushAccumulator: CGFloat = 0
    private var displayID: CGDirectDisplayID = 0
    private weak var window: NSWindow?
    private var lastEscapeAt = Date.distantPast

    private static let edgeZone: CGFloat = 5
    private static let pushThreshold: CGFloat = 35
    private static let escapeMargin: CGFloat = 12
    private static let recaptureDelay: TimeInterval = 0.3

    var isActive: Bool {
        return timer != nil
    }

    var canCapture: Bool {
        return !isActive && Date().timeIntervalSince(lastEscapeAt) > Self.recaptureDelay
    }

    func begin(displayID: CGDirectDisplayID, window: NSWindow) {
        end()
        self.displayID = displayID
        self.window = window
        pushAccumulator = 0
        _ = CGGetLastMouseDelta()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func end() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard
            let virtualFrame = NSScreen.screens.first(where: { $0.displayID == displayID })?.frame
        else {
            end()
            return
        }
        let location = NSEvent.mouseLocation
        let delta = CGGetLastMouseDelta()

        if !virtualFrame.insetBy(dx: -1, dy: -1).contains(location) {
            escape(from: location, frame: virtualFrame)
            return
        }

        // delta is y-down, frames are y-up
        var outward: CGFloat = 0
        if location.x <= virtualFrame.minX + Self.edgeZone, delta.x < 0 { outward += CGFloat(-delta.x) }
        if location.x >= virtualFrame.maxX - Self.edgeZone, delta.x > 0 { outward += CGFloat(delta.x) }
        if location.y <= virtualFrame.minY + Self.edgeZone, delta.y > 0 { outward += CGFloat(delta.y) }
        if location.y >= virtualFrame.maxY - Self.edgeZone, delta.y < 0 { outward += CGFloat(-delta.y) }

        if outward > 0 {
            pushAccumulator += outward
            if pushAccumulator > Self.pushThreshold {
                escape(from: location, frame: virtualFrame)
            }
        } else if abs(delta.x) + abs(delta.y) > 0 {
            // decay rather than reset, so hand jitter cannot wipe a steady push
            pushAccumulator /= 2
        }
    }

    private func escape(from exitPoint: NSPoint, frame virtualFrame: NSRect) {
        end()
        lastEscapeAt = Date()
        guard let window = window else {
            return
        }

        let fractionX = max(0, min(1, (exitPoint.x - virtualFrame.minX) / virtualFrame.width))
        let fractionY = max(0, min(1, (exitPoint.y - virtualFrame.minY) / virtualFrame.height))
        let windowFrame = window.frame
        var target = NSPoint(
            x: windowFrame.minX + fractionX * windowFrame.width,
            y: windowFrame.minY + fractionY * windowFrame.height
        )

        let distanceLeft = exitPoint.x - virtualFrame.minX
        let distanceRight = virtualFrame.maxX - exitPoint.x
        let distanceBottom = exitPoint.y - virtualFrame.minY
        let distanceTop = virtualFrame.maxY - exitPoint.y
        switch min(distanceLeft, distanceRight, distanceBottom, distanceTop) {
        case distanceLeft: target.x = windowFrame.minX - Self.escapeMargin
        case distanceRight: target.x = windowFrame.maxX + Self.escapeMargin
        case distanceBottom: target.y = windowFrame.minY - Self.escapeMargin
        default: target.y = windowFrame.maxY + Self.escapeMargin
        }

        CGWarpMouseCursorPosition(cocoaToCG(target))
    }

    private func cocoaToCG(_ point: NSPoint) -> CGPoint {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens[0]
        return CGPoint(x: point.x, y: primary.frame.height - point.y)
    }
}
