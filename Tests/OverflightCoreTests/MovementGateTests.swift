import XCTest
@testable import OverflightCore

final class MovementGateTests: XCTestCase {
	// ~0.001 deg latitude is ~111m.
	func testFirstSightingAdmitted() {
		var gate = MovementGate(floorS: 30, minMoveM: 100, stampS: 600)
		XCTAssertTrue(gate.admit(vid: "a", ts: 1000, lat: 47.0, lon: -122.0))
	}

	func testFloorDropsFastRepeats() {
		var gate = MovementGate(floorS: 30, minMoveM: 100, stampS: 600)
		_ = gate.admit(vid: "a", ts: 1000, lat: 47.0, lon: -122.0)
		// Moved plenty, but 10s after the last kept point — under the floor.
		XCTAssertFalse(gate.admit(vid: "a", ts: 1010, lat: 47.01, lon: -122.0))
		// Past the floor and moved: admitted.
		XCTAssertTrue(gate.admit(vid: "a", ts: 1031, lat: 47.01, lon: -122.0))
	}

	func testParkedVehicleDroppedUntilStamp() {
		var gate = MovementGate(floorS: 30, minMoveM: 100, stampS: 600)
		_ = gate.admit(vid: "a", ts: 1000, lat: 47.0, lon: -122.0)
		// Not moving: dropped past the floor, dropped at 5 minutes...
		XCTAssertFalse(gate.admit(vid: "a", ts: 1300, lat: 47.0, lon: -122.0))
		// ...admitted at the stamp interval even without movement.
		XCTAssertTrue(gate.admit(vid: "a", ts: 1600, lat: 47.0, lon: -122.0))
		// And the stamp resets the clock.
		XCTAssertFalse(gate.admit(vid: "a", ts: 1900, lat: 47.0, lon: -122.0))
	}

	func testSmallDriftAccumulatesToAdmission() {
		var gate = MovementGate(floorS: 30, minMoveM: 100, stampS: 600)
		_ = gate.admit(vid: "a", ts: 1000, lat: 47.0, lon: -122.0)
		// 55m from the kept point: dropped (under min move).
		XCTAssertFalse(gate.admit(vid: "a", ts: 1060, lat: 47.0005, lon: -122.0))
		// 111m from the kept point (distance measures from last KEPT, not
		// last seen, so slow drift still earns points): admitted.
		XCTAssertTrue(gate.admit(vid: "a", ts: 1120, lat: 47.001, lon: -122.0))
	}

	func testVehiclesAreIndependent() {
		var gate = MovementGate(floorS: 30, minMoveM: 100, stampS: 600)
		_ = gate.admit(vid: "a", ts: 1000, lat: 47.0, lon: -122.0)
		XCTAssertTrue(gate.admit(vid: "b", ts: 1001, lat: 47.0, lon: -122.0))
	}

	func testZeroFloorAdmitsEveryMove() {
		var gate = MovementGate(floorS: 0, minMoveM: 25, stampS: 600)
		_ = gate.admit(vid: "t", ts: 1000, lat: 40.0, lon: -75.0)
		XCTAssertTrue(gate.admit(vid: "t", ts: 1060, lat: 40.001, lon: -75.0))
		XCTAssertFalse(gate.admit(vid: "t", ts: 1120, lat: 40.001, lon: -75.0))
	}

	func testPruneForgetsStaleVehicles() {
		var gate = MovementGate(floorS: 30, minMoveM: 100, stampS: 600)
		_ = gate.admit(vid: "a", ts: 1000, lat: 47.0, lon: -122.0)
		_ = gate.admit(vid: "b", ts: 30000, lat: 47.0, lon: -122.0)
		gate.prune(now: 30000, olderThanS: 6 * 3600)
		XCTAssertEqual(gate.trackedCount, 1)
		// A pruned vehicle reads as a first sighting again.
		XCTAssertTrue(gate.admit(vid: "a", ts: 30001, lat: 47.0, lon: -122.0))
	}
}
