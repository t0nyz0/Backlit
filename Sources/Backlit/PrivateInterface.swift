import Foundation
import ObjectiveC

/// CoreBrightness is private, so its methods are called through function
/// pointers cast to a fixed signature. `responds(to:)` proves only that a
/// method exists; a changed argument or return type would then be undefined
/// behavior. Every casted selector must match its exact type encoding first,
/// so an incompatible macOS version is reported as unsupported instead.
enum PrivateInterface {
    /// `-copyPropertyForKey:` → object
    static let copyProperty = "@24@0:8@16"
    /// `-setProperty:forKey:` → BOOL
    static let setProperty = "B32@0:8@16@24"
    /// `-copyPropertyForKey:keyboardID:` → object
    static let copyKeyboardProperty = "@32@0:8@16Q24"
    /// `-setProperty:withKey:keyboardID:` and `-setProperty:withKey:andDisplay:` → BOOL
    static let setScopedProperty = "B40@0:8@16@24Q32"
    /// `-copyKeyboardBacklightIDs` → object
    static let copyKeyboardIDs = "@16@0:8"

    static func matches(_ object: NSObject, _ selector: Selector, _ encoding: String) -> Bool {
        guard object.responds(to: selector), let cls = object_getClass(object),
              let method = class_getInstanceMethod(cls, selector),
              let actual = method_getTypeEncoding(method) else { return false }
        return String(cString: actual) == encoding
    }
}
