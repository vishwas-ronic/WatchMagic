import SwiftUI
import WatchMagicKit

/// Shown while the iPhone guides a gesture-training set: the watch only
/// records (and taps a cue every 2.5 s). Big text in case the user glances.
struct TrainingRecordingView: View {
    @EnvironmentObject private var engine: ControlEngine
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 6) {
            if let t = engine.training {
                Text(t.done ? t.phase : "Recording")
                    .font(.footnote)
                    .foregroundStyle(t.done ? Color.green : Color.red)
                Text(t.label.title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                if t.cueTotal > 0 {
                    Text("Cue \(t.cue) of \(t.cueTotal)")
                        .font(.title3.monospacedDigit())
                } else if !t.done {
                    Text("Move normally")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if t.done {
                    Button("Done") { dismiss() }
                } else {
                    Button("Stop", role: .destructive) { engine.cancelTraining() }
                }
            } else {
                Text("Start training on your iPhone:\nSettings → Train gestures")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }
        }
        .navigationTitle("Training")
        .onAppear { services.keepAlive() }
    }
}
