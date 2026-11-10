import AppKit

/// Cache the two known controller processes from launch/termination events.
/// Enumerating every application's lazy LaunchServices properties in the
/// animation loop stalls input and is unnecessary work.
final class ControllerMonitor {
    static let shared=ControllerMonitor()
    private let lock=NSLock()
    private var names:[pid_t:String]=[:]
    private var observers:[NSObjectProtocol]=[]
    private init() {
        let center=NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName:NSWorkspace.didLaunchApplicationNotification,object:nil,queue:.main){[weak self] note in
            if let app=note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {self?.add(app)}
        })
        observers.append(center.addObserver(forName:NSWorkspace.didTerminateApplicationNotification,object:nil,queue:.main){[weak self] note in
            guard let self,let app=note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else{return};self.lock.lock();self.names.removeValue(forKey:app.processIdentifier);self.lock.unlock()
        })
        for app in NSWorkspace.shared.runningApplications {add(app)}
    }
    var competingApp:String? {lock.lock();defer{lock.unlock()};return names.sorted{$0.key<$1.key}.first?.value}
    private func add(_ app:NSRunningApplication) {
        let bundle=app.bundleIdentifier?.lowercased() ?? "",name=app.localizedName ?? ""
        guard bundle.contains("backglow") || name.caseInsensitiveCompare("Backglow") == .orderedSame || name.caseInsensitiveCompare("LidPulse") == .orderedSame else{return}
        lock.lock();names[app.processIdentifier]=name.isEmpty ? "another logo controller" : name;lock.unlock()
    }
}
