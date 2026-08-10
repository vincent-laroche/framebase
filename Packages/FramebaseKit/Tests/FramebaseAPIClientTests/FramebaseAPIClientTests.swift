import Foundation
import FramebaseAPIClient
import Testing

@Suite("Framebase API client")
struct FramebaseAPIClientTests {
    @Test("Sessions become unavailable shortly before expiry")
    func sessionExpirySafetyMargin() {
        let usable = DeviceSession(deviceID: "fixture-device", token: "fixture-token", expiresAt: .now.addingTimeInterval(120))
        let expired = DeviceSession(deviceID: "fixture-device", token: "fixture-token", expiresAt: .now.addingTimeInterval(10))
        #expect(usable.isUsable)
        #expect(!expired.isUsable)
    }
}
