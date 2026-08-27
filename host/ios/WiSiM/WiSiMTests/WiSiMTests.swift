import XCTest
@testable import WiSiM

final class WiSiMTests: XCTestCase {
    func testManagementEndpoints() throws {
        XCTAssertEqual(try ManagementEndpoint.normalize("192.168.4.1").absoluteString, "http://192.168.4.1")
        XCTAssertEqual(try ManagementEndpoint.normalize("http://192.168.5.1/").absoluteString, "http://192.168.5.1")
        XCTAssertThrowsError(try ManagementEndpoint.normalize("http://example.com"))
        XCTAssertThrowsError(try ManagementEndpoint.normalize("http://user:pass@192.168.4.1"))
    }

    func testSMSContactIdentity() throws {
        let json = #"{"imsi":"test-imsi","peer":"+999000000000","device_id":"all","last_sms_id":7,"last_timestamp":"now","last_content":"hello","unread_count":1,"device_name":"UFI","local_phone":null}"#.data(using: .utf8)!
        let contact = try JSONDecoder().decode(SMSContact.self, from: json)
        XCTAssertEqual(contact.id, "test-imsi|+999000000000")
        XCTAssertEqual(contact.unreadCount, 1)
    }

    func testVoiceCapabilityLabelsRemainTruthful() {
        XCTAssertEqual(VoiceSupport.unsupported("x").title, "不支持")
        XCTAssertEqual(VoiceSupport.needsMacRelay("x").title, "需要 Mac 中继")
    }

    func testManagedHardwareLabelsRemainTruthful() {
        let relay = ManagedHardwareAvailability.macRelayRequired("relay")
        XCTAssertEqual(ManagedHardwareKind.djiQDC507.title, "大疆 QDC507")
        XCTAssertEqual(relay.title, "需要 Mac 中继")
        XCTAssertEqual(relay.detail, "relay")
    }
}
