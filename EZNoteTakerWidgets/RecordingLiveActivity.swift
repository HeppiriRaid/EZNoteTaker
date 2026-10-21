import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct EZNoteTakerWidgets: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
    }
}

private let brick = Color(red: 0.90, green: 0.49, blue: 0.38)
private let recordRed = Color(red: 0.95, green: 0.27, blue: 0.24)

/// Lock-screen and Dynamic Island console for a class that is being recorded.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenConsole(context: context)
                .activityBackgroundTint(Color.black.opacity(0.82))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(RecordingLinks.recorder)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusBadge(isPaused: context.state.isPaused)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Label("\(context.state.photoCount)", systemImage: "camera.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    ElapsedText(state: context.state)
                        .font(.title2.weight(.semibold).monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        if !context.state.nowDiscussing.isEmpty {
                            Text(context.state.nowDiscussing).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                        }
                        ConsoleButtons(isPaused: context.state.isPaused)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.isPaused ? "pause.circle.fill" : "record.circle")
                    .foregroundStyle(context.state.isPaused ? .orange : recordRed)
            } compactTrailing: {
                ElapsedText(state: context.state)
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "mic.fill")
                    .foregroundStyle(context.state.isPaused ? .orange : recordRed)
            }
            .widgetURL(RecordingLinks.recorder)
        }
    }
}

private struct LockScreenConsole: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        let state = context.state
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                StatusBadge(isPaused: state.isPaused)
                Text(context.attributes.courseName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Spacer()
                ElapsedText(state: state)
                    .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.trailing)
            }

            HStack(spacing: 14) {
                Label("\(state.photoCount) photos", systemImage: "camera.fill")
                if let last = state.lastPhotoAt {
                    Label {
                        Text(last, style: .relative) + Text(" ago")
                    } icon: {
                        Image(systemName: "clock")
                    }
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(0.75))

            if !state.nowDiscussing.isEmpty {
                Label(state.nowDiscussing, systemImage: "building.columns.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(brick)
                    .lineLimit(1)
            }

            ConsoleButtons(isPaused: state.isPaused)
        }
        .padding(16)
    }
}

private struct StatusBadge: View {
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isPaused ? Color.orange : recordRed)
                .frame(width: 9, height: 9)
            Text(isPaused ? "PAUSED" : "REC")
                .font(.caption.weight(.heavy))
                .foregroundStyle(isPaused ? Color.orange : recordRed)
        }
    }
}

/// Live timer while recording (updates itself on the lock screen), frozen time while paused.
private struct ElapsedText: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        if state.isPaused {
            Text(ClockText.format(state.elapsed))
        } else {
            Text(state.timerStart, style: .timer)
        }
    }
}

private struct ConsoleButtons: View {
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Runs in the background app — no unlock needed.
            Button(intent: ToggleRecordingPauseIntent()) {
                Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(isPaused ? Color.green.opacity(0.35) : Color.white.opacity(0.18), in: Capsule())

            // The camera needs the phone unlocked: this opens the app straight to it (Face ID).
            Link(destination: RecordingLinks.camera) {
                Label("Photo", systemImage: "camera.fill")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(.black)
                    .background(Color.white, in: Capsule())
            }
        }
    }
}
