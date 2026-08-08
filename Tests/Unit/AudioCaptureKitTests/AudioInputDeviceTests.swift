import AudioCaptureKit
import XCTest

final class AudioInputDeviceTests: XCTestCase {
    func testEveryListedInputHasAUsableIdentity() throws {
        let devices = AudioInputDevices.available()
        try XCTSkipIf(devices.isEmpty, "This machine exposes no audio input.")

        for device in devices {
            XCTAssertFalse(device.id.isEmpty, "A device without a UID cannot be persisted.")
            XCTAssertFalse(device.name.isEmpty, "A device without a name cannot be offered.")
        }
    }

    func testStoredUIDsResolveBackToLiveDevices() throws {
        let devices = AudioInputDevices.available()
        try XCTSkipIf(devices.isEmpty, "This machine exposes no audio input.")

        // The picker persists the UID and the capture session resolves it again at start time;
        // if that round-trip broke, a chosen microphone would silently fall back to the default.
        for device in devices {
            XCTAssertNotNil(
                AudioInputDevices.deviceID(forUID: device.id),
                "\(device.name) could not be resolved from its stored UID."
            )
        }
    }

    func testUnknownUIDResolvesToNothing() {
        XCTAssertNil(AudioInputDevices.deviceID(forUID: "voxol.device.that.does.not.exist"))
    }

    func testAtMostOneDeviceClaimsToBeTheSystemDefault() throws {
        let devices = AudioInputDevices.available()
        try XCTSkipIf(devices.isEmpty, "This machine exposes no audio input.")
        XCTAssertLessThanOrEqual(devices.filter(\.isDefault).count, 1)
    }
}
