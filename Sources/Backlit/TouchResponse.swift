import AppKit
import IOKit

struct TouchContacts {
    private(set) var active = Set<AnyHashable>()
    mutating func update(identity:AnyHashable,phase:NSTouch.Phase) {
        if phase == .ended || phase == .cancelled { active.remove(identity) }
        else if phase == .began || phase == .moved || phase == .stationary { active.insert(identity) }
    }
    mutating func reset() {active.removeAll()}
}

/// An event-driven native device listener, independent of the frontmost app.
@MainActor final class TouchResponse {
    private var generation=0
    var onClick:(()->Void)?
    var onChange:((Bool,Int)->Void)?
    private(set) var eventCount=0
    static var sources:[TouchSource] {NativeTouchInput.shared.availableSources}
    func start(source:TouchSource)->Bool {
        generation += 1;let current=generation;eventCount=0
        onChange?(false,0)
        return NativeTouchInput.shared.start(source:source){[weak self] count,clicked in
            MainActor.assumeIsolated {
                guard let self,self.generation == current else{return}
                if clicked {self.onClick?()} else {self.eventCount += 1;self.onChange?(count>0,count)}
            }
        }
    }
    func stop(){generation += 1;NativeTouchInput.shared.stop();onChange?(false,0)}
    func reset(){NativeTouchInput.shared.reset();onChange?(false,0)}
}
