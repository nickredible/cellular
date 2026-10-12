//
//  WLANModel.swift
//  Cellular
//
//  Created by Xuan Han on 23/7/23.
//

import Foundation
import CoreWLAN

/**
 This class handles all things related to Wi-Fi.
 
 All state in this class is only accessed on the main thread. Blocking CoreWLAN calls (scanning and associating) run on `wifiQueue`.
 */
class WLANModel: NSObject, ObservableObject, CWEventDelegate {
    private let defaults = UserDefaults.standard
    private let cwWiFiClient = CWWiFiClient.shared()
    private let cwInterface: CWInterface!
    private let wifiQueue = DispatchQueue(label: "WLANModel", qos: .userInitiated)
    
    /// Incremented whenever an in-flight connection attempt to the hotspot should be abandoned
    private var connectGeneration = 0
    private let maxConnectAttempts = 4
    private let connectRetryInterval: TimeInterval = 10
    private var connectRetryTimer: Timer?
    
    private var notifyDisconnectTimer: Timer?
    private var autoEnableTimer: Timer?
    
    /// How long to wait before retrying a trusted network that could not be joined (e.g. because of a wrong password)
    private let trustedNetworkRetryInterval: TimeInterval = 300
    private var trustedNetworkFailureDates: [String: Date] = [:]
    private var isConnectingToTrustedNetwork = false
    
    var ssid: String?
    private var password: String?
    private var userRecentlyConnectedWhileOnTrustedNetwork = false
    var userRecentlyDisconnectedFromHotspot = false
    
    override init() {
        cwInterface = cwWiFiClient.interface()!
        super.init()
        cwWiFiClient.delegate = self
        
        do {
            try cwWiFiClient.startMonitoringEvent(with: .linkDidChange)
            try cwWiFiClient.startMonitoringEvent(with: .scanCacheUpdated)
        } catch {
            print("Failed to start Wi-Fi monitoring: \(error.localizedDescription)")
        }
    }
    
    /**
     The names of the networks macOS has saved, in the order it prefers them. Like any SSID, these can only be read with the Location Services permission.
     */
    var savedNetworkSSIDs: [String] {
        let profiles = cwInterface.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []
        var seenSSIDs = Set<String>()
        return profiles.compactMap(\.ssid).filter { seenSSIDs.insert($0).inserted }
    }
    
    /**
     This function sets the hotspot details for later use.
     - parameter ssid: The SSID of the hotspot
     - parameter password: The password of the hotspot
     */
    func setHotspotDetails(ssid: String, password: String) {
        self.ssid = ssid
        self.password = password
    }
    
    /**
     This function connects to the hotspot, retrying a few times while the phone's hotspot starts up.
     - parameter completionHandler: The function to call when connection is successful
     - parameter onError: The function to call when connection is unsuccessful
     */
    func connect(completionHandler: @escaping () -> Void, onError: @escaping () -> Void) {
        guard let ssid, let password else {
            print("Hotspot SSID and password must be set before calling this function.")
            onError()
            return
        }
        
        // Abandon any previous connection attempt
        cancelConnect()
        
        // Check if user is currently connected to a trusted network
        if let currentSSID = cwInterface.ssid() {
            let trustedNetworkSSIDs = defaults.stringArray(forKey: "trustedNetworks") ?? []
            if trustedNetworkSSIDs.contains(currentSSID) {
                userRecentlyConnectedWhileOnTrustedNetwork = true
            }
        }
        
        attemptConnect(ssid: ssid, password: password, attempt: 1, generation: connectGeneration, completionHandler: completionHandler, onError: onError)
    }
    
    /**
     This function makes a single attempt to scan for and join the hotspot, scheduling another attempt if it fails.
     */
    private func attemptConnect(ssid: String, password: String, attempt: Int, generation: Int, completionHandler: @escaping () -> Void, onError: @escaping () -> Void) {
        print("Connection attempt \(attempt)")
        
        wifiQueue.async { [self] in
            var isConnected = false
            var connectError: Error?
            
            do {
                // Scan for hotspot
                if let network = try cwInterface.scanForNetworks(withName: ssid).first(where: { $0.ssid == ssid }) {
                    // Don't join the hotspot if this attempt was cancelled while scanning
                    guard DispatchQueue.main.sync(execute: { generation == connectGeneration }) else { return }
                    
                    // Attempt to connect to hotspot if it is found
                    try cwInterface.associate(to: network, password: password)
                    isConnected = true
                }
            } catch {
                connectError = error
            }
            
            DispatchQueue.main.async { [self] in
                guard generation == connectGeneration else {
                    print("Connection to hotspot cancelled.")
                    return
                }
                
                if isConnected {
                    connectRetryTimer = nil
                    completionHandler()
                } else if attempt < maxConnectAttempts {
                    // The hotspot may still be starting up, so try again shortly
                    if let connectError {
                        print("Failed to connect to hotspot: \(connectError.localizedDescription)")
                    } else {
                        print("Hotspot not found.")
                    }
                    connectRetryTimer = Timer.scheduledTimer(withTimeInterval: connectRetryInterval, repeats: false) { [weak self] _ in
                        self?.attemptConnect(ssid: ssid, password: password, attempt: attempt + 1, generation: generation, completionHandler: completionHandler, onError: onError)
                    }
                } else {
                    print("Giving up connecting to hotspot after \(attempt) attempts.")
                    connectRetryTimer = nil
                    userRecentlyConnectedWhileOnTrustedNetwork = false
                    onError()
                }
            }
        }
    }
    
