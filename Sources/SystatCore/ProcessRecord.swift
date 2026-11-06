import Foundation

/// A process as identified by its PID plus its start time, so a reused PID is a different process.
public struct ProcessIdentity: Hashable, Sendable {
    public let pid: Int32
    /// Microseconds since 1970.
    public let startTime: UInt64

    public init(pid: Int32, startTime: UInt64) {
        self.pid = pid
        self.startTime = startTime
    }
}

/// A GUI app's name and the path of its `.app` bundle.
public struct AppInfo: Sendable, Equatable {
    public var name: String
    public var bundlePath: String

    public init(name: String, bundlePath: String) {
        self.name = name
        self.bundlePath = bundlePath
    }
}

/// Everything systat knows about one process at one refresh.
public struct ProcessRecord: Sendable, Equatable {
    public var identity: ProcessIdentity
    public var parentPID: Int32
    public var uid: UInt32
    /// The kernel's short command name (`p_comm`).
    public var commandName: String
    public var executablePath: String?
    /// Readable for the user's own processes only.
    public var arguments: [String]?
    /// Readable for the user's own processes only.
    public var workingDirectory: String?
    public var app: AppInfo?
    public var memoryBytes: UInt64
    /// Cumulative user + system CPU time, own processes only.
    public var cpuTimeNanos: UInt64?
    /// `ps`'s decaying %cpu, for processes libproc cannot read.
    public var psCPUPercent: Double?
    /// True when the figures came from `ps` (resident size, not footprint).
    public var isApproximate: Bool

    public init(identity: ProcessIdentity, parentPID: Int32, uid: UInt32, commandName: String,
                executablePath: String? = nil, arguments: [String]? = nil, workingDirectory: String? = nil,
                app: AppInfo? = nil, memoryBytes: UInt64 = 0, cpuTimeNanos: UInt64? = nil,
                psCPUPercent: Double? = nil, isApproximate: Bool = false) {
        self.identity = identity
        self.parentPID = parentPID
        self.uid = uid
        self.commandName = commandName
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.app = app
        self.memoryBytes = memoryBytes
        self.cpuTimeNanos = cpuTimeNanos
        self.psCPUPercent = psCPUPercent
        self.isApproximate = isApproximate
    }

    public var startDate: Date { Date(timeIntervalSince1970: Double(identity.startTime) / 1_000_000) }
}
