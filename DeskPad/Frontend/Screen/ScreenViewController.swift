import Cocoa
import ReSwift
import ScreenCaptureKit

enum ScreenViewAction: Action {
    case setDisplayID(CGDirectDisplayID)
}

private class MirrorStreamOutput: NSObject, SCStreamOutput {
    weak var targetView: NSView?

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard
            type == .screen,
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
            let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.targetView?.layer?.contents = surface
        }
    }
}

class ScreenViewController: SubscriberViewController<ScreenViewData>, NSWindowDelegate {
    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(didClickOnScreen)))
    }

    private var display: CGVirtualDisplay!
    private var stream: SCStream?
    private let streamOutput = MirrorStreamOutput()
    private let captureMonitor = CursorCaptureMonitor()
    private var isWindowHighlighted = false
    private var previousResolution: CGSize?
    private var previousScaleFactor: CGFloat?

    override func viewDidLoad() {
        super.viewDidLoad()

        streamOutput.targetView = view

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "DeskPad Display"
        descriptor.maxPixelsWide = 5120
        descriptor.maxPixelsHigh = 2160
        descriptor.sizeInMillimeters = CGSize(width: 1600, height: 1000)
        descriptor.productID = 0x1234
        descriptor.vendorID = 0x3456
        descriptor.serialNum = 0x0001

        let display = CGVirtualDisplay(descriptor: descriptor)
        store.dispatch(ScreenViewAction.setDisplayID(display.displayID))
        self.display = display

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [
            // 32:9
            CGVirtualDisplayMode(width: 5120, height: 1440, refreshRate: 60),
            // 21:9 (239:100, 12:5)
            CGVirtualDisplayMode(width: 5120, height: 2160, refreshRate: 60),
            CGVirtualDisplayMode(width: 3840, height: 1600, refreshRate: 60),
            CGVirtualDisplayMode(width: 3440, height: 1440, refreshRate: 60),
            // 16:9
            CGVirtualDisplayMode(width: 3840, height: 2160, refreshRate: 60),
            CGVirtualDisplayMode(width: 2560, height: 1440, refreshRate: 60),
            CGVirtualDisplayMode(width: 1920, height: 1080, refreshRate: 60),
            CGVirtualDisplayMode(width: 1600, height: 900, refreshRate: 60),
            CGVirtualDisplayMode(width: 1366, height: 768, refreshRate: 60),
            CGVirtualDisplayMode(width: 1280, height: 720, refreshRate: 60),
            // 16:10
            CGVirtualDisplayMode(width: 2560, height: 1600, refreshRate: 60),
            CGVirtualDisplayMode(width: 1920, height: 1200, refreshRate: 60),
            CGVirtualDisplayMode(width: 1680, height: 1050, refreshRate: 60),
            CGVirtualDisplayMode(width: 1440, height: 900, refreshRate: 60),
            CGVirtualDisplayMode(width: 1280, height: 800, refreshRate: 60),
        ]
        display.apply(settings)
    }

    override func update(with viewData: ScreenViewData) {
        if viewData.isWindowHighlighted != isWindowHighlighted {
            isWindowHighlighted = viewData.isWindowHighlighted
            view.window?.backgroundColor = isWindowHighlighted
                ? NSColor(named: "TitleBarActive")
                : NSColor(named: "TitleBarInactive")
            if isWindowHighlighted {
                view.window?.orderFrontRegardless()
            }
        }

        if
            viewData.resolution != .zero,
            viewData.resolution != previousResolution
            || viewData.scaleFactor != previousScaleFactor
        {
            previousResolution = viewData.resolution
            previousScaleFactor = viewData.scaleFactor
            captureMonitor.end()
            stream?.stopCapture(completionHandler: nil)
            stream = nil
            view.window?.setContentSize(viewData.resolution)
            view.window?.contentAspectRatio = viewData.resolution
            view.window?.center()
            startStream(resolution: viewData.resolution, scaleFactor: viewData.scaleFactor)
        }
    }

    private func startStream(resolution: CGSize, scaleFactor: CGFloat, attempt: Int = 1) {
        let displayID = display.displayID
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, _ in
            DispatchQueue.main.async {
                guard let self = self else {
                    return
                }
                guard
                    resolution == self.previousResolution,
                    scaleFactor == self.previousScaleFactor
                else {
                    return // configuration changed while we were fetching
                }
                guard let scDisplay = content?.displays.first(where: { $0.displayID == displayID }) else {
                    // virtual display may not be listed yet right after (re)configuration
                    if attempt < 5 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            self.startStream(resolution: resolution, scaleFactor: scaleFactor, attempt: attempt + 1)
                        }
                    }
                    return
                }
                let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.width = Int(resolution.width * scaleFactor)
                configuration.height = Int(resolution.height * scaleFactor)
                configuration.showsCursor = true
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
                do {
                    try stream.addStreamOutput(self.streamOutput, type: .screen, sampleHandlerQueue: .main)
                    stream.startCapture(completionHandler: nil)
                    self.stream = stream
                } catch {
                    return
                }
            }
        }
    }

    func windowWillResize(_ window: NSWindow, to frameSize: NSSize) -> NSSize {
        let snappingOffset: CGFloat = 30
        let contentSize = window.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        guard
            let screenResolution = previousResolution,
            abs(contentSize.width - screenResolution.width) < snappingOffset
        else {
            return frameSize
        }
        return window.frameRect(forContentRect: NSRect(origin: .zero, size: screenResolution)).size
    }

    @objc private func didClickOnScreen(_ gestureRecognizer: NSGestureRecognizer) {
        guard
            let screenResolution = previousResolution,
            let window = view.window,
            captureMonitor.canCapture
        else {
            return
        }
        let clickedPoint = gestureRecognizer.location(in: view)
        let onScreenPoint = NSPoint(
            x: clickedPoint.x / view.frame.width * screenResolution.width,
            y: (view.frame.height - clickedPoint.y) / view.frame.height * screenResolution.height
        )
        store.dispatch(MouseLocationAction.requestMove(toPoint: onScreenPoint))
        captureMonitor.begin(displayID: display.displayID, window: window)
    }
}
