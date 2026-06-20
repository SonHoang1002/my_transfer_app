// AppDelegate.swift
// SuperTransfer — iOS
//
// Dán vào Runner/AppDelegate.swift (thay thế file mặc định của Flutter).

import Flutter
import UIKit
import UserNotifications

@available(iOS 14, *)
@main
@objc class AppDelegate: FlutterAppDelegate {

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {

        // Đăng ký plugin thủ công
        // Lưu ý: GeneratedPluginRegistrant.register(with: self) phải gọi TRƯỚC super
        // để các plugin khác cũng được đăng ký đúng thứ tự.
        GeneratedPluginRegistrant.register(with: self)

        // Đăng ký SuperTransferPlugin
        if let registrar = registrar(forPlugin: "SuperTransferPlugin") {
            SuperTransferPlugin.register(with: registrar)
        }

        // Xin quyền notification — delegate phải set trước khi gọi super
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, error in
            if let error {
                print("[AppDelegate] Notification auth error: \(error)")
            } else {
                print("[AppDelegate] Notification permission granted: \(granted)")
            }
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // Hiện notification dạng banner khi app đang foreground
    override func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }

    // Xử lý khi user tap vào notification — PHẢI gọi completionHandler
    override func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}

// =============================================================================
// Info.plist — Các key BẮT BUỘC phải thêm vào Runner/Info.plist
// =============================================================================
//
// <!-- Mạng nội bộ (UDP/TCP discovery) -->
// <key>NSLocalNetworkUsageDescription</key>
// <string>Ứng dụng cần truy cập mạng nội bộ để tìm và kết nối với thiết bị khác.</string>
//
// <key>NSBonjourServices</key>
// <array>
//     <string>_supertransfer._tcp</string>
// </array>
//
// <!-- Bluetooth BLE (discovery) -->
// <key>NSBluetoothAlwaysUsageDescription</key>
// <string>Ứng dụng sử dụng Bluetooth để tìm thiết bị gần đây.</string>
//
// <!-- Lưu ảnh/video nhận được -->
// <key>NSPhotoLibraryAddUsageDescription</key>
// <string>Ứng dụng cần lưu ảnh và video nhận được vào Thư viện ảnh.</string>
//
// <!-- Background modes -->
// <key>UIBackgroundModes</key>
// <array>
//     <string>bluetooth-central</string>
//     <string>bluetooth-peripheral</string>
//     <string>fetch</string>
//     <string>processing</string>
// </array>
