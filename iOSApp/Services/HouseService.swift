import Combine
import Foundation
import WatchMagicKit

/// Talks to Home Assistant's whole-house 3D model:
/// - loads `GET /local/house3d/house.json` (cached on disk, no secrets) so
///   rooms can be matched to spaces and aligned to the house frame;
/// - sends device / seat positions in the house frame with
///   `POST /api/states/sensor.watchmagic_layout` (`HouseLayout`).
///
/// It remembers which entity IDs / seat IDs it pushed last (UserDefaults; no
/// secrets) so items that lose their position — device removed, coordinates
/// cleared, room un-aligned — are deleted on HA. When a config change leaves
/// such items behind, it pushes the deletions automatically.
@MainActor
final class HouseService: ObservableObject {
    @Published private(set) var houseModel: HouseModel?
    @Published private(set) var loading = false
    @Published private(set) var loadError: String?
    @Published private(set) var pushing = false
    /// "Sent 7 devices, 1 seat to the 3D view" or the error.
    @Published private(set) var lastPushResult: String?
    @Published private(set) var lastPushFailed = false
    @Published private(set) var lastPushedAt: Date?

    private weak var store: ConfigStore?
    private var cancellable: AnyCancellable?
    private var autoPushTask: Task<Void, Never>?

    private static let entityKey = "layout.pushedEntityIDs"
    private static let seatKey = "layout.pushedSeatIDs"

    private var pushedEntityIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.entityKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: Self.entityKey) }
    }

    private var pushedSeatIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.seatKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: Self.seatKey) }
    }

    private static var cacheURL: URL {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return support.appendingPathComponent("WatchMagic", isDirectory: true).appendingPathComponent("house3d.json")
    }

    init(store: ConfigStore) {
        self.store = store
        if let data = try? Data(contentsOf: Self.cacheURL) {
            houseModel = try? HouseModel.fromJSON(data)
        }
        cancellable = store.$config
            .dropFirst()
            .sink { [weak self] config in self?.configChanged(config) }
    }

    /// The space a room is matched to, if the model is loaded and has it.
    func space(for room: Room) -> HouseModel.Space? {
        guard let id = room.houseSpaceID else { return nil }
        return houseModel?.space(id: id)
    }

    // MARK: - House model

    func refreshHouseModel() async {
        guard let store else { return }
        guard store.hasToken else {
            loadError = "Connect to Home Assistant first."
            return
        }
        loading = true
        defer { loading = false }
        // house.json is ~100 KB: allow more than the 3 s used for service calls.
        let client = HAClient(baseURL: store.config.haURL, token: store.token, timeout: 15)
        do {
            let model = try await client.houseModel()
            houseModel = model
            loadError = model.spaces.isEmpty ? "The house model has no spaces." : nil
            if let data = try? JSONEncoder().encode(model) {
                try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: Self.cacheURL, options: [.atomic])
            }
        } catch {
            loadError = HAError.from(error).errorDescription
        }
    }

    // MARK: - Push

    /// What a push would send now.
    func preview() -> HouseLayout.Build? {
        guard let store else { return nil }
        return HouseLayout.build(config: store.config, previousEntityIDs: pushedEntityIDs, previousSeatIDs: pushedSeatIDs)
    }

    /// Builds the layout for every aligned room and posts it. Returns the
    /// user-facing result (also published as `lastPushResult`).
    @discardableResult
    func push() async -> String {
        guard let store else { return "" }
        guard store.hasToken else { return finish("Connect to Home Assistant first.", failed: true) }
        let build = HouseLayout.build(config: store.config, previousEntityIDs: pushedEntityIDs, previousSeatIDs: pushedSeatIDs)
        guard !build.isEmpty else {
            let why = build.skipped.isEmpty
                ? "Nothing to send: align a room to the house (Place devices with camera → Align to house) first."
                : "Nothing valid to send · " + build.summary
            return finish(why, failed: true)
        }
        pushing = true
        defer { pushing = false }
        let client = HAClient(baseURL: store.config.haURL, token: store.token, timeout: 10)
        do {
            try await client.postLayout(try build.bodyData())
            pushedEntityIDs = build.sentEntityIDs
            pushedSeatIDs = build.sentSeatIDs
            lastPushedAt = Date()
            return finish(build.summary, failed: false)
        } catch {
            return finish("Couldn't send to Home Assistant: " + (HAError.from(error).errorDescription ?? "failed"), failed: true)
        }
    }

    /// Fire-and-forget push (after saving a placement).
    func pushInBackground() {
        Task { await push() }
    }

    private func finish(_ message: String, failed: Bool) -> String {
        lastPushResult = message
        lastPushFailed = failed
        return message
    }

    /// Items pushed before that no longer have a position → delete them on HA
    /// (debounced, only when something was pushed before).
    private func configChanged(_ config: AppConfig) {
        guard !pushedEntityIDs.isEmpty || !pushedSeatIDs.isEmpty else { return }
        let build = HouseLayout.build(config: config, previousEntityIDs: pushedEntityIDs, previousSeatIDs: pushedSeatIDs)
        guard !build.deletedEntityIDs.isEmpty || !build.deletedSeatIDs.isEmpty else { return }
        autoPushTask?.cancel()
        autoPushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self, !self.pushing else { return }
            await self.push()
        }
    }
}
