import CloudKit
import CryptoKit
import Foundation
import PierKit
import os

/// Tells the person's iPhone and iPad what needs them when a box sends no push of its own (a pierd with no APNs key:
/// every box `pierd setup` makes, with the App Store app). The Mac app, which follows every box, saves an alert in the
/// person's private iCloud database; CloudKit pushes it to their other devices, which subscribe to those records. No
/// server and no key: only the person's iCloud, and Pier open on a Mac.
///
/// The record's name is the alert's own (box, session, state, since), so two Macs following one box save it once and
/// the phone rings once; a Mac deletes what it saved after an hour. On the phone the notification service extension
/// turns the record's fields into the usual notification (CloudAlertPayload): the title and body, the choices as
/// buttons, a tap opening the session, an answer going to the box like any other.
@MainActor final class CloudAlerts {
    static let shared = CloudAlerts()
    /// The Mac's switch in Ajustes (on by default).
    static let enabledKey = "cloudAlerts.enabled"
    /// What this Mac saved, by record name, with when: deleted after `keep`.
    private static let savedKey = "cloudAlerts.saved"
    private static let subscribedKey = "cloudAlerts.subscribed.v1"
    private static let keep: TimeInterval = 3600
    private static let pushCheck: TimeInterval = 600

    private let log = Logger(subsystem: Shared.appBundleID, category: "cloud-alerts")
    /// Box name → whether its pierd sends push itself, and when that was checked.
    private var pushes: [String: (sends: Bool, at: Date)] = [:]
    private var subscribing = false
    private lazy var container = CKContainer(identifier: "iCloud." + Shared.appBundleID)
    private var database: CKDatabase { container.privateCloudDatabase }

