import Foundation
import XCTest
@testable import PrompterCore

final class DevicePickerProtocolTests: XCTestCase {
  private enum LegacySelection: Decodable { case selectCamera(String), selectMicrophone(String) }

  func testOldSelectionCommandsDecodeWithoutDestination() throws {
    let decoder = JSONDecoder()
    XCTAssertEqual(try decoder.decode(PadRemote.Command.self, from: Data(#"{"selectCamera":{"_0":"camera"}}"#.utf8)), .selectCamera("camera"))
    XCTAssertEqual(try decoder.decode(PadRemote.Command.self, from: Data(#"{"selectMicrophone":{"_0":"mic"}}"#.utf8)), .selectMicrophone("mic"))
  }

  func testSelectionDestinationKeepsLegacyPayloadAndRoundTrips() throws {
    for command in [PadRemote.Command.selectCamera("camera", onIPad: true), .selectMicrophone("mic", onIPad: true)] {
      let data = try JSONEncoder().encode(command)
      XCTAssertEqual(try JSONDecoder().decode(PadRemote.Command.self, from: data), command)
      XCTAssertNoThrow(try JSONDecoder().decode(LegacySelection.self, from: data))
      let outer = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
      let payload = try XCTUnwrap(outer.values.first)
      XCTAssertNotNil(payload["_0"])
      XCTAssertEqual(payload["onIPad"] as? Bool, true)
    }
  }

  func testOptionalRotationFieldsRoundTripAndOldPayloadsStillDecode() throws {
    let decoder = JSONDecoder()
    XCTAssertNil(try decoder.decode(PadRemote.Guides.self, from: Data("{}".utf8)).rotation)
    XCTAssertNil(try decoder.decode(PadRemote.MacStatus.self, from: Data("{}".utf8)).cameraRotation)
    for angle in [0, 90, 180, 270] {
      let command = PadRemote.Command.cameraGuides(.init(rotation: angle))
      XCTAssertEqual(try decoder.decode(PadRemote.Command.self, from: JSONEncoder().encode(command)), command)
      let status = PadRemote.MacStatus(cameraRotation: angle)
      XCTAssertEqual(try decoder.decode(PadRemote.MacStatus.self, from: JSONEncoder().encode(status)), status)
    }
  }

  func testLocalDeviceStateIsOptionalForOlderPeers() throws {
    var state = PadRemote.State(scripts: [], presenting: nil, running: false, mode: "Manual", speed: 120, word: 0, words: 0)
    let legacy = try JSONEncoder().encode(state)
    XCTAssertNil(try JSONDecoder().decode(PadRemote.State.self, from: legacy).localCameras)
    state.localCameras = [.init(id: "camera", name: "iPad camera")]
    state.localMicrophones = [.init(id: "mic", name: "iPad microphone")]
    state.localCameraID = "camera"
    state.localCameraOn = true
    state.cameraUsesMac = false
    XCTAssertEqual(try JSONDecoder().decode(PadRemote.State.self, from: JSONEncoder().encode(state)), state)
  }
}
