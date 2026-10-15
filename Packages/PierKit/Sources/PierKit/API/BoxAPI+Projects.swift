import Foundation

// Projects coming onto and leaving the box (capability `projects`, docs/API.md §2.8).

extension BoxAPI {
    /// The repositories of the GitHub account gh is signed in to on the box, or of `owner` (one of its organisations).
    /// `BoxError.code` is `gh_missing` or `gh_auth` when the box cannot ask GitHub.
    public func gitHubRepos(owner: String? = nil) async throws -> GitHubRepos {
        try await get(Self.url("/v1/github/repos", [("owner", owner)]))
    }

    /// Clone a repository onto the box in the background; follow it with `clones()` (or the `clone.*` events).
    public func clone(_ req: CloneRequest) async throws -> ProjectClone {
        try decode(try await call(.post, "/v1/clones", body: req).data)
    }

    /// The clones of the last hour, newest first.
    public func clones() async throws -> [ProjectClone] { try await get("/v1/clones") }

    /// Forget a finished or failed clone.
    public func forgetClone(id: String) async throws {
        _ = try await call(.delete, "/v1/clones/\(Self.seg(id))")
    }

    /// What a project takes on the disk and what removing it would lose.
    public func projectDisk(location: String) async throws -> ProjectDisk {
        try await get("/v1/locations/\(Self.seg(location))/disk")
    }

    /// Delete a project's repository and worktrees from the disk and forget it. Without `force` the box refuses
    /// (409, `unsaved_work`) while it has uncommitted changes, commits no remote has, or stashes.
    public func purgeProject(location: String, force: Bool) async throws -> ProjectPurge {
        let path = Self.url("/v1/locations/\(Self.seg(location))", [("purge", "1"), ("force", force ? "1" : nil)])
        return try decode(try await call(.delete, path).data)
    }

    /// A worktree's services with their commands (`WorktreeServiceDetail`).
    public func worktreeServiceDetails(location: String, worktree: String) async throws -> [WorktreeServiceDetail] {
        try await get("/v1/locations/\(Self.seg(location))/worktrees/\(Self.seg(worktree))/services")
    }

    /// How the worktree's preparation (setup script, autostart services) stands. Capability `prepare`.
    public func prepareStatus(location: String, worktree: String) async throws -> PrepareStatus {
        try await get("/v1/locations/\(Self.seg(location))/worktrees/\(Self.seg(worktree))/prepare")
    }

    /// Prepare the worktree now, in the background (again, for one already prepared): answers `running`; 409 while a
    /// preparation of it still runs.
    public func prepare(location: String, worktree: String) async throws -> PrepareStatus {
        try decode(try await call(.post, "/v1/locations/\(Self.seg(location))/worktrees/\(Self.seg(worktree))/prepare").data)
    }
}

// The box's projects folder, its spaces and the projects' environments (capability `environments`, docs/API.md §2.9).

extension BoxAPI {
    public func settings() async throws -> BoxSettings { try await get("/v1/settings") }

    /// Set the folder every project lives under ("" clears it: anywhere again).
    public func setProjectsRoot(_ path: String) async throws -> BoxSettings {
        struct Body: Encodable { let projects_root: String }
        return try decode(try await call(.put, "/v1/settings", body: Body(projects_root: path)).data)
    }

    public func addSpace(name: String) async throws -> ProjectSpace {
        struct Body: Encodable { let name: String }
        return try decode(try await call(.post, "/v1/spaces", body: Body(name: name)).data)
    }

    /// Delete a space. With projects in it the box refuses (409 `space_not_empty`) unless `purge`, which removes them from
    /// the disk with it (409 `unsaved_work` for work no remote has, unless `force`). Its projects never move out of it.
    /// `deleteFiles` also deletes what in it is no project's (409 `space_has_files` without it).
    public func removeSpace(name: String, purge: Bool, force: Bool, deleteFiles: Bool = false) async throws -> ProjectPurge {
        let path = Self.url("/v1/spaces/\(Self.seg(name))", [("purge", purge ? "1" : nil), ("force", force ? "1" : nil), ("delete_files", deleteFiles ? "1" : nil)])
        return try decode(try await call(.delete, path).data)
    }

    public func environment(location: String) async throws -> EnvironmentView {
        try await get("/v1/locations/\(Self.seg(location))/environment")
    }

    /// Save a project's environment; the box builds and starts it in the background (`status.state` "building").
    public func setEnvironment(location: String, _ env: ProjectEnvironment) async throws -> EnvironmentView {
        try decode(try await call(.put, "/v1/locations/\(Self.seg(location))/environment", body: env).data)
    }
}

// Accounts and limits, the box's variables and skills, public links (capabilities `accounts`, `box.env`, `shares`;
// docs/API.md §2.10–2.12).

extension BoxAPI {
    public func accounts() async throws -> [AgentAccount] { try await get("/v1/accounts") }

    public func addAccount(agent: String, name: String) async throws -> AgentAccount {
        struct Body: Encodable { let agent: String; let name: String }
        return try decode(try await call(.post, "/v1/accounts", body: Body(agent: agent, name: name)).data)
    }

    public func renameAccount(id: String, name: String) async throws -> AgentAccount {
        struct Body: Encodable { let name: String }
        return try decode(try await call(.patch, "/v1/accounts/\(Self.seg(id))", body: Body(name: name)).data)
    }

    /// Make an account the box's default for its agent.
    public func makeDefaultAccount(id: String) async throws -> AgentAccount {
        struct Body: Encodable { let `default` = true }
        return try decode(try await call(.patch, "/v1/accounts/\(Self.seg(id))", body: Body()).data)
    }

    public func removeAccount(id: String) async throws {
        _ = try await call(.delete, "/v1/accounts/\(Self.seg(id))")
    }

    /// A terminal on the account's folder where the person signs in (open it as a session).
    public func loginAccount(id: String) async throws -> Session {
        try decode(try await call(.post, "/v1/accounts/\(Self.seg(id))/login").data)
    }

    /// Put pierd's status line in the Claude accounts that lack it, so their limits can be read.
    public func enableLimits() async throws {
        _ = try await call(.post, "/v1/limits/enable")
    }

    /// Which account each agent uses in a project (`[agent: id]`, "" for the box's default).
    public func setProjectAccounts(location: String, _ choice: [String: String]) async throws -> Location {
        try decode(try await call(.put, "/v1/locations/\(Self.seg(location))/accounts", body: choice).data)
    }

    public func boxVariables() async throws -> BoxVariables { try await get("/v1/env") }

    public func setBoxVariables(_ v: BoxVariables) async throws -> BoxVariables {
        try decode(try await call(.put, "/v1/env", body: v).data)
    }

    public func skills() async throws -> [BoxSkill] { try await get("/v1/skills") }

    public func setSkill(id: String, installed: Bool) async throws -> [BoxSkill] {
        try decode(try await call(installed ? .put : .delete, "/v1/skills/\(Self.seg(id))").data)
    }

    public func publicLinks() async throws -> [PublicLink] { try await get("/v1/shares") }

    /// Publish one of a worktree's ports at a public URL for `hours` (24 by default, at most 168).
    public func createPublicLink(location: String, worktree: String, port: Int, hours: Int? = nil) async throws -> PublicLink {
        struct Body: Encodable { let location: String; let worktree: String; let port: Int; let hours: Int? }
        return try decode(try await call(.post, "/v1/shares", body: Body(location: location, worktree: worktree, port: port, hours: hours)).data)
    }

    public func removePublicLink(name: String) async throws {
        _ = try await call(.delete, "/v1/shares/\(Self.seg(name))")
    }
}
