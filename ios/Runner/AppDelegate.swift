import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
      
    // ── Đăng ký Flutter plugin ────────────────────────────────────────────
      
      let controller = window?.rootViewController as! FlutterViewController
      
      SuperTransferPlugin.register(with: registrar(forPlugin: "SuperTransferPlugin")!)
      
      // ── Xin quyền notification ────────────────────────────────────────────
             UNUserNotificationCenter.current().delegate = self
             UNUserNotificationCenter.current().requestAuthorization(
                 options: [.alert, .sound, .badge]
             ) { granted, _ in
                 print("[AppDelegate] Notification permission granted: \(granted)")
             }
      
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
   override func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        print("[AppDelegate] Notification received: \(response.notification.request.identifier)")
        completionHandler([.banner, .sound])
    }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