    /**
     This function abandons any in-flight attempt to connect to the hotspot.
     */
    private func cancelConnect() {
        connectGeneration += 1
        connectRetryTimer?.invalidate()
        connectRetryTimer = nil
    }
    
    /**
     This function disconnects from the hotspot.
     - parameter indicateOnly: Whether the Mac should only update itself that hotspot has been disconnected
     - parameter systemControlling: Whether this app should disconnect from Wi-Fi for the user
     - parameter userInitiated: Whether the user initiated this disconnection
     */
    func disconnect(indicateOnly: Bool, systemControlling: Bool, userInitiated: Bool) {
        // Cancel any attempts to connect to hotspot
        cancelConnect()
        
        userRecentlyConnectedWhileOnTrustedNetwork = false
        
        if userInitiated {
            userRecentlyDisconnectedFromHotspot = true
        }
        
        // Disconnect from hotspot if needed, without touching any other network the user may be on
        if systemControlling, let ssid {
            wifiQueue.async { [self] in
                if cwInterface.ssid() == ssid {
                    cwInterface.disassociate()
                }
            }
        }
    }
    
    func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        // CoreWLAN delivers events on a background thread
        DispatchQueue.main.async { [self] in
            evaluateLinkState()
        }
    }
    
    /**
     This function evaluates whether any hotspot-related action is needed based on the current Wi-Fi connection.
     */
    func evaluateLinkState() {
        let linkState = cwInterface.ssid() != nil
        
        print("Link state changed: \(linkState)")
        
        if linkState {
            userRecentlyDisconnectedFromHotspot = false
        }
        
        if bluetoothModel.isDeviceConnected {
            evalNotifyDisconnectHotspot()
            evalNotifyConnectHotspot()
            evalAutoEnableHotspot()
        }
    }
    
    /**
     This function notifies the phone of a manual disconnection from hotspot.
     - parameter immediate: Whether the phone should be notified immediately
     */
    private func evalNotifyDisconnectHotspot(immediate: Bool = false) {
        let currSsid = cwInterface.ssid()
        guard bluetoothModel.isConnectedToHotspot && currSsid != ssid else { return }
        
        if immediate {
            print("Notifying disconnected from hotspot...")
            bluetoothModel.disconnectFromHotspot(systemControlling: false, userInitiated: currSsid == nil)
        } else {
            notifyDisconnectTimer?.invalidate()
            notifyDisconnectTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                self?.evalNotifyDisconnectHotspot(immediate: true)
            }
        }
    }
    
    /**
     This function notifies the phone of a manual connection from hotspot. This function runs immediately when executed.
     */
    private func evalNotifyConnectHotspot() {
        let currSsid = cwInterface.ssid()
        if !(bluetoothModel.isConnectedToHotspot || bluetoothModel.isConnectingToHotspot) && currSsid == ssid {
            print("Notifying connected to hotspot...")
            bluetoothModel.notifyConnectedToHotspot()
        }
    }
    
    /**
     This function automatically enables hotspot if known Wi-Fi networks are not available.
     - parameter immediate: Whether the evaluation if auto-connect is needed should be done immediately
     */
    func evalAutoEnableHotspot(immediate: Bool = false) {
        let currSsid = cwInterface.ssid()
        let linkState = currSsid != nil
        let isAutoConnect = defaults.bool(forKey: "autoConnect")
        
        guard isAutoConnect && !isSleeping && !bluetoothModel.isLowBattery && !(bluetoothModel.isConnectedToHotspot || bluetoothModel.isConnectingToHotspot) && !linkState && !userRecentlyDisconnectedFromHotspot else { return }
        
        if immediate {
            print("Enabling hotspot because known Wi-Fi network is not available")
            bluetoothModel.enableHotspot()
        } else {
            // Give macOS a chance to join a known network on its own first
            autoEnableTimer?.invalidate()
            autoEnableTimer = Timer.scheduledTimer(withTimeInterval: 7, repeats: false) { [weak self] _ in
                self?.evalAutoEnableHotspot(immediate: true)
            }
        }
    }
    
    func scanCacheUpdatedForWiFiInterface(withName interfaceName: String) {
        // CoreWLAN delivers events on a background thread
        DispatchQueue.main.async { [self] in
            evalSwitchToTrustedNetwork()
        }
    }
    
    /**
     This function switches from the hotspot to a trusted network if one is in range.
     */
    private func evalSwitchToTrustedNetwork() {
        guard let networks = cwInterface.cachedScanResults() else { return }
        
        let trustedNetworkSSIDs = defaults.stringArray(forKey: "trustedNetworks") ?? []
        
        // Find the first trusted network in range, in the order the user added them
        guard let trustedNetworkIndex = trustedNetworkSSIDs.firstIndex(where: { trustedSSID in networks.contains { $0.ssid == trustedSSID } }) else {
            // The user has left their trusted networks, so they should be switched back to one when they return
            userRecentlyConnectedWhileOnTrustedNetwork = false
            return
        }
        
        let trustedSSID = trustedNetworkSSIDs[trustedNetworkIndex]
        
        // Connect to the trusted network if the user did not choose to connect to the hotspot while on a trusted network
        guard defaults.bool(forKey: "useTrustedNetworks"),
              bluetoothModel.isConnectedToHotspot,
              !userRecentlyConnectedWhileOnTrustedNetwork,
              !isConnectingToTrustedNetwork,
              let network = networks.first(where: { $0.ssid == trustedSSID }) else { return }
        
        // Don't repeatedly try a network that recently failed, since each attempt drops the hotspot connection
        if let failureDate = trustedNetworkFailureDates[trustedSSID], Date().timeIntervalSince(failureDate) < trustedNetworkRetryInterval {
            return
        }
        
        print("Found trusted network!")
        isConnectingToTrustedNetwork = true
        let trustedPassword = Keychain.trustedNetworkPasswords[trustedSSID] ?? ""
        let hotspotSSID = ssid
        let hotspotPassword = password
        
        wifiQueue.async { [self] in
            var isConnected = false
            
            do {
                try associate(toTrustedNetwork: network, password: trustedPassword)
                isConnected = true
            } catch {
                print("Failed to associate to trusted network \(trustedSSID): \(error.localizedDescription)")
                
                // A failed attempt can leave the Mac without any network, so rejoin the hotspot if needed
                if cwInterface.ssid() == nil, let hotspotSSID, let hotspotPassword {
                    do {
                        if let hotspot = try cwInterface.scanForNetworks(withName: hotspotSSID).first(where: { $0.ssid == hotspotSSID }) {
                            try cwInterface.associate(to: hotspot, password: hotspotPassword)
                        }
                    } catch {
                        print("Failed to rejoin hotspot: \(error.localizedDescription)")
                    }
                }
            }
            
            DispatchQueue.main.async { [self] in
                isConnectingToTrustedNetwork = false
                
                if isConnected {
                    trustedNetworkFailureDates[trustedSSID] = nil
                    
                    // Disconnect from hotspot if successfully connected to trusted network
                    bluetoothModel.disconnectFromHotspot(systemControlling: false)
                } else {
                    trustedNetworkFailureDates[trustedSSID] = Date()
                }
            }
        }
    }
    
    /**
     This function joins a trusted network. Trusted networks without a password, like eduroam, are joined with the settings macOS has saved for them, such as an 802.1X profile, since there's no single password to store.
     - parameter network: The trusted network to join
     - parameter password: The trusted network's password, or an empty string to use the settings macOS has saved
     */
    private func associate(toTrustedNetwork network: CWNetwork, password: String) throws {
        if !password.isEmpty {
            try cwInterface.associate(to: network, password: password)
            return
        }
        
        let enterpriseSecurities: [CWSecurity] = [.dynamicWEP, .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise, .enterprise, .wpa3Enterprise]
        if enterpriseSecurities.contains(where: { network.supportsSecurity($0) }) {
            try cwInterface.associate(toEnterpriseNetwork: network, identity: nil, username: nil, password: nil)
        } else {
            try cwInterface.associate(to: network, password: nil)
        }
    }
    
    /**
     This function helps reset all hotspot settings for setup again.
     */
    func reset() {
        // Cancel all tasks
        cancelConnect()
        notifyDisconnectTimer?.invalidate()
        notifyDisconnectTimer = nil
        autoEnableTimer?.invalidate()
        autoEnableTimer = nil
        
        // Reset all variables. Wi-Fi event monitoring is left running so that a newly linked phone works without relaunching the app.
        ssid = nil
        password = nil
        userRecentlyConnectedWhileOnTrustedNetwork = false
        userRecentlyDisconnectedFromHotspot = false
        trustedNetworkFailureDates.removeAll()
        isConnectingToTrustedNetwork = false
    }
}
