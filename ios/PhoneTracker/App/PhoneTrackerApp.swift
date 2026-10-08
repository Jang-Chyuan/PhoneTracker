import GoogleMaps
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    // iOS relaunches the app in the background for a location event after it ended the app; resume recording then.
    let inBackground = launchOptions?[.location] != nil || application.applicationState == .background
    // A foreground launch resumes from the screen instead (AppModel.ensureLocation), like Android's onResume.
    if inBackground { LocationTracker.shared.resumeAfterLaunch(inBackground: true) }
    return true
  }
}

@main
struct PhoneTrackerApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var model = AppModel()

  init() {
    // Must run before the first GMSMapView exists; the SDK aborts without any key. Like Android, a missing key
    // only leaves the base map blank while GPS recording keeps working.
    GMSServices.provideAPIKey(GoogleMapsKey.configured ? GoogleMapsKey.value : "missing-key")
  }

  var body: some Scene {
    WindowGroup {
      ContentView().environmentObject(model)
    }
  }
}
