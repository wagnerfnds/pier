import Foundation

// Home widget data. What gh/git would tell on a laptop is read here on the box with one
// `exec` per widget. `location` is only the working directory the shell starts in (any location works).

extension PierBoxClient {
    /// Pull requests waiting on your review and yours, across every repo (one `gh api graphql`).
    public func homePullRequests(location: String) async throws -> HomePRs {
        let r = try await exec(location: location, command: HomeCommands.pullRequests, timeout: "45s")
        return try HomeCommands.parsePullRequests(exitCode: r.exitCode, output: r.output)
    }

    /// The latest failing run per branch and workflow, for each repo (`owner/name` slugs), in one shell.
    public func homeCIFailures(location: String, repos: [String]) async throws -> [CIFailure] {
        guard let cmd = HomeCommands.ciFailures(repos: repos) else { return [] }
        let r = try await exec(location: location, command: cmd, timeout: "60s")
        return try HomeCommands.parseCIFailures(exitCode: r.exitCode, output: r.output)
    }

    /// Commits and lines changed a day over the last 14 days, across the given repos' main checkouts, in one shell.
    public func homeGitActivity(location: String, projects: [HomeGitProject], now: Date = Date(), calendar: Calendar = .current) async throws -> GitActivity {
        guard let cmd = HomeCommands.gitActivity(projects: projects, utcOffset: calendar.timeZone.secondsFromGMT(for: now)) else { return GitActivity() }
        let r = try await exec(location: location, command: cmd, timeout: "60s")
        guard r.exitCode == 0 else { throw HomeError(problem: .other, message: r.output.split(separator: "\n").last.map(String.init) ?? "git exited with \(r.exitCode)") }
        return HomeCommands.parseGitActivity(output: r.output, projects: projects, now: now, calendar: calendar)
    }
}

extension BoxAPI {
    /// Dev servers listening in worktrees (`GET /v1/services`).
    public func services() async throws -> [BoxService] { try await get("/v1/services") }
}
