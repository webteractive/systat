import AppKit
import Observation
import SystatCore

/// The refresh loop and everything the panel shows.
/// Closed: machine figures every 5 s. Open: machine and processes every 2 s.
@MainActor @Observable final class Monitor {
    private(set) var machine: MachineSample?
    private(set) var critical = CriticalState()
    private(set) var lastUpdated: Date?
    private(set) var cpuReady = false
    private(set) var lists: [ListKind: StableList] = Monitor.emptyLists()
    var selectedList: ListKind = .memory
    var pointerOverList = false {
        didSet { if oldValue && !pointerOverList { applyRows(frozen: false) } }
    }

    /// Called with `critical.any` whenever it changes; drives the menu bar icon.
    @ObservationIgnored var onCriticalChange: ((Bool) -> Void)?

    @ObservationIgnored private var machineReader = MachineReader()
    @ObservationIgnored private var evaluator = CriticalEvaluator()
    @ObservationIgnored private var tracker = CPUTracker()
    @ObservationIgnored private var allRows: [ProcessRow] = []
    @ObservationIgnored private var isOpen = false
    @ObservationIgnored private var lastClick = Date.distantPast
    @ObservationIgnored private var loop: Task<Void, Never>?

    private let uid = getuid()
    private let selfPID = getpid()
    private let home = NSHomeDirectory()

    private static let openInterval: Duration = .seconds(2)
    private static let closedInterval: Duration = .seconds(5)
    private static let clickHold: TimeInterval = 1

    func start() {
        restartLoop()
    }

    func menuWillOpen() {
        isOpen = true
        selectedList = initialList(for: critical)
        restartLoop()
    }

    func menuDidClose() {
        isOpen = false
        tracker.reset()
        cpuReady = false
        allRows = []
        lists = Self.emptyLists()
        pointerOverList = false
    }

    func quit(_ row: DisplayRow) { act(.quit, on: row) }

    func forceQuit(_ row: DisplayRow) { act(.forceQuit, on: row) }

    private func act(_ action: KillAction, on display: DisplayRow) {
        lastClick = Date()
        guard display.row.protection == .killable, display.state != .ended else { return }
        let outcome = ProcessKiller.perform(action, on: display.row, currentUID: uid)
        // The same process can be in both lists; mark it in each.
        for kind in ListKind.allCases {
            switch outcome {
            case .sent where action == .quit: lists[kind]?.markQuitting(display.id, at: lastClick)
            case .sent: break   // the next refresh shows it as ended
            case .gone: lists[kind]?.markEnded(display.id)
            case .failed(let reason): lists[kind]?.markFailed(display.id, reason: reason)
            }
        }
    }

    /// Refreshes at once, then on the open or closed interval.
    private func restartLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: self.isOpen ? Self.openInterval : Self.closedInterval)
            }
        }
    }

    private func refresh() async {
        let wantProcesses = isOpen
        let apps = wantProcesses ? runningApps() : [:]
        let reader = machineReader
        let uid = self.uid
        // Reading (and running ps) happens off the main thread.
        let (updatedReader, sample, records) = await Task.detached {
            var reader = reader
            let sample = reader.sample(now: Date())
            let records = wantProcesses ? ProcessReader().read(apps: apps, currentUID: uid) : nil
            return (reader, sample, records)
        }.value

        machineReader = updatedReader
        machine = sample
        let state = evaluator.update(sample)
        if state.any != critical.any { onCriticalChange?(state.any) }
        critical = state
        lastUpdated = sample.time

        guard let records, isOpen else { return }
        let now = Date()
        let cpu = tracker.update(records, at: now)
        cpuReady = tracker.isReady
        allRows = ProcessTable.rows(from: records, cpu: cpu, currentUID: uid, selfPID: selfPID, home: home, now: now)
        applyRows(frozen: pointerOverList || now.timeIntervalSince(lastClick) < Self.clickHold)
    }

    private func applyRows(frozen: Bool) {
        let now = Date()
        for kind in ListKind.allCases {
            lists[kind]?.update(with: allRows, frozen: frozen, now: now)
        }
    }

    private static func emptyLists() -> [ListKind: StableList] {
        [.memory: StableList(kind: .memory), .cpu: StableList(kind: .cpu)]
    }
}
