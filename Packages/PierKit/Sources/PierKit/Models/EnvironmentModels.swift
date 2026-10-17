// Codable models of the box's projects folder, its spaces and the projects' isolated environments (docs/API.md §2.9).
// Checked against Server/pierd/internal/box/settings.go and environment.go.
import Foundation

/// `GET`/`PUT /v1/settings`.
public struct BoxSettings: Codable, Sendable, Hashable {
    /// The folder every project lives under; nil: anywhere.
    public let projectsRoot: String?
    public let home: String
    public let spaces: [ProjectSpace]
    public let docker: DockerState
    /// What every setup agent on the box must keep to (docs/API.md §2.6.1): the box's own text, or its defaults
    /// (`prepareRulesDefault`); nil from a box without setup agents.
    public let prepareRules: String?
    public let prepareRulesDefault: Bool
    /// A worktree's preview gets a public link by itself; nil from a box without previews.
    public let autoShare: Bool?

    public init(projectsRoot: String? = nil, home: String = "", spaces: [ProjectSpace] = [], docker: DockerState = DockerState(),
                prepareRules: String? = nil, prepareRulesDefault: Bool = false, autoShare: Bool? = nil) {
        self.projectsRoot = projectsRoot; self.home = home; self.spaces = spaces; self.docker = docker
        self.prepareRules = prepareRules; self.prepareRulesDefault = prepareRulesDefault; self.autoShare = autoShare
    }

    enum CodingKeys: String, CodingKey {
        case projectsRoot = "projects_root", home, spaces, docker
        case prepareRules = "prepare_rules", prepareRulesDefault = "prepare_rules_default", autoShare = "auto_share"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let root = try c.decodeIfPresent(String.self, forKey: .projectsRoot)
        projectsRoot = root?.isEmpty == true ? nil : root
        home = try c.decodeIfPresent(String.self, forKey: .home) ?? ""
        spaces = try c.decodeIfPresent([ProjectSpace].self, forKey: .spaces) ?? []
        docker = try c.decodeIfPresent(DockerState.self, forKey: .docker) ?? DockerState()
        prepareRules = try c.decodeIfPresent(String.self, forKey: .prepareRules)
        prepareRulesDefault = try c.decodeIfPresent(Bool.self, forKey: .prepareRulesDefault) ?? false
        autoShare = try c.decodeIfPresent(Bool.self, forKey: .autoShare)
    }
}

/// A folder of projects under the projects folder.
public struct ProjectSpace: Codable, Sendable, Hashable, Identifiable {
    public let name: String
    public let path: String
    public let projects: Int
    public var id: String { name }
    public init(name: String, path: String = "", projects: Int = 0) { self.name = name; self.path = path; self.projects = projects }

    enum CodingKeys: String, CodingKey { case name, path, projects }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        projects = try c.decodeIfPresent(Int.self, forKey: .projects) ?? 0
    }
}

public struct DockerState: Codable, Sendable, Hashable {
    public let available: Bool
    public let version: String?
    public let error: String?
    public init(available: Bool = false, version: String? = nil, error: String? = nil) {
        self.available = available; self.version = version; self.error = error
    }
    enum CodingKeys: String, CodingKey { case available, version, error }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = try c.decodeIfPresent(Bool.self, forKey: .available) ?? false
        version = try c.decodeIfPresent(String.self, forKey: .version)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

/// A project's isolated environment: the runtime its programs run in, its service containers, its own compose file.
public struct ProjectEnvironment: Codable, Sendable, Hashable {
    public var runtime: EnvRuntime?
    public var containers: [EnvContainer]
    public var compose: Bool

    public init(runtime: EnvRuntime? = nil, containers: [EnvContainer] = [], compose: Bool = false) {
        self.runtime = runtime; self.containers = containers; self.compose = compose
    }
    public var isEmpty: Bool { runtime == nil && containers.isEmpty && !compose }

    enum CodingKeys: String, CodingKey { case runtime, containers, compose }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runtime = try c.decodeIfPresent(EnvRuntime.self, forKey: .runtime)
        containers = try c.decodeIfPresent([EnvContainer].self, forKey: .containers) ?? []
        compose = try c.decodeIfPresent(Bool.self, forKey: .compose) ?? false
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(runtime, forKey: .runtime)
        try c.encode(containers, forKey: .containers)
        if compose { try c.encode(true, forKey: .compose) }
    }
}

public struct EnvRuntime: Codable, Sendable, Hashable {
    /// "php:8.4", "node:22", "python:3.12", "ruby:3.3", "go:1.23".
    public var preset: String?
    public var image: String?
    public var projectDockerfile: Bool
    public var commands: [String]

