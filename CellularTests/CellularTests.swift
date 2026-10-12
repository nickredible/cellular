//
//  CellularTests.swift
//  CellularTests
//
//  Created by Xuan Han on 5/6/23.
//

import XCTest
@testable import Cellular

/**
 These tests cover how the Mac parses commands written by the Cellular Companion app. The Companion app disconnects whenever a write is rejected, so payloads it really sends must always be accepted.
 */
final class CellularTests: XCTestCase {
    private let sharedKey = "abcdefghijklmnopqrstuvwxyz012345"

    /**
     This function encrypts hotspot details the same way the Companion app does: AES/CBC/PKCS7 with a hex IV, and Android's default Base64 encoding, which inserts a line break every 76 characters.
     */
    private func companionHotspotDetailsPayload(ssid: String, password: String, key: String) -> String {
        var ivBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, ivBytes.count, &ivBytes)
        let ivData = Data(ivBytes)

        let cipherData = AES(key: key, ivData: ivData)!.encrypt(string: "\"\(ssid)\" \"\(password)\"")!
        var base64 = cipherData.base64EncodedString()
        var index = base64.index(base64.startIndex, offsetBy: 76, limitedBy: base64.endIndex)
        while let lineEnd = index, lineEnd < base64.endIndex {
            base64.insert("\n", at: lineEnd)
            index = base64.index(lineEnd, offsetBy: 77, limitedBy: base64.endIndex)
        }

        let ivHex = ivBytes.map { String(format: "%02x", $0) }.joined()
        return "1 \(ivHex) \(base64)"
    }

    func testSplitPayloadKeepsEmptyParts() {
        // The Companion app sends an empty network type when the phone has no mobile data network
        XCTAssertEqual(BluetoothModel.splitPayload("2 -1  -1"), ["2", "-1", "", "-1"])
    }

    func testPhoneInfoAcceptsEveryNetworkTypeTheCompanionSends() {
        for networkType in ["", "GPRS", "E", "3G", "4G", "5G", "5Ge", "5G+"] {
            let phoneInfo = BluetoothModel.parsePhoneInfo(parts: BluetoothModel.splitPayload("2 -1 \(networkType) -1"))
            XCTAssertEqual(phoneInfo, .init(signalLevel: -1, networkType: networkType, batteryLevel: -1), "Network type \"\(networkType)\"")
        }
    }

    func testPhoneInfoParsesAllFields() {
        let phoneInfo = BluetoothModel.parsePhoneInfo(parts: BluetoothModel.splitPayload("2 3 4G 87"))
        XCTAssertEqual(phoneInfo, .init(signalLevel: 3, networkType: "4G", batteryLevel: 87))
    }

    func testPhoneInfoIgnoresInvalidValuesInsteadOfRejecting() {
        let phoneInfo = BluetoothModel.parsePhoneInfo(parts: BluetoothModel.splitPayload("2 7 6G 150"))
        XCTAssertEqual(phoneInfo, .init(signalLevel: -1, networkType: "-1", batteryLevel: -1))
    }

    func testPhoneInfoRejectsMalformedPayload() {
        XCTAssertNil(BluetoothModel.parsePhoneInfo(parts: BluetoothModel.splitPayload("2 3 4G")))
    }

    func testHotspotDetailsRoundTrip() {
        let payload = companionHotspotDetailsPayload(ssid: "My Phone", password: "hunter22", key: sharedKey)
        let details = BluetoothModel.parseHotspotDetails(parts: BluetoothModel.splitPayload(payload), sharedKey: sharedKey)
        XCTAssertEqual(details?.ssid, "My Phone")
        XCTAssertEqual(details?.password, "hunter22")
    }

    func testHotspotDetailsWithLineBrokenBase64() {
        // Long enough for Android's Base64 encoder to insert line breaks
        let ssid = "A rather long hotspot name for testing"
        let password = "and an even longer password, with spaces and symbols !@#$%^&*()"
        let payload = companionHotspotDetailsPayload(ssid: ssid, password: password, key: sharedKey)
        XCTAssertTrue(payload.contains("\n"), "Test payload should contain a line break")

        let details = BluetoothModel.parseHotspotDetails(parts: BluetoothModel.splitPayload(payload), sharedKey: sharedKey)
        XCTAssertEqual(details?.ssid, ssid)
        XCTAssertEqual(details?.password, password)
    }

    func testHotspotDetailsWithEmptyPassword() {
        let payload = companionHotspotDetailsPayload(ssid: "Open hotspot", password: "", key: sharedKey)
        let details = BluetoothModel.parseHotspotDetails(parts: BluetoothModel.splitPayload(payload), sharedKey: sharedKey)
        XCTAssertEqual(details?.ssid, "Open hotspot")
        XCTAssertEqual(details?.password, "")
    }

    func testHotspotDetailsWithWrongKeyIsRejected() {
        let payload = companionHotspotDetailsPayload(ssid: "My Phone", password: "hunter22", key: "ZYXWVUTSRQPONMLKJIHGFEDCBA987654")
        XCTAssertNil(BluetoothModel.parseHotspotDetails(parts: BluetoothModel.splitPayload(payload), sharedKey: sharedKey))
    }

    func testRandomAlphanumeric() {
        let value = String.randomAlphanumeric(length: 32)
        XCTAssertEqual(value.count, 32)
        XCTAssertTrue(value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
        XCTAssertNotEqual(value, String.randomAlphanumeric(length: 32))
    }
}
