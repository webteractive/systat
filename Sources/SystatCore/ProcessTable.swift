import Foundation

/// One row of the top-10 list. For a `claude` session it covers the session and its helpers.
public struct ProcessRow: Sendable, Equatable, Identifiable {
    public var id: ProcessIdentity
    public var name: String
    public var detail: String
    public var memoryBytes: UInt64
    public var cpuPercent: Double?
    public var isApproximate: Bool
    public var protection: Protection
    public var isApp: Bool
    public var isClaudeSession: Bool

    public init(id: ProcessIdentity, name: String, detail: String, memoryBytes: UInt64, cpuPercent: Double?,
                isApproximate: Bool, protection: Protection, isApp: Bool, isClaudeSession: Bool) {
        self.id = id
        self.name = name
        self.detail = detail
        self.memoryBytes = memoryBytes
        self.cpuPercent = cpuPercent
        self.isApproximate = isApproximate
        self.protection = protection
        self.isApp = isApp
        self.isClaudeSession = isClaudeSession
    }
}

public enum ProcessTable {
    /// The leader followed by every descendant owned by `ownerUID`, reached through owned processes only.
    public static func sessionMembers(leader: ProcessIdentity, in records: [ProcessRecord], ownerUID: UInt32) -> [ProcessIdentity] {
        let children = Dictionary(grouping: records, by: \.parentPID)
        var members = [leader]
        var seen: Set<Int32> = [leader.pid]
        var queue = [leader.pid]
        while !queue.isEmpty {
            let pid = queue.removeFirst()
            for child in children[pid] ?? [] where child.uid == ownerUID && !seen.contains(child.identity.pid) {
                seen.insert(child.identity.pid)
                members.append(child.identity)
                queue.append(child.identity.pid)
            }
        }
        return members
    }

    public static func rows(from records: [ProcessRecord], cpu: [ProcessIdentity: Double], currentUID: UInt32,
                            selfPID: Int32, home: String, now: Date) -> [ProcessRow] {
        let records = records.filter { $0.identity.pid != selfPID }
        let byPID = Dictionary(records.map { ($0.identity.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let byIdentity = Dictionary(records.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        func isOwnClaude(_ r: ProcessRecord) -> Bool { r.uid == currentUID && Naming.isClaude(r) }
        func hasClaudeAncestor(_ r: ProcessRecord) -> Bool {
            var seen: Set<Int32> = [r.identity.pid]
            var pid = r.parentPID
            while let parent = byPID[pid], !seen.contains(pid) {
                if isOwnClaude(parent) { return true }
                seen.insert(pid)
                pid = parent.parentPID
            }
            return false
        }

        let leaders = records.filter { isOwnClaude($0) && !hasClaudeAncestor($0) }
        var sessions: [ProcessIdentity: [ProcessRecord]] = [:]
        var folded: Set<ProcessIdentity> = []
        for leader in leaders {
            let members = sessionMembers(leader: leader.identity, in: records, ownerUID: currentUID)
            sessions[leader.identity] = members.compactMap { byIdentity[$0] }
            folded.formUnion(members.dropFirst())
        }

        let kept = records.filter { !folded.contains($0.identity) }
        let names = kept.map(Naming.displayName)
        let nameCounts = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
        return zip(kept, names).map { r, name in
            let members = sessions[r.identity] ?? [r]
            let leaderCPU = cpu[r.identity]
            let sessionCPU = leaderCPU.map { _ in members.compactMap { cpu[$0.identity] }.reduce(0, +) }
            return ProcessRow(
                id: r.identity,
                name: name,
                detail: Naming.detail(for: r, name: name, nameIsShared: (nameCounts[name] ?? 0) > 1, home: home, now: now),
                memoryBytes: members.reduce(0) { $0 + $1.memoryBytes },
                cpuPercent: sessionCPU,
                isApproximate: members.contains(where: \.isApproximate),
                protection: Protection.classify(uid: r.uid, currentUID: currentUID, pid: r.identity.pid,
                                                executablePath: r.executablePath, name: name),
                isApp: r.app != nil,
                isClaudeSession: sessions[r.identity] != nil
            )
        }
    }

    public static func top(_ rows: [ProcessRow], by kind: ListKind, limit: Int = 10) -> [ProcessRow] {
        let sorted = rows.sorted { a, b in
            switch kind {
            case .memory:
                if a.memoryBytes != b.memoryBytes { return a.memoryBytes > b.memoryBytes }
            case .cpu:
                switch (a.cpuPercent, b.cpuPercent) {
                case let (x?, y?) where x != y: return x > y
                case (.some, nil): return true
                case (nil, .some): return false
                default: break
                }
            }
            return a.id.pid < b.id.pid
        }
        return Array(sorted.prefix(limit))
    }
}