    public init(preset: String? = nil, image: String? = nil, projectDockerfile: Bool = false, commands: [String] = []) {
        self.preset = preset; self.image = image; self.projectDockerfile = projectDockerfile; self.commands = commands
    }

    enum CodingKeys: String, CodingKey { case preset, image, projectDockerfile = "project_dockerfile", commands }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preset = try c.decodeIfPresent(String.self, forKey: .preset)
        image = try c.decodeIfPresent(String.self, forKey: .image)
        projectDockerfile = try c.decodeIfPresent(Bool.self, forKey: .projectDockerfile) ?? false
        commands = try c.decodeIfPresent([String].self, forKey: .commands) ?? []
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(preset, forKey: .preset)
        try c.encodeIfPresent(image, forKey: .image)
        if projectDockerfile { try c.encode(true, forKey: .projectDockerfile) }
        if !commands.isEmpty { try c.encode(commands, forKey: .commands) }
    }
}

public struct EnvContainer: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var image: String
    public var port: Int?
    public var env: [String: String]?
    public var id: String { name }
    public init(name: String, image: String, port: Int? = nil, env: [String: String]? = nil) {
        self.name = name; self.image = image; self.port = port; self.env = env
    }
}

/// `GET`/`PUT /v1/locations/{l}/environment`.
public struct EnvironmentView: Codable, Sendable, Hashable {
    public struct Status: Codable, Sendable, Hashable {
        public struct Container: Codable, Sendable, Hashable, Identifiable {
            public let name: String
            public let image: String
            public let hostPort: Int?
            public let state: String
            public let unit: String
            public var id: String { name }
            public var isRunning: Bool { state == "running" }
            public init(name: String, image: String, hostPort: Int? = nil, state: String = "stopped", unit: String = "") {
                self.name = name; self.image = image; self.hostPort = hostPort; self.state = state; self.unit = unit
            }
            enum CodingKeys: String, CodingKey { case name, image, hostPort = "host_port", state, unit }
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = try c.decode(String.self, forKey: .name)
                image = try c.decodeIfPresent(String.self, forKey: .image) ?? ""
                hostPort = try c.decodeIfPresent(Int.self, forKey: .hostPort)
                state = try c.decodeIfPresent(String.self, forKey: .state) ?? "stopped"
                unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
            }
        }
        /// "none", "building", "ready", "failed".
        public let state: String
        public let error: String?
        public let image: String?
        public let commands: [String]
        public let containers: [Container]
        public let variables: [String]
        public let log: String?

        public init(state: String = "none", error: String? = nil, image: String? = nil, commands: [String] = [], containers: [Container] = [],
                    variables: [String] = [], log: String? = nil) {
            self.state = state; self.error = error; self.image = image; self.commands = commands; self.containers = containers
            self.variables = variables; self.log = log
        }
        enum CodingKeys: String, CodingKey { case state, error, image, commands, containers, variables, log }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            state = try c.decodeIfPresent(String.self, forKey: .state) ?? "none"
            error = try c.decodeIfPresent(String.self, forKey: .error)
            image = try c.decodeIfPresent(String.self, forKey: .image)
            commands = try c.decodeIfPresent([String].self, forKey: .commands) ?? []
            containers = try c.decodeIfPresent([Container].self, forKey: .containers) ?? []
            variables = try c.decodeIfPresent([String].self, forKey: .variables) ?? []
            log = try c.decodeIfPresent(String.self, forKey: .log)
        }
    }
    public struct ProjectFiles: Codable, Sendable, Hashable {
        public let dockerfile: Bool
        public let compose: Bool
        public init(dockerfile: Bool = false, compose: Bool = false) { self.dockerfile = dockerfile; self.compose = compose }
        enum CodingKeys: String, CodingKey { case dockerfile, compose }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            dockerfile = try c.decodeIfPresent(Bool.self, forKey: .dockerfile) ?? false
            compose = try c.decodeIfPresent(Bool.self, forKey: .compose) ?? false
        }
    }
    public let environment: ProjectEnvironment
    public let status: Status
    public let project: ProjectFiles
    public let docker: DockerState

    public var isBuilding: Bool { status.state == "building" }

    public init(environment: ProjectEnvironment = ProjectEnvironment(), status: Status = Status(), project: ProjectFiles = ProjectFiles(), docker: DockerState = DockerState()) {
        self.environment = environment; self.status = status; self.project = project; self.docker = docker
    }
    enum CodingKeys: String, CodingKey { case environment, status, project, docker }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        environment = try c.decodeIfPresent(ProjectEnvironment.self, forKey: .environment) ?? ProjectEnvironment()
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? Status()
        project = try c.decodeIfPresent(ProjectFiles.self, forKey: .project) ?? ProjectFiles()
        docker = try c.decodeIfPresent(DockerState.self, forKey: .docker) ?? DockerState()
    }
}
