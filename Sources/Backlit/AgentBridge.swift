import Foundation
import CryptoKit
import Darwin

enum CodingAgent: String, CaseIterable, Identifiable, Codable {
    case claude, codex

    private struct Installation {
        let label:String
        let settingsFile:String
        let homeVariable:String
        let defaultDirectory:String
    }
    private static let installations:[CodingAgent:Installation]=[
        .claude:Installation(label:"Claude Code",settingsFile:"settings.json",homeVariable:"CLAUDE_CONFIG_DIR",defaultDirectory:".claude"),
        .codex:Installation(label:"Codex",settingsFile:"hooks.json",homeVariable:"CODEX_HOME",defaultDirectory:".codex")
    ]
    private var installation:Installation {Self.installations[self]!}
    var id:String {rawValue}
    var title:String {installation.label}
    var file:String {installation.settingsFile}
    var folder:URL {configurationDirectory(environment:ProcessInfo.processInfo.environment,home:FileManager.default.homeDirectoryForCurrentUser)}

    // Locations are interoperability facts from the agents' own documentation.
    func configurationDirectory(environment:[String:String],home:URL)->URL {
        let profile=installation
        if let location=environment[profile.homeVariable],location.first == "/" {
            return URL(fileURLWithPath:location,isDirectory:true)
        }
        return home.appendingPathComponent(profile.defaultDirectory,isDirectory:true)
    }
}
struct AgentEvent: Codable, Equatable { var agent: CodingAgent; var state: AgentState; var time: Date }
struct AgentHookInstallation: Equatable {
    let fullyInstalled: Bool
    let hasManagedHooks: Bool
    var canDisconnect: Bool { hasManagedHooks }
    static let absent = AgentHookInstallation(fullyInstalled:false,hasManagedHooks:false)
}

/// A partial snapshot must not be presented as complete session status.
struct AgentEventScan {
    let events: [AgentEvent]
    let limited: Bool
}
struct AgentEventScanLimits {
    let maximumEntries: Int
    let maximumReads: Int
    static let standard = Self(maximumEntries: 4096, maximumReads: 1024)
}

enum AgentBridge {
    static var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Backlit") }
    static var eventDirectory: URL { directory.appendingPathComponent("agent-events") }
    static let marker = "--backlit-hook"