    var enabled: Bool {
        get { !Shared.isLocalTest && (UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    // MARK: Mac: forwarding

    /// A transition on a box this Mac follows: the alert for the person's other devices, unless the box pushes itself,
    /// or the person turned this (or that kind of notification) off.
    func forward(box: BoxRecord, client: any PierBoxClient, identity: PierIdentity?, session: Session, to state: AgentState?,
                 showBox: Bool) async {
        guard enabled, state == .waiting || state == .finished else { return }
        let events = PushStateStore.load().events
        if (state == .waiting && !events.waiting) || (state == .finished && !events.finished) { return }
        guard let (title, body) = Notifications.text(box: box.name, session: session, to: state, showBox: showBox) else { return }
        guard await !sendsPush(box, identity: identity) else { return }
        let options = state == .waiting ? await ChoiceOptions.fetch(client: client, session: session) : nil
        let id = CKRecord.ID(recordName: Self.recordName(box: box.name, session: session.name, state: state, since: session.stateSince))
        let r = CKRecord(recordType: CloudAlertPayload.recordType, recordID: id)
        r["title"] = title
        r["body"] = body
        r[CloudAlertPayload.infoKey] = CloudAlertPayload.encode(.init(
            box: box.name, session: session.name, location: session.location,
            category: NotificationCategoryID.category(state: state, ask: session.ask),
            options: (options?.count ?? 0) >= 2 ? options : nil))
        do {
            _ = try await database.save(r)
            remember(id.recordName)
            log.info("saved alert \(id.recordName, privacy: .public) for \(box.name, privacy: .public)/\(session.name, privacy: .public)")
        } catch let e as CKError where e.code == .serverRecordChanged {
            // Another Mac saved this one first: the phone rang once.
            log.info("alert \(id.recordName, privacy: .public) was saved already")
        } catch {
            log.error("saving an alert: \(error.localizedDescription, privacy: .public)")
        }
        await sweep()
    }

    /// Whether the box's pierd pushes to this app by itself (its push routes answer, for this app's bundle id: a box set up
    /// for a build of someone's own pushes to that one), checked every few minutes. Its pushes reach the phone directly;
    /// an alert from here would ring it twice.
    private func sendsPush(_ box: BoxRecord, identity: PierIdentity?) async -> Bool {
        if let known = pushes[box.name], Date().timeIntervalSince(known.at) < Self.pushCheck { return known.sends }
        guard let identity else { return false }
        let client = PushClient(box: box, identity: identity)
        let info = try? await PushRegistrar.deadline(.seconds(4)) { try await client.info() }
        let sends = info?.bundleID == Shared.appBundleID
        pushes[box.name] = (sends, Date())
        return sends
    }

    static func recordName(box: String, session: String, state: AgentState?, since: Date?) -> String {
        let key = [box, session, state?.rawValue ?? "", String(Int(since?.timeIntervalSince1970 ?? 0))].joined(separator: "\u{1F}")
        return "alert-" + SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func remember(_ name: String) {
        var saved = UserDefaults.standard.dictionary(forKey: Self.savedKey) as? [String: Double] ?? [:]
        saved[name] = Date().timeIntervalSince1970
        UserDefaults.standard.set(saved, forKey: Self.savedKey)
    }

    /// Deletes the alerts this Mac saved more than an hour ago (they have long been delivered).
    private func sweep() async {
        let saved = UserDefaults.standard.dictionary(forKey: Self.savedKey) as? [String: Double] ?? [:]
        let cutoff = Date().addingTimeInterval(-Self.keep).timeIntervalSince1970
        let old = saved.filter { $0.value < cutoff }.map(\.key)
        guard !old.isEmpty else { return }
        do {
            _ = try await database.modifyRecords(saving: [], deleting: old.map { CKRecord.ID(recordName: $0) })
            var left = saved
            for k in old { left[k] = nil }
            UserDefaults.standard.set(left, forKey: Self.savedKey)
        } catch {
            log.error("deleting old alerts: \(error.localizedDescription, privacy: .public)")
        }
    }

    #if DEBUG
    /// The subscriptions in the person's private database, every device's (the phone's shows up from the Mac), in the
    /// log (`-cloudAlertsDiagnose 1`).
    func diagnose() async {
        guard !Shared.isLocalTest else { return }
        do {
            let subs = try await database.allSubscriptions()
            log.info("subscriptions: \(subs.map(\.subscriptionID).joined(separator: ", "), privacy: .public)")
        } catch {
            log.error("diagnose: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Saves a test alert the person's iPhone and iPad should ring for (`-cloudAlertsTest 1`), as a waiting agent with two
    /// choices; deleted with the rest after an hour.
    func sendTest() async {
        guard !Shared.isLocalTest else { return }
        let id = CKRecord.ID(recordName: "alert-test-\(Int(Date().timeIntervalSince1970))")
        let r = CKRecord(recordType: CloudAlertPayload.recordType, recordID: id)
        r["title"] = "Pier · teste"
        r["body"] = "Aviso do Mac pelo iCloud: ele chegou?"
        r[CloudAlertPayload.infoKey] = CloudAlertPayload.encode(.init(box: "pier-test", session: "icloud-test", options: ["Sim", "Não"]))
        do {
            _ = try await database.save(r)
            remember(id.recordName)
            log.info("test alert saved: \(id.recordName, privacy: .public)")
        } catch {
            log.error("test alert: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Saves an alert with every field and deletes it (`-cloudAlertsSeed 1`): CloudKit's development environment then
    /// knows the record type and all its fields, the schema to deploy to production. A device already subscribed gets it.
    func seedSchema() async {
        guard !Shared.isLocalTest else { return }
        let r = CKRecord(recordType: CloudAlertPayload.recordType, recordID: CKRecord.ID(recordName: "alert-schema-seed"))
        r["title"] = "Pier"
        r["body"] = "schema"
        r[CloudAlertPayload.infoKey] = CloudAlertPayload.encode(.init(box: "box", session: "session", location: "location",
                                                                      category: "category", options: ["one", "two"]))
        do {
            _ = try await database.modifyRecords(saving: [r], deleting: [], savePolicy: .allKeys)
            _ = try await database.modifyRecords(saving: [], deleting: [r.recordID])
            log.info("schema seeded")
        } catch {
            log.error("seeding the schema: \(error.localizedDescription, privacy: .public)")
        }
    }
    #endif

    // MARK: iPhone, iPad: the subscription

    /// Subscribes this device to the alerts a Mac saves, once (CloudKit keeps the subscription with the person's iCloud).
    /// Tried again on each foreground until it works: no iCloud account yet, or no Mac has saved an alert yet (CloudKit
    /// knows no PierAlert records then, in the development environment).
    func subscribeIfNeeded() async {
        guard !Shared.isLocalTest else { return }
        guard !subscribing, !UserDefaults.standard.bool(forKey: Self.subscribedKey) else { return }
        subscribing = true
        defer { subscribing = false }
        guard (try? await container.accountStatus()) == .available else {
            log.info("no iCloud account: no alerts from a Mac")
            return
        }
        let s = CKQuerySubscription(recordType: CloudAlertPayload.recordType, predicate: NSPredicate(value: true),
                                    subscriptionID: CloudAlertPayload.subscriptionID, options: [.firesOnRecordCreation])
        let n = CKSubscription.NotificationInfo()
        // The record's own words; the service extension also sets them, with the session and the choices.
        n.titleLocalizationKey = "%1$@"
        n.titleLocalizationArgs = ["title"]
        n.alertLocalizationKey = "%1$@"
        n.alertLocalizationArgs = ["body"]
        n.soundName = "default"
        n.shouldSendMutableContent = true
        n.desiredKeys = [CloudAlertPayload.infoKey]
        s.notificationInfo = n
        do {
            _ = try await database.save(s)
            UserDefaults.standard.set(true, forKey: Self.subscribedKey)
            log.info("subscribed to the Mac's alerts")
        } catch {
            log.error("subscribing: \(error.localizedDescription, privacy: .public)")
            // CloudKit asked to wait (a throttle, the service busy): try again then, while the app still runs.
            if let wait = (error as? CKError)?.retryAfterSeconds, wait < 1800 {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(wait + 1))
                    await self?.subscribeIfNeeded()
                }
            }
        }
    }
}
