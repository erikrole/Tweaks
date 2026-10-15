import Darwin
import Foundation
import ObjectiveC
import os

/// Finder Sync is loaded only while the settings window is open. The idle app does not link it.
enum FinderExtensionBridge {
    private static let loaded = OSAllocatedUnfairLock(initialState: false)

    static func prepare() -> Bool {
        let firstTime = loaded.withLock { value -> Bool in
            if value { return false }
            value = true
            return true
        }
        if !firstTime { return NSClassFromString("FIFinderSyncController") != nil }
        let path = "/System/Library/Frameworks/FinderSync.framework/FinderSync"
        return dlopen(path, RTLD_LAZY) != nil && NSClassFromString("FIFinderSyncController") != nil
    }

    static func isEnabled() -> Bool? {
        guard prepare(), let cls = NSClassFromString("FIFinderSyncController") else { return nil }
        guard let controller = classObject(cls, "defaultController") else { return nil }
        return instanceBool(controller, "isExtensionEnabled")
    }

    static func showManagement() {
        guard prepare(), let cls = NSClassFromString("FIFinderSyncController") else { return }
        classVoid(cls, "showExtensionManagementInterface")
    }

    private static func classObject(_ cls: AnyClass, _ name: String) -> AnyObject? {
        let sel = NSSelectorFromString(name)
        guard let meta = object_getClass(cls), class_respondsToSelector(meta, sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        let imp = unsafeBitCast(class_getMethodImplementation(meta, sel), to: Fn.self)
        return imp(cls, sel)?.takeUnretainedValue()
    }

    private static func classVoid(_ cls: AnyClass, _ name: String) {
        let sel = NSSelectorFromString(name)
        guard let meta = object_getClass(cls), class_respondsToSelector(meta, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        let imp = unsafeBitCast(class_getMethodImplementation(meta, sel), to: Fn.self)
        imp(cls, sel)
    }

    private static func instanceBool(_ object: AnyObject, _ name: String) -> Bool? {
        let sel = NSSelectorFromString(name)
        guard let cls = object_getClass(object), class_respondsToSelector(cls, sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
        let imp = unsafeBitCast(class_getMethodImplementation(cls, sel), to: Fn.self)
        return imp(object, sel)
    }
}