    static func receive(agent: CodingAgent, state: String, session: String, directory: URL = eventDirectory) throws {
        guard !session.isEmpty, session.utf8.count <= 256, session.utf8.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)||$0 == 45||$0 == 95}) else { throw RuntimeServices.failure("Session identifier must contain 1–256 ASCII letters, digits, hyphens, or underscores.") }
        let hash = SHA256.hash(data: Data((agent.rawValue + session).utf8)).map { String(format:"%02x",$0) }.joined()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        let file = directory.appendingPathComponent(hash + ".json")
        if state == "ended" { if FileManager.default.fileExists(atPath:file.path) { try FileManager.default.removeItem(at:file) }; return }
        guard let state = AgentState(rawValue:state) else { throw RuntimeServices.failure("Unknown agent state.") }
        try JSONEncoder().encode(AgentEvent(agent:agent,state:state,time:Date())).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    /// Compatibility for callers that do not present completeness. The app
    /// uses scanEvents so a budget-limited snapshot is visibly identified.
    static func events(directory: URL = eventDirectory, now: Date = Date()) -> [AgentEvent] {
        scanEvents(directory: directory, now: now).events
    }
    static func scanEvents(directory: URL = eventDirectory, now: Date = Date(),
                           limits: AgentEventScanLimits = .standard) -> AgentEventScan {
        guard let stream = opendir(directory.path) else {
            return AgentEventScan(events: [], limited: errno != ENOENT)
        }
        defer { closedir(stream) }
        var enumerationFailed = false
        let result = scanEvents(now: now, limits: limits, nextURL: {
            // readdir is nonrecursive and retains only the current entry. Do
            // not construct an array of every filename before applying limits.
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    enumerationFailed = errno != 0
                    return nil
                }
                let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                return directory.appendingPathComponent(name)
            }
        }, readMetadata: metadata(at:))
        return AgentEventScan(events: result.events, limited: result.limited || enumerationFailed)
    }
    /// Deterministic seam for budget/ordering tests; production supplies a
    /// streaming directory cursor and the descriptor-bounded metadata reader.
    static func scanEvents(now: Date, limits: AgentEventScanLimits,
                           nextURL: () -> URL?, readMetadata: (URL) -> Data?) -> AgentEventScan {
        let entryLimit = max(0, limits.maximumEntries), readLimit = max(0, limits.maximumReads)
        var entries = 0, reads = 0, events: [AgentEvent] = []
        while let file = nextURL() {
            // One extra entry distinguishes an exactly-full complete scan
            // from truncation. It is neither opened nor retained.
            guard entries < entryLimit else { return AgentEventScan(events: events, limited: true) }
            entries += 1
            guard file.pathExtension == "json" else { continue }
            guard reads < readLimit else { return AgentEventScan(events: events, limited: true) }
            reads += 1
            guard let data = readMetadata(file), data.count < 4096,
                  let event = try? JSONDecoder().decode(AgentEvent.self, from: data),
                  (-10..<900).contains(now.timeIntervalSince(event.time)) else { continue }
            events.append(event)
        }
        return AgentEventScan(events: events, limited: false)
    }
    /// Bound each read on the opened descriptor, rather than trusting a path
    /// size check followed by an unbounded Foundation read. O_NONBLOCK keeps
    /// opening a FIFO from waiting before fstat can reject non-regular files.
    private static func metadata(at file:URL)->Data? {
        let descriptor = open(file.path,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var information = stat()
        guard fstat(descriptor,&information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_size >= 0, information.st_size < 4096 else { return nil }
        var bytes = [UInt8](repeating:0,count:4096), count = 0
        while count < bytes.count {
            let received = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor,buffer.baseAddress!.advanced(by:count),buffer.count-count)
            }
            if received == 0 { return Data(bytes.prefix(count)) }
            if received < 0 {
                if errno == EINTR { continue }
                return nil
            }
            count += received
        }
        return nil // Includes a file that grew to the limit after fstat.
    }
    static func aggregate(_ events: [AgentEvent]) -> AgentState {
        events.contains{$0.state == .attention} ? .attention : events.contains{$0.state == .working} ? .working : .waiting
    }
    static func file(_ agent: CodingAgent) -> URL {
        let key = "agent.folder." + agent.rawValue
        return (UserDefaults.standard.string(forKey:key).map{URL(fileURLWithPath:$0)} ?? agent.folder).appendingPathComponent(agent.file)
    }
    static func connected(_ agent: CodingAgent) -> Bool {
        installation(agent).fullyInstalled
    }
    static func installation(_ agent: CodingAgent) -> AgentHookInstallation {
        guard let data = try? Data(contentsOf:file(agent)) else { return .absent }
        return inspectHooks(data,agent:agent,binaries:binaries(for:agent),
            isExecutable:FileManager.default.isExecutableFile(atPath:))
    }
    /// Recognizes a complete current installation, not trust or event delivery.
    /// Unknown/custom/legacy commands are preserved but do not establish that
    /// every current hook is installed and points at an available executable.
    static func hooksInstalled(_ data:Data,agent:CodingAgent,binaries:[String],isExecutable:(String)->Bool)->Bool {
        inspectHooks(data,agent:agent,binaries:binaries,isExecutable:isExecutable).fullyInstalled
    }
    static func inspectHooks(_ data:Data,agent:CodingAgent,binaries:[String],isExecutable:(String)->Bool)->AgentHookInstallation {
        guard let document = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              let hooks = document["hooks"] as? [String:Any] else { return .absent }
        // Removability is independent of completeness and executable health.
        // Mirror the merger's exact ownership rules so partial/stale/legacy
        // installations retain Disconnect without claiming custom shell work.
        let owned = Set(binaries.flatMap { path in
            ["working","waiting","attention","ended"].map { command(agent,$0,binary:path) }
        })
        let hasManagedHooks = hookEvents(for:agent).contains { name,_ in
            (hooks[name] as? [[String:Any]] ?? []).contains { group in
                (group["hooks"] as? [[String:Any]] ?? []).contains { item in
                    guard let text = item["command"] as? String else { return false }
                    return owned.contains(text) || ownsLegacyCommand(text,agent:agent,binaries:binaries)
                }
            }
        }
        let available = Set(binaries).filter { $0.hasPrefix("/") && !$0.contains("\0") && isExecutable($0) }
        let fullyInstalled = document["disableAllHooks"] as? Bool != true && available.contains { binary in
            hookEvents(for:agent).allSatisfy { name,phase in
                guard let groups = hooks[name] as? [[String:Any]] else { return false }
                return groups.contains { group in
                    if name == "Notification" {
                        guard group["matcher"] as? String == "permission_prompt|idle_prompt" else { return false }
                    } else if let matcher = group["matcher"] {
                        guard matcher as? String == "" else { return false }
                    }
                    guard let commands = group["hooks"] as? [[String:Any]] else { return false }
                    return commands.contains {
                        $0["type"] as? String == "command" && $0["command"] as? String == command(agent,phase,binary:binary)
                    }
                }
            }
        }
        return AgentHookInstallation(fullyInstalled:fullyInstalled,hasManagedHooks:hasManagedHooks)
    }
    private static func binaries(for agent:CodingAgent)->[String] {
        [Bundle.main.executableURL!.path,
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Backlit.app/Contents/MacOS/Backlit").path,
         "/Applications/Backlit.app/Contents/MacOS/Backlit"]
        + (UserDefaults.standard.string(forKey:"agent.binary."+agent.rawValue).map{[$0]} ?? [])
    }
    private static func hookEvents(for agent:CodingAgent)->[(String,String)] {
        let base = [("UserPromptSubmit","working"),("PreToolUse","working"),("PostToolUse","working"),
                    ("PermissionRequest","attention"),("Stop","waiting"),("SessionEnd","ended")]
        return base + (agent == .codex ? [("Interrupt","waiting")] : [("PostToolUseFailure","working"),("Notification","attention")])
    }
    static func shellArgument(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    static func command(_ agent:CodingAgent,_ phase:String,binary:String)->String {
        let executable=shellArgument(binary)
        return """
        # Backlit metadata hook v2
        [ -x \(executable) ] || exit 0
        /usr/bin/pgrep -x Backlit >/dev/null 2>&1 || exit 0
        backlit_session=$(/usr/bin/plutil -extract session_id raw -expect string -o - - 2>/dev/null) || exit 0
        [ -n "$backlit_session" ] && [ "${#backlit_session}" -le 256 ] || exit 0
        \(executable) \(marker) \(agent.rawValue) \(shellArgument(phase)) "$backlit_session" >/dev/null 2>&1 || :
        """
    }
    private static func ownsLegacyCommand(_ text:String,agent:CodingAgent,binaries:[String])->Bool {
        // A prefix and embedded invocation do not establish ownership of the
        // whole shell command: users may have appended their own work. Only
        // remove the exact known legacy form; preserve unknown variants.
        binaries.contains { binary in
            ["working","waiting","attention","ended"].contains { phase in
                text == "/usr/bin/pgrep -xq Backlit || exit 0; " + shellArgument(binary)
                    + " " + marker + " " + agent.rawValue + " " + phase + " $sid"
            }
        }
    }
    static func merged(_ original: Data?, agent: CodingAgent, enabled: Bool, binary: String, priorBinaries: [String] = []) throws -> Data {
        var doc: [String:Any] = [:]
        if let original {
            guard let parsed = try JSONSerialization.jsonObject(with:original) as? [String:Any] else { throw RuntimeServices.failure("Agent settings must be a JSON object. Nothing changed.") }
            doc = parsed
        }
        guard doc["hooks"] == nil || doc["hooks"] is [String:Any] else { throw RuntimeServices.failure("Unrecognized hooks format. Nothing changed.") }
        var hooks = doc["hooks"] as? [String:Any] ?? [:]
        for (name,phase) in hookEvents(for:agent) {
            guard hooks[name] == nil || hooks[name] is [[String:Any]] else { throw RuntimeServices.failure("Unrecognized event format. Nothing changed.") }
            var groups: [[String:Any]] = []
            for group in hooks[name] as? [[String:Any]] ?? [] {
                guard let commands = group["hooks"] as? [[String:Any]] else { throw RuntimeServices.failure("Unrecognized hook group. Nothing changed.") }
                let ours = Set(([binary] + priorBinaries).flatMap { path in ["working","waiting","attention","ended"].map { command(agent,$0,binary:path) } })
                let retained = commands.filter { item in
                    guard let text = item["command"] as? String else { return true }
                    return !ours.contains(text) && !ownsLegacyCommand(text,agent:agent,binaries:[binary]+priorBinaries)
                }
                if retained.count == commands.count { groups.append(group) }
                else if !retained.isEmpty { var amended = group; amended["hooks"] = retained; groups.append(amended) }
            }
            if enabled {
                var group: [String:Any] = ["hooks":[["type":"command","command":command(agent,phase,binary:binary),"timeout":3]]]
                if name == "Notification" { group["matcher"] = "permission_prompt|idle_prompt" }
                groups.append(group)
            }
            hooks[name] = groups.isEmpty ? nil : groups
        }
        doc["hooks"] = hooks.isEmpty ? nil : hooks
        return try JSONSerialization.data(withJSONObject:doc,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]) + Data([10])
    }
    static func connect(_ agent: CodingAgent, enabled: Bool) throws {
        let binary = Bundle.main.executableURL!.path
        let prior = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Backlit.app/Contents/MacOS/Backlit").path, "/Applications/Backlit.app/Contents/MacOS/Backlit"] + (UserDefaults.standard.string(forKey:"agent.binary."+agent.rawValue).map{[$0]} ?? [])
        if try saveHooks(at: file(agent), agent: agent, enabled: enabled, binary: binary,
                         priorBinaries: prior, backupDirectory: directory) {
            UserDefaults.standard.set(binary, forKey: "agent.binary." + agent.rawValue)
        }
    }
    /// The path-injected transaction is also used by inert filesystem tests.
    /// Existing-file writers can still race the optimistic reread; no external
    /// compare-and-swap guarantee is claimed. Initial creation never replaces
    /// a file that appeared after the absent observation.
    @discardableResult static func saveHooks(at file: URL, agent: CodingAgent, enabled: Bool,
                                            binary: String, priorBinaries: [String] = [],
                                            backupDirectory: URL,
                                            beforeCommit: () throws -> Void = {}) throws -> Bool {
        let manager = FileManager.default
        let exists = manager.fileExists(atPath: file.path)
        if !exists && !enabled { return false }
        let attrs = exists ? try manager.attributesOfItem(atPath: file.path) : [:]
        guard !exists || attrs[.type] as? FileAttributeType == .typeRegular else { throw RuntimeServices.failure("Agent settings is a symbolic link or special file. Choose its actual folder first.") }
        let bytes = exists ? try Data(contentsOf: file) : nil
        let output = try merged(bytes, agent: agent, enabled: enabled, binary: binary, priorBinaries: priorBinaries)
        try manager.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let bytes {
            let backup = backupDirectory.appendingPathComponent("agent-backup-" + UUID().uuidString + ".json")
            try bytes.write(to: backup, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            guard try Data(contentsOf: file) == bytes else { throw RuntimeServices.failure("Agent settings changed during connection. Try again.") }
            SupportFilePruner.pruneAgentBackups(directory: backupDirectory)
        }
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if exists {
            try beforeCommit()
            try output.write(to: file, options: .atomic)
            try manager.setAttributes([.posixPermissions: attrs[.posixPermissions] ?? 0o600], ofItemAtPath: file.path)
        } else {
            try createHooksExclusively(output, at: file, beforeCommit: beforeCommit)
        }
        return true
    }
    private static func createHooksExclusively(_ data: Data, at file: URL,
                                               beforeCommit: () throws -> Void) throws {
        let manager = FileManager.default
        let staged = file.deletingLastPathComponent().appendingPathComponent(".backlit-hooks-" + UUID().uuidString + ".tmp")
        let descriptor = open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var needsClose = true
        defer {
            if needsClose { close(descriptor) }
            try? manager.removeItem(at: staged)
        }
        // The descriptor is private from creation; restore owner read/write
        // if an unusually restrictive process umask removed either bit.
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        try data.withUnsafeBytes { buffer in
            var count = 0
            while count < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: count), buffer.count - count)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(written == 0 ? EIO : errno)) }
                count += written
            }
        }
        let closeResult = close(descriptor)
        needsClose = false
        guard closeResult == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        try beforeCommit()
        guard renamex_np(staged.path, file.path, UInt32(RENAME_EXCL)) == 0 else {
            let reason = errno
            if reason == EEXIST || reason == ENOTEMPTY {
                throw RuntimeServices.failure("Agent settings appeared during connection. Nothing was overwritten. Review them and try again.")
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(reason))
        }
    }
}
