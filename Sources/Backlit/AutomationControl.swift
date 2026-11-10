import Foundation
import CoreFoundation

enum ActivityCategory:String,CaseIterable,Codable,Identifiable {
    case build,export,backup,focus,recording,streaming
    var id:String {rawValue}
    var title:String {rawValue.capitalized}
}

enum ActivityState:String,CaseIterable,Codable,Identifiable {
    case active,complete,attention,clear
    var id:String {rawValue}
}

enum AutomationError:Error,LocalizedError,Equatable {
    case invalidURL,invalidSignal,invalidValue,disabled,unavailable
    var errorDescription:String? {
        switch self {
        case .invalidURL:return "That Backlit link is not valid."
        case .invalidSignal:return "Use a known activity and state, with a bounded duration and progress from 0 to 1."
        case .invalidValue:return "Brightness must be a finite value from 0 to 100 percent."
        case .disabled:return "Enable Shortcuts and links in Backlit before using this action."
        case .unavailable:return "Open Backlit before using this action."
        }
    }
}

/// Only fixed activity metadata crosses the automation boundary.
struct ActivitySignal:Codable,Equatable {
    let category:ActivityCategory
    let state:ActivityState
    let duration:Double?
    let progress:Double?
    var effectiveDuration:Double {duration ?? (state == .active ? 60 : state == .clear ? 0 : 8)}

    init(category:ActivityCategory,state:ActivityState,duration:Double?=nil,progress:Double?=nil) throws {
        if let duration {
            let maximum=state == .active ? 14_400.0 : 60.0
            guard state != .clear,duration.isFinite,(1...maximum).contains(duration) else {throw AutomationError.invalidSignal}
        }
        if let progress {
            guard state == .active,progress.isFinite,(0...1).contains(progress) else {throw AutomationError.invalidSignal}
        }
        self.category=category;self.state=state;self.duration=duration;self.progress=progress
    }
    init(data:Data) throws {
        guard data.count<=2048,
              let object=try? JSONSerialization.jsonObject(with:data),let value=object as? [String:Any],
              Set(value.keys).isSubset(of:["category","state","duration","progress"]),
              let rawCategory=value["category"] as? String,let category=ActivityCategory(rawValue:rawCategory),
              let rawState=value["state"] as? String,let state=ActivityState(rawValue:rawState) else {throw AutomationError.invalidSignal}
        func number(_ key:String) throws ->Double? {
            guard let raw=value[key] else{return nil}
            guard let n=raw as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else {throw AutomationError.invalidSignal}
            return n.doubleValue
        }
        try self.init(category:category,state:state,duration:number("duration"),progress:number("progress"))
    }
    init(from decoder:Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(category:values.decode(ActivityCategory.self,forKey:.category),state:values.decode(ActivityState.self,forKey:.state),
                      duration:values.decodeIfPresent(Double.self,forKey:.duration),progress:values.decodeIfPresent(Double.self,forKey:.progress))
    }
    private enum CodingKeys:String,CodingKey {case category,state,duration,progress}
}

enum AutomationCommand:Equatable {
    case power(Bool),toggle,brightness(Double),mode(GlowMode),signal(ActivitySignal)

    static func behavior(named name:String) throws ->GlowMode {
        guard let value=GlowMode(rawValue:name.lowercased() == "trackpad" ? "touch" : name.lowercased()) else {throw AutomationError.invalidURL}
        return value
    }
    init(url:URL) throws {
        guard url.absoluteString.utf8.count<=1024,
              let parts=URLComponents(url:url,resolvingAgainstBaseURL:false),parts.scheme?.lowercased()=="backlit",
              parts.user==nil,parts.password==nil,parts.port==nil,parts.fragment==nil,
              parts.path.isEmpty || parts.path=="/",let host=parts.host,
              parts.percentEncodedHost==host else {throw AutomationError.invalidURL}
        var query:[String:String]=[:]
        for item in parts.queryItems ?? [] {
            guard query[item.name]==nil,let value=item.value,!value.isEmpty else {throw AutomationError.invalidURL}
            query[item.name]=value
        }
        func only(_ keys:Set<String>) throws {
            guard Set(query.keys).isSubset(of:keys) else {throw AutomationError.invalidURL}
        }
        func number(_ key:String) throws ->Double? {
            guard let value=query[key] else{return nil}
            guard value==value.trimmingCharacters(in:.whitespacesAndNewlines),let number=Double(value),number.isFinite else {throw AutomationError.invalidURL}
            return number
        }
        switch host.lowercased() {
        case "power":
            try only(["state"])
            guard let value=query["state"],value=="on" || value=="off" else {throw AutomationError.invalidURL}
            self = .power(value=="on")
        case "toggle":
            try only([]);self = .toggle
        case "brightness":
            try only(["value"])
            guard let value=try number("value"),(0...100).contains(value) else {throw AutomationError.invalidValue}
            self = .brightness(value/100)
        case "mode":
            try only(["name"])
            guard let name=query["name"] else {throw AutomationError.invalidURL}
            self = .mode(try Self.behavior(named:name))
        case "signal":
            try only(["category","state","duration","progress"])
            guard let name=query["category"],let category=ActivityCategory(rawValue:name),
                  let raw=query["state"],let state=ActivityState(rawValue:raw) else {throw AutomationError.invalidSignal}
            self = .signal(try ActivitySignal(category:category,state:state,duration:number("duration"),progress:number("progress")))
        default:throw AutomationError.invalidURL
        }
    }
}

@MainActor final class AutomationRouter {
    static let shared=AutomationRouter()
    var enabled=false
    var handler:((AutomationCommand)throws->Void)?
    func perform(_ command:AutomationCommand) throws {
        guard enabled else {throw AutomationError.disabled}
        if case .brightness(let value)=command {
            guard value.isFinite,(0...1).contains(value) else {throw AutomationError.invalidValue}
        }
        guard let handler else {throw AutomationError.unavailable}
        try handler(command)
    }
}
