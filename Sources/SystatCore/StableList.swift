import Foundation

public enum RowState: Sendable, Equatable {
    case normal
    case quitting(since: Date)
    case ended
    case failed(String)
}

public struct DisplayRow: Sendable, Equatable, Identifiable {
    public var row: ProcessRow
    public var state: RowState
    public var id: ProcessIdentity { row.id }

    public init(row: ProcessRow, state: RowState = .normal) {
        self.row = row
        self.state = state
    }
}

/// The top-10 list as shown: reorders freely, except while frozen (pointer over the list,
/// or just after a click), when rows keep their places and ended processes stay as "Ended".
public struct StableList: Sendable {
    public static let quitTimeout: TimeInterval = 5

    public let kind: ListKind
    public private(set) var rows: [DisplayRow] = []

    public init(kind: ListKind) {
        self.kind = kind
    }

    /// `all` is every row, not only the top 10, so a row that drops out of the top 10 is not mistaken for ended.
    public mutating func update(with all: [ProcessRow], frozen: Bool, now: Date) {
        let fresh = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if frozen {
            rows = rows.map { current in
                guard let row = fresh[current.id] else { return DisplayRow(row: current.row, state: .ended) }
                return DisplayRow(row: row, state: current.state)
            }
        } else {
            let states = Dictionary(rows.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
            rows = ProcessTable.top(all, by: kind).map { row in
                switch states[row.id] {
                case .quitting(let since)?: DisplayRow(row: row, state: .quitting(since: since))
                default: DisplayRow(row: row)
                }
            }
        }
        for i in rows.indices {
            if case .quitting(let since) = rows[i].state, now.timeIntervalSince(since) >= Self.quitTimeout {
                rows[i].state = .normal
            }
        }
    }

    public mutating func markQuitting(_ id: ProcessIdentity, at time: Date) {
        set(.quitting(since: time), for: id)
    }

    public mutating func markFailed(_ id: ProcessIdentity, reason: String) {
        set(.failed(reason), for: id)
    }

    public mutating func markEnded(_ id: ProcessIdentity) {
        set(.ended, for: id)
    }

    private mutating func set(_ state: RowState, for id: ProcessIdentity) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].state = state
    }
}
