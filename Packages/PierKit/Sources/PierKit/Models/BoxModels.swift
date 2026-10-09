// Codable models of pierd's JSON (docs/API.md §13.3), checked against the Go structs in Server/pierd.
import Foundation

/// What an agent adapter can report and how (`hooks`, `notify`, `plugin`, `screen`).
public struct AdapterCaps: Codable, Sendable, Hashable {
    public let ready: Bool
    public let started: Bool
    public let waiting: Bool
    public let finished: Bool
    public let finalMessage: Bool
    public let via: String

    public init(ready: Bool = false, started: Bool = false, waiting: Bool = false, finished: Bool = false, finalMessage: Bool = false, via: String = "") {
        self.ready = ready
        self.started = started
        self.waiting = waiting
        self.finished = finished
        self.finalMessage = finalMessage
        self.via = via
    }

    enum CodingKeys: String, CodingKey {
        case ready
        case started
        case waiting
        case finished
        case finalMessage = "final_message"
        case via
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.ready = try c.decodeIfPresent(Bool.self, forKey: .ready) ?? false
        self.started = try c.decodeIfPresent(Bool.self, forKey: .started) ?? false
        self.waiting = try c.decodeIfPresent(Bool.self, forKey: .waiting) ?? false
        self.finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? false
        self.finalMessage = try c.decodeIfPresent(Bool.self, forKey: .finalMessage) ?? false
        self.via = try c.decodeIfPresent(String.self, forKey: .via) ?? ""
    }
}

/// An agent the box can start (`GET /v1/info` agents[] or a location's presets).
public struct AgentPreset: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let command: String
    public let promptFlag: String?
    public let modelFlag: String?
    public let effortFlag: String?
    public let models: [String]?
    public let efforts: [String]?

    public init(id: String, name: String = "", command: String = "", promptFlag: String? = nil, modelFlag: String? = nil, effortFlag: String? = nil, models: [String]? = nil, efforts: [String]? = nil) {
        self.id = id
        self.name = name
        self.command = command
        self.promptFlag = promptFlag
        self.modelFlag = modelFlag
        self.effortFlag = effortFlag
        self.models = models
        self.efforts = efforts
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case command
        case promptFlag = "prompt_flag"
        case modelFlag = "model_flag"
        case effortFlag = "effort_flag"
        case models
        case efforts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        self.promptFlag = try c.decodeIfPresent(String.self, forKey: .promptFlag)
        self.modelFlag = try c.decodeIfPresent(String.self, forKey: .modelFlag)
        self.effortFlag = try c.decodeIfPresent(String.self, forKey: .effortFlag)
        self.models = try c.decodeIfPresent([String].self, forKey: .models)
        self.efforts = try c.decodeIfPresent([String].self, forKey: .efforts)
    }

    /// Show a model picker only if the box can pass one.
    public var canPickModel: Bool { modelFlag != nil }
    public var canPickEffort: Bool { effortFlag != nil }
}

/// `GET /v1/info`. `build` is a binary digest, not a version.
public struct BoxInfo: Codable, Sendable, Hashable {
    public let name: String
    public let os: String
    public let arch: String
    public let build: String
    public let user: String?
    public let home: String?
    public let tools: [String]
    public let agents: [AgentPreset]
    public let capabilities: [String]
    public let adapters: [String: AdapterCaps]?

    public init(name: String, os: String = "", arch: String = "", build: String = "", user: String? = nil, home: String? = nil, tools: [String] = [], agents: [AgentPreset] = [], capabilities: [String] = [], adapters: [String: AdapterCaps]? = nil) {
        self.name = name
        self.os = os
        self.arch = arch
        self.build = build
        self.user = user
        self.home = home
        self.tools = tools
        self.agents = agents
        self.capabilities = capabilities
        self.adapters = adapters
    }

    enum CodingKeys: String, CodingKey {
        case name
        case os
        case arch
        case build
        case user
        case home
        case tools
        case agents
        case capabilities
        case adapters
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.os = try c.decodeIfPresent(String.self, forKey: .os) ?? ""
        self.arch = try c.decodeIfPresent(String.self, forKey: .arch) ?? ""
        self.build = try c.decodeIfPresent(String.self, forKey: .build) ?? ""
        self.user = try c.decodeIfPresent(String.self, forKey: .user)
        self.home = try c.decodeIfPresent(String.self, forKey: .home)
        self.tools = try c.decodeIfPresent([String].self, forKey: .tools) ?? []
        self.agents = try c.decodeIfPresent([AgentPreset].self, forKey: .agents) ?? []
        self.capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        self.adapters = try c.decodeIfPresent([String: AdapterCaps].self, forKey: .adapters)
    }

    public func has(_ capability: String) -> Bool { capabilities.contains(capability) }
}

/// An installable agent CLI (`GET /v1/agents`).
public struct AgentCLI: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let command: String
    public let install: String?
    public let verified: String?
    public let isDefault: Bool?
    public let offered: Bool
    public let why: String?
    public let installed: Bool
    public let path: String?

    public init(id: String, name: String = "", command: String = "", install: String? = nil, verified: String? = nil, isDefault: Bool? = nil, offered: Bool = false, why: String? = nil, installed: Bool = false, path: String? = nil) {
        self.id = id
        self.name = name
        self.command = command
        self.install = install
        self.verified = verified
        self.isDefault = isDefault
        self.offered = offered
        self.why = why
        self.installed = installed
        self.path = path
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case command
        case install
        case verified
        case isDefault = "default"
        case offered
        case why
        case installed
        case path
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        self.install = try c.decodeIfPresent(String.self, forKey: .install)
        self.verified = try c.decodeIfPresent(String.self, forKey: .verified)
        self.isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault)
        self.offered = try c.decodeIfPresent(Bool.self, forKey: .offered) ?? false
        self.why = try c.decodeIfPresent(String.self, forKey: .why)
        self.installed = try c.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        self.path = try c.decodeIfPresent(String.self, forKey: .path)
    }
}

