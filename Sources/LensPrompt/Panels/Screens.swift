import AppKit
import LensPromptCore

enum Screens {
    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    static func descriptor(_ screen: NSScreen) -> ScreenDescriptor {
        var id = screen.localizedName
        if let did = displayID(screen), let uuid = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue() {
            id = CFUUIDCreateString(nil, uuid) as String
        }
        return ScreenDescriptor(id: id, name: screen.localizedName, frame: screen.frame,
                                visibleFrame: screen.visibleFrame, scale: Double(screen.backingScaleFactor))
    }

    static var all: [ScreenDescriptor] { NSScreen.screens.map(descriptor) }

    static func screen(for descriptor: ScreenDescriptor) -> NSScreen? {
        NSScreen.screens.first { Self.descriptor($0).id == descriptor.id }
    }

    /// Physical width in millimetres when the display reports it.
    static func physicalWidthMM(_ screen: NSScreen) -> CGFloat? {
        guard let did = displayID(screen) else { return nil }
        let size = CGDisplayScreenSize(did)
        return size.width > 0 ? size.width : nil
    }
}
