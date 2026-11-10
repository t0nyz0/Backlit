import Foundation

/// Owns at most one item. Removing it does not quit the app or close its window;
/// Dock/Finder reopen and the app's Settings menu remain independent paths.
@MainActor final class MenuBarItemController<Item: AnyObject> {
    private(set) var item: Item?
    @discardableResult func setVisible(_ visible: Bool, create: () -> Item, remove: (Item) -> Void) -> Bool {
        if visible {
            guard item == nil else { return false }
            item = create()
        } else {
            guard let current = item else { return false }
            item = nil
            remove(current)
        }
        return true
    }
}
