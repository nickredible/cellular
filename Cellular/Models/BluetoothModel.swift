//
//  BluetoothModel.swift
//  Cellular
//
//  Created by Xuan Han on 7/6/23.
//

import Foundation
import CoreBluetooth
import UserNotifications

extension Data {
    init?(fromHexEncodedString string: String) {
        // Convert 0 ... 9, a ... f, A ...F to their decimal value,
        // return nil for all other input characters
        func decodeNibble(u: UInt8) -> UInt8? {
            switch(u) {
            case 0x30 ... 0x39:
                return u - 0x30
            case 0x41 ... 0x46:
                return u - 0x41 + 10
            case 0x61 ... 0x66:
                return u - 0x61 + 10
            default:
                return nil
            }
        }
        
        self.init(capacity: string.utf8.count/2)
        
        var iter = string.utf8.makeIterator()
        while let c1 = iter.next() {
            guard
                let val1 = decodeNibble(u: c1),
                let c2 = iter.next(),
                let val2 = decodeNibble(u: c2)
            else { return nil }
            self.append(val1 << 4 + val2)
        }
    }
}

extension String {
    /**
     This function generates a random alphanumeric string using the system's cryptographically secure random number generator.
     - parameter length: The length of the string to generate
     */
    static func randomAlphanumeric(length: Int) -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in characters.randomElement(using: &generator)! })
    }
}

/**
 This class handles all things related to connecting to and communicating with the Cellular Companion app on the Android device.
 */
class BluetoothModel: NSObject, ObservableObject, CBPeripheralManagerDelegate {
    private var peripheralManager: CBPeripheralManager?
    private let defaults = UserDefaults.standard
    private var serviceUUID: CBUUID?
    private let commandCharacteristicUUID = CBUUID(string: "00000001-0000-1000-8000-00805f9b34fb")
    private let notificationCharacteristicUUID = CBUUID(string: "00000002-0000-1000-8000-00805f9b34fb")
    private var sharedKey: String?
    private var centralUUID: UUID?
    private var connectedCentral: CBCentral?
    private var pendingNotifications: [NotificationType] = []
    private var notificationCharacteristic: CBMutableCharacteristic?
    private var resetCompletionHandler: (() -> Void)?
    private var hotspotRequestTimer: Timer?
    private var resetFallbackTimer: Timer?
    
    /// Network types sent by the Companion app. An empty string means the phone has no mobile data network.
    static let acceptableNetworkTypes: Set<String> = ["", "GPRS", "E", "3G", "4G", "5G", "5Ge", "5G+"]
    
    /// How long to wait for the phone to report that its hotspot is on after asking it to turn the hotspot on
    private let hotspotRequestTimeout: TimeInterval = 60
    
    @Published private(set) var isPoweredOn = false
    @Published var isBluetoothOffDialogPresented = false
    @Published var isBluetoothNotGrantedDialogPresented = false
    @Published var isBluetoothNotSupportedDialogPresented = false
    @Published var isBluetoothUnknownErrorDialogPresented = false
    
    @Published var isHelloWorldReceived = false
    @Published var isSetupComplete = false
    @Published var isDeviceConnected = false
    @Published var isConnectingToHotspot = false
    @Published var isConnectedToHotspot = false
    var isLowBattery = false
    private var isResetting = false
    
    @Published var signalLevel = -1
    @Published var networkType = "-1"
    @Published var batteryLevel = -1
    
    enum NotificationType: String {
        case EnableHotspot = "0"
        case DisableHotspot = "1"
        case IndicateConnectedHotspot = "2"
        case EnableSeePhoneInfo = "3"
        case DisableSeePhoneInfo = "4"
        case IndicateReset = "5"
        case DisconnectDevice = "6"
    }
    
    struct PhoneInfo: Equatable {
        /// The signal level of the phone (0 to 3), -1 if unchanged
        var signalLevel: Int
        /// The network type of the phone (one of `acceptableNetworkTypes`), "-1" if unchanged
        var networkType: String
        /// The battery level of the phone (0 to 100), -1 if unchanged
        var batteryLevel: Int
    }
    
    enum CommandType: String {
        case HelloWorld = "0"
        case ShareHotspotDetails = "1"
        case SharePhoneInfo = "2"
        case ConnectToHotspot = "3"
        case DisconnectFromHotspot = "4"
        case IndicateReset = "5"
    }
    
