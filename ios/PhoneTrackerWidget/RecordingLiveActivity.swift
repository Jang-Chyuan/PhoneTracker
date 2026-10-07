import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct PhoneTrackerWidgetBundle: WidgetBundle {
  var body: some Widget { RecordingLiveActivity() }
}

private let blue = Color(red: 37 / 255, green: 99 / 255, blue: 235 / 255)
private let summary = "≤ 10 km/h 每 30 秒；> 10～20 每 5 秒；> 20 每秒保存"

struct RecordingLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
      HStack(spacing: 12) {
        Image(systemName: "location.fill").foregroundStyle(blue).font(.title2)
        VStack(alignment: .leading, spacing: 2) {
          Text("PhoneTracker 背景位置記錄").font(.headline)
          Text(summary).font(.caption).foregroundStyle(.secondary)
          Text(context.state.startedAt, style: .timer).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        Button(intent: StopRecordingIntent()) { Text("停止記錄").font(.subheadline.bold()) }
          .tint(blue)
      }
      .padding()
      .activityBackgroundTint(Color(.systemBackground).opacity(0.9))
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) { Image(systemName: "location.fill").foregroundStyle(blue) }
        DynamicIslandExpandedRegion(.center) { Text("PhoneTracker 記錄中").font(.headline) }
        DynamicIslandExpandedRegion(.trailing) {
          Text(context.state.startedAt, style: .timer).font(.caption.monospacedDigit()).frame(width: 56)
        }
        DynamicIslandExpandedRegion(.bottom) {
          Button(intent: StopRecordingIntent()) { Text("停止記錄") }.tint(blue)
        }
      } compactLeading: {
        Image(systemName: "location.fill").foregroundStyle(blue)
      } compactTrailing: {
        Text(context.state.startedAt, style: .timer).font(.caption2.monospacedDigit()).frame(width: 44)
      } minimal: {
        Image(systemName: "location.fill").foregroundStyle(blue)
      }
    }
  }
}
