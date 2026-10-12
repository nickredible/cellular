//
//  AppDelegate.swift
//  Cellular Helper
//
//  Created by Xuan Han on 24/6/23.
//

import AppKit

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        let runningApps = NSWorkspace.shared.runningApplications
        let isRunning = runningApps.contains {
            $0.bundleIdentifier == "com.xuanhan.cellular"
        }
        
        guard !isRunning else {
            NSApplication.shared.terminate(self)
            return
        }
        
        // The helper lives at Cellular.app/Contents/Library/LoginItems/Cellular Helper.app
        var appURL = Bundle.main.bundleURL
        for _ in 1...4 {
            appURL.deleteLastPathComponent()
        }
        
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                print("Failed to launch Cellular: \(error.localizedDescription)")
            }
            
            // Only quit once the launch request has been handled
            DispatchQueue.main.async {
                NSApplication.shared.terminate(self)
            }
        }
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }
    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}

