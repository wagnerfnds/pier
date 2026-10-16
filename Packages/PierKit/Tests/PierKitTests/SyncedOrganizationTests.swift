import Foundation
import Testing
@testable import PierKit

struct SyncedOrganizationTests {
    typealias Org = SyncedOrganization
    let a = UUID(), b = UUID(), c = UUID()

    var mac: Org {
        Org(sections: [.init(id: a, name: "Residente", projects: ["pier/api", "pier/site"], sort: .manual),
                       .init(id: b, name: "Brokerfy", projects: ["pier/brokerfy"], sort: .name)],
            renames: ["pier/api": "API"], hidden: ["pier/old"], unsortedOrder: ["pier/x"], expanded: ["unsorted": false],
            updatedAt: Date(timeIntervalSince1970: 100))
    }

    @Test func aDeviceThatSyncedTakesTheNewerCopyWhole() {
        var phone = mac
        phone.sections.removeLast()
        phone.updatedAt = Date(timeIntervalSince1970: 50)
        #expect(Org.resolve(local: phone, remote: mac, synced: true) == mac)
        phone.updatedAt = Date(timeIntervalSince1970: 200)
        #expect(Org.resolve(local: phone, remote: mac, synced: true) == phone, "a newer local change stays (and goes up)")
        #expect(Org.resolve(local: phone, remote: nil, synced: true) == phone)
        #expect(Org.resolve(local: Org(), remote: mac, synced: false) == mac, "an empty device takes iCloud's")
    }

    @Test func theFirstSyncMergesSoNoSectionIsLost() {
        let phone = Org(sections: [.init(id: c, name: "residente", projects: ["pier/api", "pier/crm"], sort: .manual),
                                   .init(id: UUID(), name: "Pessoal", projects: ["pier/site", "pier/blog"], sort: .activity)],
                        renames: ["pier/api": "api (phone)", "pier/crm": "CRM"], hidden: ["pier/tmp"], unsortedOrder: ["pier/y", "pier/x"],
                        updatedAt: Date(timeIntervalSince1970: 300))
        let m = Org.resolve(local: phone, remote: mac, synced: false)
        #expect(m.sections.map(\.name) == ["Residente", "Brokerfy", "Pessoal"])
        #expect(m.sections[0].id == a, "iCloud's section keeps its id (the sidebar's folds are keyed by it)")
        #expect(m.sections[0].projects == ["pier/api", "pier/site", "pier/crm"], "same name (any case): its projects join")
        #expect(m.sections[2].projects == ["pier/blog"], "a project sits in one section only, iCloud's place wins")
        #expect(m.renames == ["pier/api": "API", "pier/crm": "CRM"])
        #expect(m.hidden == ["pier/old", "pier/tmp"])
        #expect(m.unsortedOrder == ["pier/x", "pier/y"])
        #expect(m.expanded == ["unsorted": false])
        #expect(m.updatedAt == Date(timeIntervalSince1970: 300))
    }

    @Test func contentComparesWithoutTheTime() {
        var later = mac
        later.updatedAt = .now
        #expect(later.sameContent(as: mac))
        later.hidden.insert("pier/y")
        #expect(!later.sameContent(as: mac))
    }
}