    override init() {
        super.init()
        isSetupComplete = defaults.bool(forKey: "isSetupComplete")
    }
    
    /**
     This function generates and stores in UserDefaults a new service UUID and shared key for connecting to a new device. It then prepares the device for incoming BLE connections.
     - Returns: A dictionary containing data to be added to a QR code for scanning by the Companion app
     */
    func prepareForNewConnection() -> [String: String] {
        let serviceUUID = CBUUID(nsuuid: UUID())
        let sharedKey = String.randomAlphanumeric(length: 32)
        self.serviceUUID = serviceUUID
        self.sharedKey = sharedKey
        defaults.set(serviceUUID.uuidString, forKey: "serviceUUID")
        Keychain.set(sharedKey, forKey: Keychain.sharedKeyKey)
        
        // The service UUID has changed, so the old peripheral manager (if any) must not keep advertising
        tearDownPeripheralManager()
        initializeBluetooth()
        
        return [
            "serviceUUID": serviceUUID.uuidString,
            "sharedKey": sharedKey,
        ]
    }
    
    /**
     This function prepares this device for incoming BLE connections. The service UUID and shared key must be set or present in UserDefaults before this function is called. Calling this function again while Bluetooth is already initialised does nothing.
     */
    func initializeBluetooth() {
        guard peripheralManager == nil else {
            print("Bluetooth is already initialised.")
            return
        }
        
        if serviceUUID == nil {
            guard let serviceUUIDString = defaults.string(forKey: "serviceUUID")
            else {
                print("Error: Service UUID not set, call prepareForNewConnection() first.")
                return
            }
            
            serviceUUID = CBUUID(string: serviceUUIDString)
        }
        if sharedKey == nil {
            sharedKey = Keychain.string(forKey: Keychain.sharedKeyKey)
            
            if sharedKey == nil {
                print("Error: Shared PIN not set, call prepareForNewConnection() first.")
                return
            }
        }
        if let centralUUIDString = defaults.string(forKey: "centralUUID") {
            centralUUID = UUID(uuidString: centralUUIDString)
        } else {
            if isSetupComplete {
                print("Error: Central UUID not set but setup is complete!")
                return
            }
        }
        
        if let ssid = defaults.string(forKey: "ssid"), let password = Keychain.string(forKey: Keychain.hotspotPasswordKey) {
            wlanModel.setHotspotDetails(ssid: ssid, password: password)
        }
        
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
    }
    
    /**
     This function stops advertising, removes all services and releases the peripheral manager.
     */
    private func tearDownPeripheralManager() {
        guard let peripheralManager else { return }
        
        peripheralManager.delegate = nil
        if peripheralManager.state == .poweredOn {
            peripheralManager.stopAdvertising()
            peripheralManager.removeAllServices()
        }
        
        self.peripheralManager = nil
        notificationCharacteristic = nil
        isPoweredOn = false
    }
    
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state != .poweredOn {
            isPoweredOn = false
            
            // CoreBluetooth does not report unsubscriptions when Bluetooth stops, so the phone must be treated as disconnected here
            handleDeviceDisconnected()
        }
        
