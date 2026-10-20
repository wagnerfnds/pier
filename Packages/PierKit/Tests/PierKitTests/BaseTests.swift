import Foundation
import Testing

@testable import PierKit

@Suite struct BaseTests {
    /// A project's base: its files (a dotenv file's keys, never values), the folders carried from the main checkout,
    /// the team's part and the recipe, each saying whose it is.
    @Test func baseDecodes() throws {
        let base = try Fixture.decode("base.json", as: ProjectBase.self)
        #expect(base.key == "octocat__shop" && !base.isEmpty && base.copiesShareBlocks)
        let env = try #require(base.files.first)
        #expect(env.path == ".env" && env.isEnv && env.isTeams && env.keys == ["APP_KEY", "DB_HOST", "DB_PASSWORD"] && env.added != nil)
        let auth = try #require(base.files.last)
        #expect(!auth.isEnv && !auth.isTeams && auth.size == 120)
        #expect(base.carry.map(\.path) == ["node_modules", "vendor", "frankenphp"])
        #expect(base.carry.map(\.from) == ["worktreeinclude", "team", "box"] && base.carry.last?.inMain == false)
        #expect(base.team?.published != nil && base.team?.error == nil)
        #expect(base.recipe?.from == "team" && base.recipe?.services == ["web"] && base.recipe?.setup?.contains("migrate") == true)
        #expect(base.warnings.count == 1)
    }

    @Test func emptyAndUnreadableBasesDecode() throws {
        let none = try Fixture.decode("base_none.json", as: ProjectBase.self)
        #expect(none.isEmpty && none.copy == nil && !none.copiesShareBlocks)
        let unreadable = try Fixture.decode("base_team_unreadable.json", as: ProjectBase.self)
        #expect(!unreadable.isEmpty && unreadable.team?.error?.contains("cannot be read") == true && unreadable.team?.published == nil)
        // A box that sends nothing but its key still decodes.
        let bare = try JSONDecoder.pier.decode(ProjectBase.self, from: Data(#"{"key":"x"}"#.utf8))
        #expect(bare.isEmpty && bare.warnings.isEmpty)
    }

    /// A running preparation says its step and how the base went in: what is in place, what was carried and how long
    /// it took, what failed.
    @Test func preparationCarriesTheBase() throws {
        let st = try Fixture.decode("prepare_running_step.json", as: PrepareStatus.self)
        #expect(st.state == .running && st.step == "setup" && st.hasAnything)
        let base = try #require(st.base)
        #expect(base.filesInPlace.map(\.path) == [".env", ".env.testing"])
        #expect(base.files[1].keys == ["DB_DATABASE"] && base.files[2].action == "skipped")
        #expect(base.carriedInPlace.map(\.path) == ["node_modules", "vendor"] && base.carriedMS == 2242)
        #expect(base.problems.map(\.path) == ["frankenphp"])
        // An older box sends neither; an empty base reads as none.
        let old = try Fixture.decode("prepare_skipped.json", as: PrepareStatus.self)
        #expect(old.step == nil && old.base == nil)
        let empty = try JSONDecoder.pier.decode(PrepareStatus.self, from: Data(#"{"state":"ready","base":{}}"#.utf8))
        #expect(empty.base == nil && !empty.hasAnything)
    }

    @Test func route() async throws {
        let t = MockTransport { _, _, _ in (200, try Fixture.data("base.json")) }
        let a = BoxAPI(transport: t, eventPolicy: EventStreamPolicy(jitter: 0))
        #expect(try await a.projectBase(location: "shop/x").files.count == 2)
        #expect(t.requests.map { "\($0.method) \($0.path)" } == ["GET /v1/locations/shop%2Fx/base"])
    }
}
