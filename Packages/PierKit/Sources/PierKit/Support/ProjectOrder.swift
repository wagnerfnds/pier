import Foundation

/// How a group of projects in the sidebar is ordered: by hand (the person drags them), by name, or by the most recent
/// agent activity.
public enum ProjectSort: String, Codable, Sendable, CaseIterable {
    case manual, name, activity

    public init(from decoder: Decoder) throws {
        self = ProjectSort(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .manual
    }
}

/// The order of the sidebar's groups (projects in a section, sections among themselves). Pure over keys, so the
/// sidebar, the Projects tab and the tests agree.
public enum ProjectOrder {
    /// `keys` in display order. `manual` is the saved order (keys missing from it follow, by name); `name` gives the name
    /// shown for a key; `activity` the last time an agent did something there (nil: never; those follow, by name).
    public static func ordered(_ keys: [String], sort: ProjectSort, manual: [String] = [], name: (String) -> String,
                               activity: (String) -> Date? = { _ in nil }) -> [String] {
        func byName(_ a: String, _ b: String) -> Bool {
            let r = name(a).localizedStandardCompare(name(b))
            return r == .orderedSame ? a < b : r == .orderedAscending
        }
        switch sort {
        case .name:
            return keys.sorted(by: byName)
        case .activity:
            let at = Dictionary(keys.map { ($0, activity($0)) }, uniquingKeysWith: { a, _ in a })
            return keys.sorted { a, b in
                switch (at[a] ?? nil, at[b] ?? nil) {
                case let (x?, y?) where x != y: return x > y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return byName(a, b)
                }
            }
        case .manual:
            let rank = Dictionary(manual.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            return keys.sorted { a, b in
                switch (rank[a], rank[b]) {
                case let (x?, y?): return x < y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return byName(a, b)
                }
            }
        }
    }

    /// `list` after moving `item` right before `target` (nil: to the end). An item that was not in the list is inserted;
    /// a target that is not there means the end. Dropping an item on itself changes nothing.
    public static func moving<T: Equatable>(_ item: T, before target: T?, in list: [T]) -> [T] {
        guard item != target else { return list }
        var out = list.filter { $0 != item }
        let at = target.flatMap { t in out.firstIndex(of: t) } ?? out.endIndex
        out.insert(item, at: at)
        return out
    }

    /// `list` after moving `item` right after `target` (to the end when `target` is not in it). Dropping an item on
    /// itself changes nothing.
    public static func moving<T: Equatable>(_ item: T, after target: T, in list: [T]) -> [T] {
        guard item != target else { return list }
        guard let i = list.firstIndex(of: target) else { return moving(item, before: nil, in: list) }
        let next = list[(i + 1)...].first { $0 != item }
        return moving(item, before: next, in: list)
    }
}
