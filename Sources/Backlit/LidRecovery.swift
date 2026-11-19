import Foundation

/// Recovery owns only resources recorded by this helper. Always attempt every
/// owned restoration, even if an independent private API has stopped working.
struct LidRecovery: Codable, Equatable {
    let needsRestore: Bool
    let logoOverride: Bool

    init(needsRestore: Bool, logoOverride: Bool) {
        self.needsRestore = needsRestore
        self.logoOverride = logoOverride
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        needsRestore = try values.decode(Bool.self, forKey: .needsRestore)
        logoOverride = try values.decodeIfPresent(Bool.self, forKey: .logoOverride) ?? false
    }
    func restore(forceNormalSleep: Bool = false, logo: () throws -> Void,
                 power: () throws -> Void) throws {
        var failures: [Error] = []
        if logoOverride { do { try logo() } catch { failures.append(error) } }
        if needsRestore || forceNormalSleep { do { try power() } catch { failures.append(error) } }
        if !failures.isEmpty { throw DisplayFailureGroup(failures: failures, separator: " ") }
    }
}
