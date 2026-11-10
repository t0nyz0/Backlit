import Foundation
import IOKit

/// Interoperability declarations for the installed MultitouchSupport framework.
/// Only device usage and path/state scalars are inspected. Touch buffers (which
/// contain positions) are deliberately never dereferenced or retained.
enum TouchSource:String,CaseIterable,Identifiable {
    case screen,trackpad,both
    var id:String {rawValue}
    var title:String {switch self {case .screen:return "Screen";case .trackpad:return "Trackpad";case .both:return "Both"}}
    func includes(_ other:TouchSource)->Bool {self == .both || self == other}
}
struct NativeContactLedger {
    private(set) var active:[UInt:Set<Int>]=[:]
    var count:Int {active.values.reduce(0){$0+$1.count}}
    mutating func update(device:UInt,path:Int,state:Int) {
        if state == 3 || state == 4 {active[device,default:[]].insert(path)}
        else {active[device]?.remove(path)}
    }
    mutating func reset(){active.removeAll()}
}

final class NativeTouchInput {
    // Framework callbacks are process-global; this object has process lifetime.
    static let shared=NativeTouchInput()
    typealias PathCallback = @convention(c) (UnsafeRawPointer?,Int,Int,UnsafeRawPointer?)->Void
    typealias ButtonCallback = @convention(c) (UnsafeRawPointer?,UInt32,UInt32,UnsafeRawPointer?)->Void
    typealias RegisterButton = @convention(c) (UnsafeRawPointer,ButtonCallback,UnsafeRawPointer?)->Bool
    typealias UnregisterButton = @convention(c) (UnsafeRawPointer,ButtonCallback)->Bool
    typealias List = @convention(c) ()->Unmanaged<CFArray>?
    typealias Service = @convention(c) (UnsafeRawPointer)->io_service_t
    typealias Register = @convention(c) (UnsafeRawPointer,PathCallback)->Void
    typealias Start = @convention(c) (UnsafeRawPointer,Int32)->Int32
    typealias Stop = @convention(c) (UnsafeRawPointer)->Int32
    private struct Device {let pointer:UnsafeRawPointer;let source:TouchSource}
    private var retainedDevices:CFArray?
    private var devices:[Device]=[]
    private var running:[Device]=[]
    private var register:Register?
    private var unregister:Register?
    private var registerButton:RegisterButton?
    private var unregisterButton:UnregisterButton?
    private var begin:Start?
    private var end:Stop?
    private let lock=NSLock()
    private var ledger=NativeContactLedger()
    private var accepting:Set<UInt>=[]
    private var sink:((Int,Bool)->Void)?
    private static let callback:PathCallback = {device,path,state,_ in
        guard let device else{return}
        shared.consume(device:UInt(bitPattern:device),path:path,state:state)
    }
    private static let buttonCallback:ButtonCallback = {device,new,old,_ in
        guard let device,new & ~old != 0 else{return}
        shared.consumeClick(device:UInt(bitPattern:device))
    }
    private init() {
        guard let h=dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",RTLD_LAZY|RTLD_LOCAL),
              let l=dlsym(h,"MTDeviceCreateList"),let s=dlsym(h,"MTDeviceGetService"),
              let r=dlsym(h,"MTRegisterPathCallback"),let u=dlsym(h,"MTUnregisterPathCallback"),
              let b=dlsym(h,"MTDeviceStart"),let e=dlsym(h,"MTDeviceStop") else{return}
        if let rb=dlsym(h,"MTRegisterButtonStateCallback"),let ub=dlsym(h,"MTUnregisterButtonStateCallback") {
            registerButton=unsafeBitCast(rb,to:RegisterButton.self);unregisterButton=unsafeBitCast(ub,to:UnregisterButton.self)
        }
        let list=unsafeBitCast(l,to:List.self),service=unsafeBitCast(s,to:Service.self)
        register=unsafeBitCast(r,to:Register.self);unregister=unsafeBitCast(u,to:Register.self)
        begin=unsafeBitCast(b,to:Start.self);end=unsafeBitCast(e,to:Stop.self)
        guard let array=list()?.takeRetainedValue() else{return};retainedDevices=array
        for index in 0..<CFArrayGetCount(array) {
            guard let pointer=CFArrayGetValueAtIndex(array,index) else{continue}
            let node=service(pointer)
            guard node != 0,let pairs=IORegistryEntryCreateCFProperty(node,"DeviceUsagePairs" as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? [[String:NSNumber]] else{continue}
            // Screen (13/4) and trackpad (13/5) are distinct devices, never
            // inferred from pointer movement, product names, or mouse clicks.
            let usage=pairs.first{$0["DeviceUsagePage"]?.intValue == 13}?["DeviceUsage"]?.intValue
            // This macOS build exposes a screen device but neither native
            // path nor frame callbacks deliver its contacts globally. Do not
            // offer a non-working Screen/Both selector or guess at its ABI.
            if usage == 5 {devices.append(Device(pointer:pointer,source:.trackpad))}
        }
    }
    var availableSources:[TouchSource] {
        var result:[TouchSource]=[]
        if devices.contains(where:{$0.source == .screen}) {result.append(.screen)}
        if devices.contains(where:{$0.source == .trackpad}) {result.append(.trackpad)}
        if result.count == 2 {result.append(.both)}
        return result
    }
    /// Call lifecycle operations only on the main thread. Callbacks may arrive
    /// on the framework queue; the lock filters unchanged contact states there.
    func start(source:TouchSource,sink:@escaping(Int,Bool)->Void)->Bool {
        stop()
        guard let register,let begin else{return false}
        lock.lock();self.sink=sink;lock.unlock()
        for device in devices where source.includes(device.source) {
            lock.lock();accepting.insert(UInt(bitPattern:device.pointer));lock.unlock()
            register(device.pointer,Self.callback)
            if device.source == .trackpad {_ = registerButton?(device.pointer,Self.buttonCallback,nil)}
            if begin(device.pointer,0) == 0 {running.append(device)}
            else {_ = unregisterButton?(device.pointer,Self.buttonCallback);unregister?(device.pointer,Self.callback);lock.lock();accepting.remove(UInt(bitPattern:device.pointer));lock.unlock()}
        }
        return !running.isEmpty
    }
    func stop() {
        lock.lock();accepting.removeAll();sink=nil;ledger.reset();lock.unlock()
        // Stop delivery before removing the callback; do not seize or close
        // macOS's underlying device. The retained list outlives callbacks.
        for device in running {_ = end?(device.pointer);unregister?(device.pointer,Self.callback);_ = unregisterButton?(device.pointer,Self.buttonCallback)}
        running.removeAll()
    }
    func reset(){lock.lock();ledger.reset();lock.unlock()}
    private func consumeClick(device:UInt) {
        lock.lock();defer{lock.unlock()}
        guard accepting.contains(device),let sink else{return}
        let count=ledger.count
        DispatchQueue.main.async {sink(count,true)}
    }
    private func consume(device:UInt,path:Int,state:Int) {
        lock.lock()
        guard accepting.contains(device) else{lock.unlock();return}
        let before=ledger.count
        ledger.update(device:device,path:path,state:state)
        let count=ledger.count, notify=ledger.count != before ? sink:nil
        // Keep ordering across native devices, even when their queues differ.
        if let notify {DispatchQueue.main.async {notify(count,false)}}
        lock.unlock()
    }
}
