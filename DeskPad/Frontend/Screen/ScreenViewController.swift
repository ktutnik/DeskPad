import Cocoa
import ReSwift

enum ScreenViewAction: Action {
    case setDisplayID(CGDirectDisplayID)
}

class ScreenViewController: SubscriberViewController<ScreenViewData>, NSWindowDelegate {
    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(didClickOnScreen)))
    }

    private var display: CGVirtualDisplay!
    private var stream: CGDisplayStream?
    private var isWindowHighlighted = false
    private var previousResolution: CGSize?
    private var previousScaleFactor: CGFloat?

    override func viewDidLoad() {
        super.viewDidLoad()

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
            // The asset catalog colors are references to these system colors; fall back
            // to them directly so the highlight still works without a compiled catalog.
            view.window?.backgroundColor = isWindowHighlighted
                ? NSColor(named: "TitleBarActive") ?? .selectedContentBackgroundColor
                : NSColor(named: "TitleBarInactive") ?? .windowBackgroundColor
            // Only raise within the current space: pulling a fullscreen DeskPad forward
            // from another space would drag the user out of whatever they are looking at.
            if isWindowHighlighted, view.window?.isOnActiveSpace == true {
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
            stream = nil
            view.window?.setContentSize(viewData.resolution)
            view.window?.contentAspectRatio = viewData.resolution
            centerOnHostScreen()
            let stream = CGDisplayStream(
                dispatchQueueDisplay: display.displayID,
                outputWidth: Int(viewData.resolution.width * viewData.scaleFactor),
                outputHeight: Int(viewData.resolution.height * viewData.scaleFactor),
                pixelFormat: 1_111_970_369,
                properties: [
                    CGDisplayStream.showCursor: true,
                ] as CFDictionary,
                queue: .main,
                handler: { [weak self] _, _, frameSurface, _ in
                    if let surface = frameSurface {
                        self?.view.layer?.contents = surface
                    }
                }
            )
            self.stream = stream
            stream?.start()
        }
    }

    /// Centers on a real screen rather than the virtual one, so the window never
    /// lands on the display it is mirroring and shows itself recursively.
    private func centerOnHostScreen() {
        guard
            let window = view.window,
            let host = NSScreen.screens.first(where: { $0.displayID != display.displayID })
        else {
            view.window?.center()
            return
        }
        let visibleFrame = host.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        ))
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
        guard let screenResolution = previousResolution else {
            return
        }
        let clickedPoint = gestureRecognizer.location(in: view)
        let onScreenPoint = NSPoint(
            x: clickedPoint.x / view.frame.width * screenResolution.width,
            y: (view.frame.height - clickedPoint.y) / view.frame.height * screenResolution.height
        )
        store.dispatch(MouseLocationAction.requestMove(toPoint: onScreenPoint))
    }
}
