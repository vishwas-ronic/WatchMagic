import SwiftUI
import WatchMagicKit

struct ConnectView: View {
    @EnvironmentObject private var store: ConfigStore

    @State private var urlText = ""
    @State private var tokenText = ""
    @State private var didLoad = false

    @State private var testing = false
    @State private var testResult: Result<String, Error>?
    @State private var importing = false
    @State private var importError: String?
    @State private var areaWarning: String?
    @State private var formError: String?

    private var tokenIsSaved: Bool {
        store.hasToken && tokenText.trimmingCharacters(in: .whitespacesAndNewlines) == store.token
    }

    var body: some View {
        Form {
            Section {
                TextField("http://homeassistant.local:8123", text: $urlText)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Long-lived access token", text: $tokenText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if tokenIsSaved {
                    Label("Token saved in Keychain", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if !tokenText.isEmpty {
                    Label("Not saved yet — tap Save or Test", systemImage: "lock.open")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let formError {
                    Text(formError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Home Assistant")
            } footer: {
                Text("Create a token in Home Assistant under Profile → Security → Long-lived access tokens. It is stored only in the Keychain and synced to your watch.")
            }

            Section {
                HStack {
                    Button("Save") { _ = saveCredentials() }
                    Spacer()
                    Button {
                        Task { await test() }
                    } label: {
                        if testing { ProgressView() } else { Text("Test") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(testing)
                }
                .buttonStyle(.bordered)
                if let testResult {
                    switch testResult {
                    case .success(let message):
                        Label("Connected: \(message)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failure(let error):
                        Label(Self.message(for: error), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }

            Section {
                Button {
                    Task { await runImport() }
                } label: {
                    HStack {
                        Label("Import from Home Assistant", systemImage: "square.and.arrow.down")
                        Spacer()
                        if importing { ProgressView() }
                    }
                }
                .disabled(importing || !store.hasToken)
                if let importError {
                    Text(importError).font(.caption).foregroundStyle(.red)
                }
                if let cache = store.importCache {
                    Text("Last import \(cache.fetchedAt.formatted(date: .abbreviated, time: .shortened)): \(cache.states.count) entities, \(cache.areas.count) areas")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if !store.hasToken { Text("Save a token first.") }
            }

            if let cache = store.importCache {
                suggestedRooms(cache)
                entitiesSection(cache)
            }
        }
        .navigationTitle("Connect")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            urlText = store.config.haURL.absoluteString
            tokenText = store.token
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func suggestedRooms(_ cache: HAImportCache) -> some View {
        Section {
            if cache.areas.isEmpty {
                Text(areaWarning ?? "No areas found in Home Assistant.")
                    .foregroundStyle(.secondary)
            }
            ForEach(cache.areas) { area in
                let count = area.entityIDs.count
                let existing = store.room(forArea: area.id)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(NameCleaner.cleanRoomName(area.name))
                        Text(count == 0 ? "No lights, fans or switches" : "\(count) device\(count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if existing != nil {
                        Label("Added", systemImage: "checkmark")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else if count > 0 {
                        Button("Add room") { store.importArea(area) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .opacity(count == 0 && existing == nil ? 0.45 : 1)
            }
        } header: {
            Text("Suggested rooms from Home Assistant")
        } footer: {
            if let areaWarning, !cache.areas.isEmpty { Text(areaWarning) }
        }
    }

    @ViewBuilder
    private func entitiesSection(_ cache: HAImportCache) -> some View {
        Section {
            if cache.states.isEmpty {
                Text("No light, fan or switch entities found.").foregroundStyle(.secondary)
            }
            ForEach(cache.states) { state in
                EntityRow(state: state)
            }
        } header: {
            Text("Lights, fans & switches (\(cache.states.count))")
        }
    }

    // MARK: Actions

    /// Validates and stores URL + token. Returns false on validation error.
    private func saveCredentials() -> Bool {
        formError = nil
        let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else {
            formError = "Enter a URL like http://homeassistant.local:8123"
            return false
        }
        store.setHAURL(url)
        do {
            try store.setToken(tokenText)
        } catch {
            formError = error.localizedDescription
            return false
        }
        return true
    }

    private func test() async {
        guard saveCredentials() else { return }
        guard let client = store.makeClient() else {
            formError = "Enter a long-lived access token"
            testResult = nil
            return
        }
        testing = true
        defer { testing = false }
        do {
            testResult = .success(try await client.ping())
        } catch {
            testResult = .failure(error)
        }
    }

    private func runImport() async {
        guard saveCredentials() else { return }
        importing = true
        importError = nil
        defer { importing = false }
        do {
            areaWarning = try await store.refreshImport()
        } catch {
            importError = Self.message(for: error)
        }
    }

    static func message(for error: Error) -> String {
        HAError.from(error).errorDescription ?? error.localizedDescription
    }
}

struct EntityRow: View {
    let state: EntityState
    /// Cleaned display name; defaults to the HA friendly name.
    var title: String? = nil

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? state.displayName)
                Text(state.entityID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(state.state)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(state.isOn ? Color.green : Color.secondary)
                Text(state.domain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
