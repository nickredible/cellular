//
//  AppDelegate.swift
//  Cellular
//
//  Created by Xuan Han on 24/6/23.
//

import Foundation
import AppKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let defaults = UserDefaults.standard
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Make app an accessory if setup is complete (no icon in Dock)
        let isSetupComplete = defaults.bool(forKey: "isSetupComplete")
        if isSetupComplete {
            if let window = NSApplication.shared.windows.first {
                window.close()
                NSApp.setActivationPolicy(.accessory)
            }
        }
        
        // Register for sleep/wake notifications
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(onWakeNotification(notification:)),
            name: NSWorkspace.didWakeNotification, object: nil)
        
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(onSleepNotification(notification:)),
            name: NSWorkspace.willSleepNotification, object: nil)
        
        // Get local notification permission
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { success, error in
            if success {
                print("Notification permission granted (AppDelegate).")
            } else if let error = error {
                print(error.localizedDescription)
            }
        }
        
        updateModel.startChecking()
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        // Open the release page when the user clicks an update notification
        if response.notification.request.identifier == UpdateModel.notificationIdentifier,
           let urlString = response.notification.request.content.userInfo[UpdateModel.notificationURLKey] as? String,
           let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return !flag
    }
    
    @objc func onWakeNotification(notification: NSNotification) {
        print("Computer has woken up.")
        
        isSleeping = false
        
        // Make sure the phone can find this Mac again if the Bluetooth link dropped during sleep
        bluetoothModel.handleWake()
        
        wlanModel.evalAutoEnableHotspot()
    }
    
    @objc func onSleepNotification(notification: NSNotification) {
        print("Computer is going to sleep.")
        
        // Never auto-enable the hotspot while asleep, regardless of the "disconnect when asleep" setting
        isSleeping = true
        
        let isAutoDisconnectWhenSleep = defaults.bool(forKey: "autoDisconnectWhenSleep")
        if isAutoDisconnectWhenSleep && (bluetoothModel.isConnectedToHotspot || bluetoothModel.isConnectingToHotspot) {
            bluetoothModel.disconnectFromHotspot()
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return !bluetoothModel.isSetupComplete
    }
}
