import ActivityKit
import AppIntents
import Foundation

/// Shared by the app and the widget extension.
struct RecordingActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable { var startedAt: Date }
}

/// "停止記錄" on the lock screen / Dynamic Island. LiveActivityIntent runs in the app process.
struct StopRecordingIntent: LiveActivityIntent {
  static var title: LocalizedStringResource = "停止記錄"
  static var description = IntentDescription("停止 PhoneTracker 背景位置記錄")
  init() {}
  func perform() async throws -> some IntentResult {
    #if !WIDGET_EXTENSION
    await MainActor.run { LocationTracker.shared.stop() }
    #endif
    return .result()
  }
}
