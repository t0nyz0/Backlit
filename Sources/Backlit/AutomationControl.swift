import Foundation

enum AutomationError:Error,LocalizedError,Equatable {
    case invalidURL,invalidValue,disabled,unavailable
    var errorDescription:String? {
        switch self {
        case .invalidURL:return "That Backlit link is not valid."
        case .invalidValue:return "Brightness must be a finite value from 0 to 100 percent."
        case .disabled:return "Enable Backlit links in Connections before using this action."
        case .unavailable:return "Open Backlit before using this action."
        }
    }
}

enum AutomationCommand:Equatable {
    case power(Bool),toggle,brightness(Double),mode(GlowMode)

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