        switch peripheral.state {
        case .poweredOn:
            print("CBManager is powered on")
            isPoweredOn = true
            isBluetoothOffDialogPresented = false
            isBluetoothNotGrantedDialogPresented = false
            isBluetoothNotSupportedDialogPresented = false
            isBluetoothUnknownErrorDialogPresented = false
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["bluetooth"])
            setupPeripheral()
        case .poweredOff:
            print("CBManager is not powered on")
            isBluetoothOffDialogPresented = true
        case .resetting:
            print("CBManager is resetting")
            isBluetoothUnknownErrorDialogPresented = true
            if isSetupComplete {
                showFailedToStartNotification(reason: .UnknownBluetoothError)
            }
        case .unauthorized:
            print("Bluetooth permission was not granted")
            isBluetoothNotGrantedDialogPresented = true
            if isSetupComplete {
                showFailedToStartNotification(reason: .BluetoothPermissionNotGranted)
            }
        case .unsupported:
            print("Bluetooth is not supported on this device")
            isBluetoothNotSupportedDialogPresented = true
            if isSetupComplete {
                showFailedToStartNotification(reason: .BluetoothNotSupported)
            }
        default:
            print("A previously unknown peripheral manager state occurred")
            isBluetoothUnknownErrorDialogPresented = true
            if isSetupComplete {
                showFailedToStartNotification(reason: .UnknownBluetoothError)
            }
        }
    }
    
    /**
     This function (re-)creates the Cellular service. Advertising starts once the service has been added. Ensure that `peripheralManager` is powered on before this function is called.
     */
    private func setupPeripheral() {
        guard let peripheralManager, isPoweredOn, let serviceUUID else {
            print("Error: Peripheral manager is not powered on.")
            return
        }
        
        // Start from a clean GATT database so that services are never added twice
        peripheralManager.stopAdvertising()
        peripheralManager.removeAllServices()
        
        // Create the characteristics
        let commandCharacteristic = CBMutableCharacteristic(type: commandCharacteristicUUID,
                                                            properties: .write,
                                                            value: nil,
                                                            permissions: .writeable)
        let notificationCharacteristic = CBMutableCharacteristic(type: notificationCharacteristicUUID,
                                                                 properties: .indicate,
                                                                 value: nil,
                                                                 permissions: .readable)
        
        // Create a service for the characteristics
        let commandService = CBMutableService(type: serviceUUID, primary: true)
        commandService.characteristics = [commandCharacteristic, notificationCharacteristic]
        
        // Save the notification characteristic for later
        self.notificationCharacteristic = notificationCharacteristic
        
        // Add the service to the peripheral manager
        peripheralManager.add(commandService)
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            print("Error: Failed to add service: \(error.localizedDescription)")
            return
        }
        
        startAdvertising()
    }
    
    /**
     This function starts (or restarts) advertising the Cellular service so that the phone can find this Mac.
     */
    private func startAdvertising() {
        guard let peripheralManager, isPoweredOn, let serviceUUID else { return }
        
        if peripheralManager.isAdvertising {
            peripheralManager.stopAdvertising()
        }
        peripheralManager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceUUID]])
    }
    
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            print("Error: Failed to start advertising: \(error.localizedDescription)")
        } else {
            print("Started advertising.")
        }
    }
    
    /**
     This function should be called when the Mac wakes from sleep. Advertising is restarted because the Bluetooth controller may have stopped it during sleep, which would leave the phone unable to find this Mac again.
     */
    func handleWake() {
        startAdvertising()
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard central.identifier == centralUUID else {
            print("Error: Unknown central subscribed to characteristic.")
            return
        }
        
        print("Central subscribed to characteristic \(characteristic.uuid.uuidString)")
        connectedCentral = central
        isDeviceConnected = true
        pendingNotifications.removeAll()
        
        // Advertising is deliberately left on. If the link drops without CoreBluetooth reporting an unsubscription (which can happen across sleep), the phone must still be able to find this Mac again.
        
        if isSetupComplete {
            // Enable seeing phone info if needed
            if defaults.bool(forKey: "seePhoneInfo") {
                enableSeePhoneInfo()
            }
            
            // Evaluate whether Wi-Fi connection-based functions need to be run
            wlanModel.evaluateLinkState()
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard central.identifier == centralUUID else {
            print("Unknown central unsubscribed from characteristic.")
            return
        }
        
        print("Central unsubscribed from characteristic \(characteristic.uuid.uuidString)")
        handleDeviceDisconnected()
        
        if isResetting {
            // Complete reset if reset is in progress
            completeReset()
        } else {
            // Re-create the service and restart advertising so the phone can reconnect later
            setupPeripheral()
        }
    }
    
    /**
     This function updates the state of this model to reflect that the phone is no longer connected.
     */
    private func handleDeviceDisconnected() {
        connectedCentral = nil
        isDeviceConnected = false
        pendingNotifications.removeAll()
        cancelHotspotRequestTimeout()
        
        // The phone turns off its hotspot when it disconnects from this Mac
        isConnectingToHotspot = false
        isConnectedToHotspot = false
        
        // Phone info is resent when the phone reconnects, so don't show stale values in the meantime
        signalLevel = -1
        networkType = "-1"
        batteryLevel = -1
    }
    
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        sendPendingNotifications()
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let firstRequest = requests.first else { return }
        
        // CoreBluetooth expects exactly one response, sent to the first request, covering every request in the batch
        var result = CBATTError.Code.success
        for eachRequest in requests {
            let requestResult = handleWrite(request: eachRequest)
            if result == .success {
                result = requestResult
            }
        }
        peripheral.respond(to: firstRequest, withResult: result)
    }
    
    /**
     This function handles a single write to the command characteristic.
     
     Note that the Companion app tears down the Bluetooth connection whenever a write fails, so well-formed commands from the linked phone should only be rejected when absolutely necessary.
     - parameter request: The write request
     - Returns: The result to respond to the phone with
     */
    private func handleWrite(request: CBATTRequest) -> CBATTError.Code {
        // Ensure that request payload is present and decodable
        guard let requestValue = request.value,
              let payload = String(data: requestValue, encoding: .utf8),
              !payload.isEmpty else {
            print("Error: No usable payload found for this request.")
            return .attributeNotFound
        }
        
        // Split parts from request payload string
        let parts = Self.splitPayload(payload)
        
        guard let command = CommandType(rawValue: parts[0]) else {
            print("Error: Unrecognised command \(parts[0]).")
            return .requestNotSupported
        }
        
        // Only the linked phone may send commands other than Hello World
        if command != .HelloWorld {
            guard request.central.identifier == centralUUID else {
                print("Error: Request received from unknown central.")
                return .insufficientAuthorization
            }
        }
        
        switch command {
        case .HelloWorld:
            // Ensure that the Hello World command is only received during setup
            guard !isSetupComplete else {
                print("Error: Setup has completed but Hello World is received.")
                return .requestNotSupported
            }
            
            print("Received Hello World")
            isHelloWorldReceived = true
            
            // Store central UUID
            centralUUID = request.central.identifier
            defaults.set(request.central.identifier.uuidString, forKey: "centralUUID")
        case .ShareHotspotDetails:
            guard let sharedKey, let hotspotDetails = Self.parseHotspotDetails(parts: parts, sharedKey: sharedKey) else {
                print("Error: Could not decrypt hotspot details.")
                return .unlikelyError
            }
            
            // Store hotspot info in UserDefaults
            saveHotspotInfo(ssid: hotspotDetails.ssid, password: hotspotDetails.password)
            
            // Set setup to be complete if needed
            if !isSetupComplete {
                isSetupComplete = true
                defaults.set(isSetupComplete, forKey: "isSetupComplete")
            }
        case .SharePhoneInfo:
            guard let phoneInfo = Self.parsePhoneInfo(parts: parts) else {
                print("Error: Payload is invalid: \(payload)")
                return .unlikelyError
            }
            
            // Update UI with new phone info accordingly
            setPhoneInfo(signalLevel: phoneInfo.signalLevel, networkType: phoneInfo.networkType, batteryLevel: phoneInfo.batteryLevel)
            
            if phoneInfo.batteryLevel != -1 {
                // Evaluate if minimum battery reached
                evalMinimumBattery(batteryLevel: phoneInfo.batteryLevel)
            }
        case .ConnectToHotspot:
            print("Connecting to hotspot...")
            connectToHotspot()
        case .DisconnectFromHotspot:
            print("Disconnecting from hotspot...")
            disconnectFromHotspot(indicateOnly: true, userInitiated: true)
        case .IndicateReset:
            print("Unlinking phone...")
            
            // Unlink phone once the write has been acknowledged
            DispatchQueue.main.async { [self] in
                reset(indicateOnly: true)
                wlanModel.reset()
            }
        }
        
        return .success
    }
    
    /**
     This function splits a command payload into its space-separated parts. Empty parts are meaningful (e.g. an unknown network type), so they are kept.
     */
    static func splitPayload(_ payload: String) -> [String] {
        payload.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    }
    
    /**
     This function decrypts the hotspot details sent by the Companion app as "1 <hex IV> <base64 ciphertext>", where the plaintext is of the form "<SSID>" "<password>".
     - parameter parts: The parts of the command payload
     - parameter sharedKey: The key shared with the phone during setup
     - Returns: The SSID and password of the hotspot, or nil if the payload is invalid
     */
    static func parseHotspotDetails(parts: [String], sharedKey: String) -> (ssid: String, password: String)? {
        // Android's default Base64 encoder inserts line breaks, so unknown characters are ignored
        guard parts.count == 3,
              let ivData = Data(fromHexEncodedString: parts[1]),
              let cipherData = Data(base64Encoded: parts[2], options: .ignoreUnknownCharacters),
              let aes = AES(key: sharedKey, ivData: ivData),
              let plainText = aes.decrypt(data: cipherData) else { return nil }
        
        let credentials = plainText.components(separatedBy: "\" \"")
        guard credentials.count == 2 else { return nil }
        
        // Trim leading/trailing quotation marks
        let ssid = credentials[0].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let password = credentials[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return (ssid, password)
    }
    
    /**
     This function parses the phone info sent by the Companion app as "2 <signal level> <network type> <battery level>", using -1 for values that have not changed. Values that are out of range are ignored rather than rejected, because a rejected write makes the phone disconnect.
     - parameter parts: The parts of the command payload
     - Returns: The phone info, or nil if the payload does not have the expected number of parts
     */
    static func parsePhoneInfo(parts: [String]) -> PhoneInfo? {
        guard parts.count == 4 else { return nil }
        
        var phoneInfo = PhoneInfo(signalLevel: -1, networkType: "-1", batteryLevel: -1)
        if let value = Int(parts[1]), (0...3).contains(value) {
            phoneInfo.signalLevel = value
        }
        if acceptableNetworkTypes.contains(parts[2]) {
            phoneInfo.networkType = parts[2]
        } else if parts[2] != "-1" {
            print("Ignoring unknown network type \(parts[2])")
        }
        if let value = Int(parts[3]), (0...100).contains(value) {
            phoneInfo.batteryLevel = value
        }
        return phoneInfo
    }
    
    /**
     This function saves the provided hotspot SSID to UserDefaults and its password to the keychain.
     - parameter ssid: The SSID of the hotspot
     - parameter password: The password of the hotspot
     */
    private func saveHotspotInfo(ssid: String, password: String) {
        wlanModel.setHotspotDetails(ssid: ssid, password: password)
        defaults.set(ssid, forKey: "ssid")
        Keychain.set(password, forKey: Keychain.hotspotPasswordKey)
        
        print("Saved hotspot info for \(ssid)")
    }
    
    /**
     This function updates the phone info UI with the provided signal level, network type and battery level.
     - parameter signalLevel: The signal level of the phone (0 to 3), -1 if unchanged
     - parameter networkType: The network type of the phone (one of `acceptableNetworkTypes`), "-1" if unchanged
     - parameter batteryLevel: The battery level of the phone (0 to 100), -1 if unchanged
     */
    private func setPhoneInfo(signalLevel: Int, networkType: String, batteryLevel: Int) {
        if signalLevel != -1 {
            self.signalLevel = signalLevel
        }
        if networkType != "-1" {
            self.networkType = networkType
        }
        if batteryLevel != -1 {
            self.batteryLevel = Int(floor(Double(batteryLevel + 12) / 25)) * 25
        }
        
        print("Phone info set: \(signalLevel) \(networkType) \(batteryLevel)")
    }
    
    /**
     This function decides if the phone's battery level is below the minimum battery level and disconnects from the hotspot if needed.
     - parameter batteryLevel: The battery level of the phone (0 to 100)
     */
    private func evalMinimumBattery(batteryLevel: Int) {
        let minimumBatteryLevel = defaults.integer(forKey: "minimumBatteryLevel")
        
        // Disconnect from hotspot if needed
        if !isLowBattery && batteryLevel < minimumBatteryLevel && (isConnectingToHotspot || isConnectedToHotspot) {
            disconnectFromHotspot()
            
            // Show notification to inform user that hotspot has disconnected due to low battery
            let content = UNMutableNotificationContent()
            content.title = "Hotspot turned off"
            content.subtitle = "Your phone's battery is below \(minimumBatteryLevel)%."
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
        
        isLowBattery = batteryLevel < minimumBatteryLevel
    }
    
    /**
     This function sends a notification to the phone, or queues it if CoreBluetooth's transmit queue is full. Notifications are not queued while the phone is disconnected because all relevant state is re-synced when it reconnects.
     - parameter value: The new value of the notification characteristic
     */
    private func updateCharacteristicValue(value: NotificationType) {
        guard isPoweredOn else {
            print("Error: Peripheral manager is not powered on.")
            return
        }
        
        guard connectedCentral != nil else {
            print("Device is not connected to the Android Companion. Value \(value) will not be sent.")
            return
        }
        
        // Preserve ordering: if values are already waiting, this one must wait too
        if pendingNotifications.isEmpty && sendNotification(value) {
            print("Value \(value) sent successfully.")
        } else {
            pendingNotifications.append(value)
            print("Value \(value) send deferred, added to pending queue.")
        }
    }
    
    /**
     This function sends a notification to the phone immediately.
     - Returns: Whether the notification was accepted by CoreBluetooth's transmit queue
     */
    private func sendNotification(_ value: NotificationType) -> Bool {
        guard let peripheralManager, let notificationCharacteristic, let connectedCentral else { return false }
        return peripheralManager.updateValue(Data(value.rawValue.utf8), for: notificationCharacteristic, onSubscribedCentrals: [connectedCentral])
    }
    
    /**
     This function sends queued notifications in order until CoreBluetooth's transmit queue is full again.
     */
    private func sendPendingNotifications() {
        while let nextValue = pendingNotifications.first {
            guard sendNotification(nextValue) else { return }
            pendingNotifications.removeFirst()
            print("Resent value \(nextValue) to central.")
        }
    }
    
    /**
     This function enables the mobile hotspot.
     */
    func enableHotspot() {
        guard isPoweredOn else {
            print("Error: Peripheral manager is not powered on.")
            return
        }
        
        guard connectedCentral != nil else {
            print("Error: Device must be connected to Android Companion.")
            return
        }
        
        if !(isConnectingToHotspot || isConnectedToHotspot) {
            isConnectingToHotspot = true
            updateCharacteristicValue(value: .EnableHotspot)
            startHotspotRequestTimeout()
        }
    }
    
    /**
     This function stops waiting forever for a phone that never answers an "Enable hotspot" request (e.g. the hotspot failed to start, or the Bluetooth link silently died).
     */
    private func startHotspotRequestTimeout() {
        hotspotRequestTimer?.invalidate()
        hotspotRequestTimer = Timer.scheduledTimer(withTimeInterval: hotspotRequestTimeout, repeats: false) { [weak self] _ in
            guard let self, self.isConnectingToHotspot else { return }
            
            print("Phone did not respond to the request to enable its hotspot.")
            self.disconnectFromHotspot(systemControlling: false)
            
            // Let the user know that the hotspot could not be turned on
            let content = UNMutableNotificationContent()
            content.title = "Couldn't turn on hotspot"
            content.subtitle = "Your phone didn't respond. Make sure Cellular Companion is running and Bluetooth is on."
            let request = UNNotificationRequest(identifier: "hotspotTimeout", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }
    
    private func cancelHotspotRequestTimeout() {
        hotspotRequestTimer?.invalidate()
        hotspotRequestTimer = nil
    }
    
    /**
     This function connects the device to the mobile hotspot.
     */
    private func connectToHotspot() {
        // The phone has responded, so the Wi-Fi connection attempt's own retries and error handling take over from here
        cancelHotspotRequestTimeout()
        isConnectingToHotspot = true
        
        wlanModel.connect { [self] in
            isConnectedToHotspot = true
            isConnectingToHotspot = false
        } onError: { [self] in
            isConnectingToHotspot = false
            disconnectFromHotspot(systemControlling: false)
        }
    }
    
    /**
     This function notifies the phone that the device is connected to the mobile hotspot.
     */
    func notifyConnectedToHotspot() {
        guard isPoweredOn else {
            print("Error: Peripheral manager is not powered on.")
            return
        }
        
        guard connectedCentral != nil else {
            print("Error: Device must be connected to Android Companion.")
            return
        }
        
        guard !isConnectedToHotspot else {
            print("Error: Device is already known to be connected to hotspot.")
            return
        }
        
        cancelHotspotRequestTimeout()
        updateCharacteristicValue(value: .IndicateConnectedHotspot)
        
        isConnectedToHotspot = true
        isConnectingToHotspot = false
    }
    
    /**
     This function disconnects the device from the mobile hotspot.
     - parameter indicateOnly: Whether the Mac should only update itself that hotspot has been disconnected
     - parameter systemControlling: Whether this app should disconnect from Wi-Fi for the user
     - parameter userInitiated: Whether the user initiated this disconnection
     */
    func disconnectFromHotspot(indicateOnly: Bool = false, systemControlling: Bool = true, userInitiated: Bool = false) {
        cancelHotspotRequestTimeout()
        
        if !indicateOnly {
            updateCharacteristicValue(value: .DisableHotspot)
        }
        
        wlanModel.disconnect(indicateOnly: indicateOnly, systemControlling: systemControlling, userInitiated: userInitiated)
        
        isConnectedToHotspot = false
        isConnectingToHotspot = false
    }
    
    /**
     This function enables the "See phone info" feature.
     */
    func enableSeePhoneInfo() {
        updateCharacteristicValue(value: .EnableSeePhoneInfo)
    }
    
    /**
     This function disables the "See phone info" feature.
     */
    func disableSeePhoneInfo() {
        updateCharacteristicValue(value: .DisableSeePhoneInfo)
        signalLevel = -1
        networkType = "-1"
        batteryLevel = -1
    }
    
    /**
     This function registers a reset completion handler that will be called when the device finishes resetting. This is typically used to update UI.
     */
    func registerResetCompletionHandler(resetCompletionHandler: @escaping () -> Void) {
        self.resetCompletionHandler = resetCompletionHandler
    }
    
    /**
     This function disconnects the device from the Android companion and de-initialises the peripheral manager. To re-initialise, call `initializeBluetooth()` again.
     */
    func dispose() {
        guard peripheralManager != nil else { return }
        
        if isConnectedToHotspot || isConnectingToHotspot {
            wlanModel.disconnect(indicateOnly: true, systemControlling: false, userInitiated: false)
        }
        handleDeviceDisconnected()
        tearDownPeripheralManager()
        print("Disposed Bluetooth model successfully.")
    }
    
    /**
     This function forgets the device paired to this Mac and prevents devices from connecting to it.
     - parameter indicateOnly: Whether the Mac should only update itself that reset has been initiated
     */
    func reset(indicateOnly: Bool = false) {
        guard !isResetting else { return }
        isResetting = true
        
        if isDeviceConnected {
            if !indicateOnly {
                updateCharacteristicValue(value: .IndicateReset)
            }
            
            // The reset completes when the phone unsubscribes. Don't wait forever if it never does (e.g. the link has silently died).
            resetFallbackTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                guard let self, self.isResetting else { return }
                print("Phone did not unsubscribe in time, completing reset anyway.")
                self.completeReset()
            }
        } else {
            completeReset()
        }
    }
    
    /**
     This function completes the unlinking of the phone, clearing all linking data. Settings are not cleared.
     */
    private func completeReset() {
        guard isResetting else { return }
        
        resetFallbackTimer?.invalidate()
        resetFallbackTimer = nil
        cancelHotspotRequestTimeout()
        
        // Stop advertising services
        tearDownPeripheralManager()
        
        // Reset all variables
        serviceUUID = nil
        sharedKey = nil
        centralUUID = nil
        connectedCentral = nil
        pendingNotifications.removeAll()
        isBluetoothOffDialogPresented = false
        isBluetoothNotGrantedDialogPresented = false
        isBluetoothNotSupportedDialogPresented = false
        isBluetoothUnknownErrorDialogPresented = false
        isHelloWorldReceived = false
        isSetupComplete = false
        isDeviceConnected = false
        isConnectingToHotspot = false
        isConnectedToHotspot = false
        isLowBattery = false
        isResetting = false
        signalLevel = -1
        networkType = "-1"
        batteryLevel = -1
        
        // Clear relevant User Defaults and secrets
        defaults.removeObject(forKey: "serviceUUID")
        defaults.removeObject(forKey: "centralUUID")
        defaults.removeObject(forKey: "isSetupComplete")
        defaults.removeObject(forKey: "ssid")
        Keychain.removeValue(forKey: Keychain.sharedKeyKey)
        Keychain.removeValue(forKey: Keychain.hotspotPasswordKey)
        
        // Get view to prepare for setup
        resetCompletionHandler?()
    }
}
