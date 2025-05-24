import UIKit
import Foundation

class AppDelegate: NSObject, UIApplicationDelegate {
    
    override init() {
        super.init()
        print("✅ AppDelegate: init() - AppDelegate instance created!")
    }
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        print("✅ AppDelegate: didFinishLaunchingWithOptions - AppDelegateが初期化されました！")
        // BackgroundSessionManagerの初期化を促す
        let manager = BackgroundSessionManager.shared
        print("✅ AppDelegate: BackgroundSessionManager = \(manager)")
        return true
    }
    
    // バックグラウンドセッションの全タスク完了時に呼ばれる
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        print("🔵 AppDelegate: handleEventsForBackgroundURLSession for \(identifier)")
        BackgroundSessionManager.shared.setBackgroundCompletionHandler(completionHandler)
    }
}