extension BoxStats {
    public struct Usage: Codable, Sendable, Hashable {
        public let total: UInt64
        public let used: UInt64

        public init(total: UInt64 = 0, used: UInt64 = 0) {
            self.total = total
            self.used = used
        }

        enum CodingKeys: String, CodingKey {
            case total
            case used
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.total = try c.decodeIfPresent(UInt64.self, forKey: .total) ?? 0
            self.used = try c.decodeIfPresent(UInt64.self, forKey: .used) ?? 0
        }
    }
}

extension BoxStats {
    public struct Disk: Codable, Sendable, Hashable {
        public let mount: String
        public let total: UInt64
        public let used: UInt64

        public init(mount: String, total: UInt64 = 0, used: UInt64 = 0) {
            self.mount = mount
            self.total = total
            self.used = used
        }

        enum CodingKeys: String, CodingKey {
            case mount
            case total
            case used
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.mount = try c.decode(String.self, forKey: .mount)
            self.total = try c.decodeIfPresent(UInt64.self, forKey: .total) ?? 0
            self.used = try c.decodeIfPresent(UInt64.self, forKey: .used) ?? 0
        }
    }
}

extension BoxStats {
    /// An agent process on the box (also ones pierd did not start).
    public struct AgentProc: Codable, Sendable, Hashable {
        public let tool: String
        public let pid: Int
        public let path: String?
        public let location: String?
        public let worktree: String?
        public let state: String
        public let since: Date?

        public init(tool: String, pid: Int = 0, path: String? = nil, location: String? = nil, worktree: String? = nil, state: String = "running", since: Date? = nil) {
            self.tool = tool
            self.pid = pid
            self.path = path
            self.location = location
            self.worktree = worktree
            self.state = state
            self.since = since
        }

        enum CodingKeys: String, CodingKey {
            case tool
            case pid
            case path
            case location
            case worktree
            case state
            case since
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.tool = try c.decode(String.self, forKey: .tool)
            self.pid = try c.decodeIfPresent(Int.self, forKey: .pid) ?? 0
            self.path = try c.decodeIfPresent(String.self, forKey: .path)
            self.location = try c.decodeIfPresent(String.self, forKey: .location)
            self.worktree = try c.decodeIfPresent(String.self, forKey: .worktree)
            self.state = try c.decodeIfPresent(String.self, forKey: .state) ?? "running"
            self.since = try c.decodeIfPresent(Date.self, forKey: .since)
        }
    }
}

/// `GET /v1/stats`. No CPU percentage: use `load[0] / cpus`.
public struct BoxStats: Codable, Sendable, Hashable {
    public let hostname: String
    public let uptimeS: Int64?
    public let cpus: Int
    public let load: [Double]?
    public let memory: BoxStats.Usage
    public let swap: BoxStats.Usage
    public let disks: [BoxStats.Disk]
    public let agents: [BoxStats.AgentProc]
    public let hooks: Bool

    public init(hostname: String = "", uptimeS: Int64? = nil, cpus: Int = 0, load: [Double]? = nil, memory: BoxStats.Usage = .init(), swap: BoxStats.Usage = .init(), disks: [BoxStats.Disk] = [], agents: [BoxStats.AgentProc] = [], hooks: Bool = false) {
        self.hostname = hostname
        self.uptimeS = uptimeS
        self.cpus = cpus
        self.load = load
        self.memory = memory
        self.swap = swap
        self.disks = disks
        self.agents = agents
        self.hooks = hooks
    }

    enum CodingKeys: String, CodingKey {
        case hostname
        case uptimeS = "uptime_s"
        case cpus
        case load
        case memory
        case swap
        case disks
        case agents
        case hooks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        self.uptimeS = try c.decodeIfPresent(Int64.self, forKey: .uptimeS)
        self.cpus = try c.decodeIfPresent(Int.self, forKey: .cpus) ?? 0
        self.load = try c.decodeIfPresent([Double].self, forKey: .load)
        self.memory = try c.decodeIfPresent(BoxStats.Usage.self, forKey: .memory) ?? .init()
        self.swap = try c.decodeIfPresent(BoxStats.Usage.self, forKey: .swap) ?? .init()
        self.disks = try c.decodeIfPresent([BoxStats.Disk].self, forKey: .disks) ?? []
        self.agents = try c.decodeIfPresent([BoxStats.AgentProc].self, forKey: .agents) ?? []
        self.hooks = try c.decodeIfPresent(Bool.self, forKey: .hooks) ?? false
    }
}

public struct DoctorCheck: Codable, Sendable, Hashable, Identifiable {
    public let area: String
    public let name: String
    public let status: String
    public let detail: String?
    public let fix: String?

    public init(area: String, name: String, status: String, detail: String? = nil, fix: String? = nil) {
        self.area = area
        self.name = name
        self.status = status
        self.detail = detail
        self.fix = fix
    }

    enum CodingKeys: String, CodingKey {
        case area
        case name
        case status
        case detail
        case fix
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.area = try c.decode(String.self, forKey: .area)
        self.name = try c.decode(String.self, forKey: .name)
        self.status = try c.decode(String.self, forKey: .status)
        self.detail = try c.decodeIfPresent(String.self, forKey: .detail)
        self.fix = try c.decodeIfPresent(String.self, forKey: .fix)
    }

    public var id: String { area + "/" + name }
}
