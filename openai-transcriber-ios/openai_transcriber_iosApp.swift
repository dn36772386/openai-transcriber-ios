//
//  openai_transcriber_iosApp.swift
//  openai-transcriber-ios
//
//  Created by apple on 2025/05/13.
//

import SwiftUI

@main
struct openai_transcriber_iosApp: App {
    
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        print("✅ App: init() - App instance created!")
        print("✅ App: appDelegate = \(String(describing: appDelegate))")
    }

    var body: some Scene {
        WindowGroup {
            ContentViewWrapper()  // ContentView → ContentViewWrapper に変更
                .onAppear {
                    print("✅ App: ContentView appeared")
                    print("✅ App: AppDelegate instance = \(String(describing: UIApplication.shared.delegate))")
                }
        }
    }
}
