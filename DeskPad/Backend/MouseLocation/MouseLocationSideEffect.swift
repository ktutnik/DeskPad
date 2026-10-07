import Foundation
import ReSwift

private var timer: Timer?
private var isObservingActiveSpace = false
/// Last cursor position observed on a real display, in Cocoa screen coordinates.
/// The cursor is sent back here when it would otherwise be stranded.
private var lastHostLocation: NSPoint?

enum MouseLocationAction: Action {
    case located(isWithinScreen: Bool)
    case requestMove(toPoint: NSPoint)
}

func mouseLocationSideEffect() -> SideEffect {
    return { action, dispatch, getState in
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                let mouseLocation = NSEvent.mouseLocation
                let screens = NSScreen.screens
                let screenContainingMouse = (screens.first { NSMouseInRect(mouseLocation, $0.frame, false) })
                let isWithinScreen = screenContainingMouse?.displayID == getState()?.screenConfigurationState.displayID
                if isWithinScreen == false, screenContainingMouse != nil {
                    lastHostLocation = mouseLocation
                }
                dispatch(MouseLocationAction.located(isWithinScreen: isWithinScreen))
                recaptureCursorIfStranded(isWithinScreen: isWithinScreen, displayID: getState()?.screenConfigurationState.displayID)
            }
        }
        if isObservingActiveSpace == false {
            isObservingActiveSpace = true
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { _ in
                // React the moment the mirror's space is switched away, rather than
                // leaving the cursor stranded until the next poll.
                let displayID = getState()?.screenConfigurationState.displayID
                let screenContainingMouse = NSScreen.screens.first {
                    NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
                }
                recaptureCursorIfStranded(
                    isWithinScreen: screenContainingMouse?.displayID == displayID,
                    displayID: displayID
                )
            }
        }
        switch action {
        case let MouseLocationAction.requestMove(point):
            guard let displayID = getState()?.screenConfigurationState.displayID else {
                return
            }
            CGDisplayMoveCursorToPoint(displayID, point)
        default:
            return
        }
    }
}

/// The virtual display has no physical screen behind it, so a cursor sitting on it is
/// only visible through the mirror window. When that window is on another space -
/// typically because a fullscreen DeskPad lost the active space to whatever app raised
/// itself - the cursor appears stuck, so send it back to a display the user can see.
///
/// Windows merely covered on the *active* space are left alone: the highlight handling
/// in `ScreenViewController` already raises the mirror in that case.
private func recaptureCursorIfStranded(isWithinScreen: Bool, displayID: CGDirectDisplayID?) {
    guard
        isWithinScreen,
        let window = mirrorWindow,
        window.isOnActiveSpace == false,
        let target = lastHostLocation ?? defaultHostLocation(virtualDisplayID: displayID)
    else {
        return
    }
    CGWarpMouseCursorPosition(flippedToDisplayCoordinates(target))
    // Warping suppresses mouse input briefly; re-associating clears that immediately.
    CGAssociateMouseAndMouseCursorPosition(1)
}

private var mirrorWindow: NSWindow? {
    return NSApp.windows.first { $0.contentViewController is ScreenViewController }
}

/// Fallback for a cursor that has never been seen off the virtual display.
private func defaultHostLocation(virtualDisplayID: CGDirectDisplayID?) -> NSPoint? {
    guard let host = (NSScreen.screens.first { $0.displayID != virtualDisplayID }) else {
        return nil
    }
    return NSPoint(x: host.visibleFrame.midX, y: host.visibleFrame.midY)
}

/// `NSEvent.mouseLocation` is bottom-left origin, the cursor APIs are top-left origin.
private func flippedToDisplayCoordinates(_ point: NSPoint) -> CGPoint {
    let primaryScreenMaxY = NSScreen.screens.first?.frame.maxY ?? 0
    return CGPoint(x: point.x, y: primaryScreenMaxY - point.y)
}
