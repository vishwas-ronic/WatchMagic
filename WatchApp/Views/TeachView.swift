import SwiftUI
import WatchMagicKit

/// Teach mode (spec 1.2.4): list of current-room devices with calibration status.
struct TeachView: View {
    @EnvironmentObject private var engine: ControlEngine
    @EnvironmentObject private var sync: WatchSyncService

    var body: some View {
        List {
            if engine.roomDevices.isEmpty {
                Text(engine.room == nil ? "No current room — pick one on your iPhone" : "No devices in this room")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if engine.needsAlignment {
                Label("Teach one placed device to align this room", systemImage: "mappin.and.ellipse")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            ForEach(engine.roomDevices) { device in
                NavigationLink(value: Route.teachDevice(device.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if device.coordinates != nil {
                                Image(systemName: "mappin")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .accessibilityLabel("Placed")
                            }
                            Text(device.name)
                                .lineLimit(1)
                        }
                        Text(statusText(device))
                            .font(.caption2)
                            .foregroundStyle(device.calibrationStatus == .taught ? .green : .secondary)
                    }
                }
            }
        }
        .navigationTitle("Teach")
    }

    private func statusText(_ device: ControlledDevice) -> String {
        var s: String
        switch device.calibrationStatus {
        case .coordinatesOnly: s = engine.needsAlignment ? "Placed · teach to align" : "Placed"
        case .taught: s = device.coordinates != nil ? "Taught ✓ · placed" : "Taught ✓"
        case .notPlaced: s = "Not placed"
        }
        if sync.pendingTaughtIDs.contains(device.id) { s += " · syncing" }
        if engine.anchorDevice?.id == device.id { s += " · anchor" }
        return s
    }
}

/// Capture screen for one device: point, hold 1 s, three times.
struct TeachDeviceView: View {
    let deviceID: UUID

    @EnvironmentObject private var engine: ControlEngine
    @EnvironmentObject private var sync: WatchSyncService

    var body: some View {
        let device = engine.device(deviceID)
        let teach = engine.teach
        let active = teach.deviceID == deviceID

        ScrollView {
            VStack(spacing: 8) {
                Text(device?.name ?? "Unknown device")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if let device {
                    Text(device.calibrationStatus.displayName
                         + (sync.pendingTaughtIDs.contains(deviceID) ? " · syncing" : ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if active { captureStatus(teach, name: device?.name ?? "the device") }

                if active && teach.phase == .capturing {
                    Button("Cancel", role: .cancel) { engine.cancelTeach() }
                } else if let device {
                    Button(device.taughtVector == nil ? "Teach" : "Re-teach") {
                        engine.startTeach(deviceID: deviceID)
                    }
                    .tint(.blue)
                    if device.taughtVector != nil {
                        Button("Clear", role: .destructive) {
                            engine.clearTaught(deviceID: deviceID)
                        }
                    }
                }
            }
        }
        .navigationTitle("Teach")
        .onDisappear {
            if engine.teach.phase == .capturing { engine.cancelTeach() }
        }
    }

    @ViewBuilder
    private func captureStatus(_ teach: ControlEngine.TeachStatus, name: String) -> some View {
        switch teach.phase {
        case .capturing:
            VStack(spacing: 6) {
                Text(teach.needsReaim
                     ? (teach.samples == 0 ? "Raise your arm and point at \(name)" : "Lower your arm, then point at \(name) again")
                     : "Point at \(name) and hold steady 1 s")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                HStack(spacing: 6) {
                    ForEach(0..<TeachCapture.samplesNeeded, id: \.self) { i in
                        Image(systemName: i < teach.samples ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(i < teach.samples ? .green : .secondary)
                    }
                }
                ProgressView(value: teach.hold)
                    .tint(.blue)
            }
        case .saved:
            Text(teach.message ?? "Saved ✓").font(.footnote).foregroundStyle(.green)
        case .inconsistent:
            Text(teach.message ?? "Not consistent — retry").font(.footnote).foregroundStyle(.orange)
        case .blocked:
            Text(teach.message ?? "Heading not ready").font(.footnote).foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        case .idle:
            EmptyView()
        }
    }
}
