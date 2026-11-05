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
    @ObservationIgnored private var processReader = ProcessReader()
    /// Running GUI apps, rebuilt only after an app launches or quits.
    @ObservationIgnored private var apps: [Int32: AppInfo]?
    @ObservationIgnored private var appObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var evaluator = CriticalEvaluator()
    @ObservationIgnored private var tracker = CPUTracker()
    @ObservationIgnored private var allRows: [ProcessRow] = []
    @ObservationIgnored private var isOpen = false
    @ObservationIgnored private var lastClick = Date.distantPast
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// Bumped on every open and close, so a read started before one is dropped after it.
    @ObservationIgnored private var generation = 0

    private let uid = getuid()
    private let selfPID = getpid()
    private let home = NSHomeDirectory()

    private static let openInterval: Duration = .seconds(2)
    private static let closedInterval: Duration = .seconds(5)
    private static let clickHold: TimeInterval = 1
    private static let closedDiskMaxAge: TimeInterval = 30
    private static let openDiskMaxAge: TimeInterval = 10
    /// Just under two refreshes, so `ps` runs every other refresh.
    private static let psMaxAge: TimeInterval = 3.5

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            appObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apps = nil }
            })
        }
        restartLoop()
    }

    func menuWillOpen() {
        generation += 1
        isOpen = true
        selectedList = initialList(for: critical)
        restartLoop()
    }

    func menuDidClose() {
        generation += 1
        isOpen = false
        tracker.reset()
        processReader = ProcessReader()   // free the per-process cache while closed
        apps = nil
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
        let startedIn = generation
        if wantProcesses && apps == nil { apps = runningApps() }
        let apps = wantProcesses ? (self.apps ?? [:]) : [:]
        let reader = machineReader
        let processReader = self.processReader
        let uid = self.uid
        let diskMaxAge = wantProcesses ? Self.openDiskMaxAge : Self.closedDiskMaxAge
        let psMaxAge = Self.psMaxAge
        // Reading (and running ps) happens off the main thread.
        let (updatedReader, updatedProcessReader, sample, records, readAt) = await Task.detached {
            var reader = reader
            var processReader = processReader
            let sample = reader.sample(now: Date(), diskMaxAge: diskMaxAge)
            let readAt = Date()
            let records = wantProcesses
                ? processReader.read(apps: apps, currentUID: uid, now: readAt, psMaxAge: psMaxAge) : nil
            return (reader, processReader, sample, records, readAt)
        }.value
        // The menu opened or closed while reading: these results belong to the old state.
        guard startedIn == generation else { return }

        machineReader = updatedReader
        if records != nil { self.processReader = updatedProcessReader }
        machine = sample
        let state = evaluator.update(sample)
        if state.any != critical.any { onCriticalChange?(state.any) }
        critical = state
        lastUpdated = sample.time

        guard let records, isOpen else { return }
        let cpu = tracker.update(records, at: readAt)
        cpuReady = tracker.isReady
        let now = Date()
        allRows = ProcessTable.rows(from: records, cpu: cpu, currentUID: uid, selfPID: selfPID, home: home, now: now)
        applyRows(frozen: pointerOverList || now.timeIntervalSince(lastClick) < Self.clickHold)
    }

    private func applyRows(frozen: Bool) {
        let now = Date()
        for kind in ListKind.allCases {
            // Until two CPU samples exist, only other users' processes have a CPU figure; a CPU list
            // built then would rank the wrong processes and could freeze that way under the pointer.
            if kind == .cpu && !cpuReady { continue }
            lists[kind]?.update(with: allRows, frozen: frozen, now: now)
        }
    }

    private static func emptyLists() -> [ListKind: StableList] {
        [.memory: StableList(kind: .memory), .cpu: StableList(kind: .cpu)]
    }
}
