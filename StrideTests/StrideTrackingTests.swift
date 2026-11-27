import XCTest
import CoreLocation
import SwiftData
@testable import Stride

private enum SimulatedPersistenceError: Error {
    case diskWriteFailed
}

@MainActor
final class StrideTrackingTests: XCTestCase {
    private var container: ModelContainer!
    private var shouldFailSave = false
    private var store: LocalDatabaseStore!
    private var settings: AppSettings!
    private var locationService: LocationManagerService!
    private var controller: WorkoutSessionController!

    override func setUp() async throws {
        shouldFailSave = false
        let schema = Schema([
            WorkoutActivity.self,
            TrackPoint.self,
            ActivitySplit.self,
            AppSettings.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        store = LocalDatabaseStore(modelContext: context) { [weak self] in
            if self?.shouldFailSave == true {
                throw SimulatedPersistenceError.diskWriteFailed
            }
            if context.hasChanges {
                try context.save()
            }
        }

        settings = store.fetchOrCreateSettings()
        settings.autoPauseEnabled = true
        settings.autoPauseSpeedThresholdMPS = 0.45
        settings.useBarometerWhenAvailable = true
        locationService = LocationManagerService()
        controller = WorkoutSessionController(
            locationService: locationService,
            store: store,
            settings: settings
        )
    }

    override func tearDown() async throws {
        controller = nil
        locationService = nil
        settings = nil
        store = nil
        container = nil
    }

    func testFirstGPSReadingDoesNotCountAsStationaryConfirmation() {
        let engine = GPSFilterEngine()
        let config = GPSFilterConfig.for(activityType: .walking, maxAccuracy: 25.0)
        let t0 = Date(timeIntervalSince1970: 1_700_000_050)
        let coord = CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.81980)

        let p1 = CLLocation(coordinate: coord, altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0, timestamp: t0)
        let d1 = engine.evaluate(location: p1, config: config, now: t0)

        XCTAssertEqual(engine.stationarySampleCount, 0)
        XCTAssertEqual(d1, .accept(distanceDeltaMeters: 0, impliedSpeedMPS: 0, movementState: .unknownOrUnconfirmed, isRoutePoint: false))

        let p2 = CLLocation(coordinate: coord, altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0, timestamp: t0.addingTimeInterval(3))
        let d2 = engine.evaluate(location: p2, config: config, now: t0.addingTimeInterval(3))
        XCTAssertEqual(engine.stationarySampleCount, 1)
        XCTAssertEqual(d2, .accept(distanceDeltaMeters: 0, impliedSpeedMPS: 0, movementState: .unknownOrUnconfirmed, isRoutePoint: false))
    }

    func testTwoIdenticalGPSPositionsDoNotConfirmMovement() {
        let engine = GPSFilterEngine()
        let config = GPSFilterConfig.for(activityType: .running, maxAccuracy: 25.0)
        let t0 = Date(timeIntervalSince1970: 1_700_000_100)
        let coord = CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.81980)

        let p1 = CLLocation(coordinate: coord, altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0, timestamp: t0)
        let p2 = CLLocation(coordinate: coord, altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0, timestamp: t0.addingTimeInterval(3))
        let p3 = CLLocation(coordinate: coord, altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0, timestamp: t0.addingTimeInterval(6))

        _ = engine.evaluate(location: p1, config: config, now: t0)
        let d2 = engine.evaluate(location: p2, config: config, now: t0.addingTimeInterval(3))
        let d3 = engine.evaluate(location: p3, config: config, now: t0.addingTimeInterval(6))

        XCTAssertEqual(d2, .accept(distanceDeltaMeters: 0, impliedSpeedMPS: 0, movementState: .unknownOrUnconfirmed, isRoutePoint: false))
        XCTAssertEqual(d3, .accept(distanceDeltaMeters: 0, impliedSpeedMPS: 0, movementState: .confirmedStationary, isRoutePoint: false))
    }

    func testStationaryDriftDoesNotCreateAcceptedRoutePointsOrAddDistance() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        controller.beginWorkoutSession(now: t0)

        let origin = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819800),
            altitude: 15,
            horizontalAccuracy: 10,
            verticalAccuracy: 5,
            course: 0,
            speed: 0.0,
            timestamp: t0
        )
        let driftedCoord = CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819881)

        controller.handleIncomingLocation(origin, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0)

        for idx in 1...4 {
            let driftLoc = CLLocation(
                coordinate: driftedCoord,
                altitude: 15,
                horizontalAccuracy: 10,
                verticalAccuracy: 5,
                course: 0,
                speed: 0.0,
                timestamp: t0.addingTimeInterval(Double(idx * 3))
            )
            controller.handleIncomingLocation(
                driftLoc,
                barometricRelativeAltitude: 0,
                isBarometerActive: true,
                now: t0.addingTimeInterval(Double(idx * 3))
            )
        }

        _ = store.flushPendingTrackPoints(now: t0.addingTimeInterval(15))
        let activity = store.fetchInProgressActivity()
        let acceptedRoutePoints = activity?.trackPoints.filter(\.isAccepted) ?? []

        XCTAssertEqual(controller.totalDistanceMeters, 0, accuracy: 0.001)
        XCTAssertEqual(controller.acceptedPointCount, 0)
        XCTAssertEqual(controller.movingTimeSeconds, 0, accuracy: 0.001)
        XCTAssertTrue(acceptedRoutePoints.isEmpty)
    }

    func testGenuineContinuousMovementAcrossCycling() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_200)
        controller.selectedActivityType = .cycling
        controller.beginWorkoutSession(now: t0)

        let steps: [(Double, TimeInterval)] = [
            (0.00000, 0.0),
            (0.00022, 3.0),
            (0.00046, 6.5),
            (0.00072, 11.0)
        ]

        for (dLon, dt) in steps {
            let loc = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 1.3521, longitude: 103.8198 + dLon),
                altitude: 12,
                horizontalAccuracy: 5,
                verticalAccuracy: 5,
                course: 90,
                speed: 7.5,
                timestamp: t0.addingTimeInterval(dt)
            )
            controller.handleIncomingLocation(loc, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(dt))
        }

        XCTAssertGreaterThan(controller.totalDistanceMeters, 60)
        XCTAssertGreaterThan(controller.currentSpeedMPS, 3.0)
    }

    func testMovementConfirmationRequiresThreeSamplesAfterAnchor() {
        let engine = GPSFilterEngine()
        let config = GPSFilterConfig.for(activityType: .running, maxAccuracy: 25.0)
        let t0 = Date(timeIntervalSince1970: 1_700_000_255)

        let p0 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819800), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0)
        let p1 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819840), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(2))
        let p2 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819880), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(4))
        let p3 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819920), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(6))

        let d0 = engine.evaluate(location: p0, config: config, now: t0)
        let d1 = engine.evaluate(location: p1, config: config, now: t0.addingTimeInterval(2))
        let d2 = engine.evaluate(location: p2, config: config, now: t0.addingTimeInterval(4))
        let d3 = engine.evaluate(location: p3, config: config, now: t0.addingTimeInterval(6))

        XCTAssertEqual(d0, .accept(distanceDeltaMeters: 0, impliedSpeedMPS: 0, movementState: .unknownOrUnconfirmed, isRoutePoint: false))
        XCTAssertEqual(d1, .accept(distanceDeltaMeters: 0, impliedSpeedMPS: 0, movementState: .unknownOrUnconfirmed, isRoutePoint: false))
        XCTAssertEqual(d2, .accept(distanceDeltaMeters: 0, impliedSpeedMPS: 0, movementState: .unknownOrUnconfirmed, isRoutePoint: false))

        if case .accept(let dist3, let speed3, let state3, let isRoute3) = d3 {
            XCTAssertEqual(state3, .confirmedMoving)
            XCTAssertTrue(isRoute3)
            XCTAssertEqual(dist3, p3.distance(from: p0), accuracy: 0.01)
            XCTAssertGreaterThan(speed3, 0)
            XCTAssertLessThanOrEqual(speed3, config.maxPlausibleSpeedMPS)
        } else {
            XCTFail("Expected 3rd moving sample after anchor to confirm movement and accept route point")
        }
    }

    func testMovingTimeDoesNotStopBetweenAcceptedRoutePoints() {
        let engine = GPSFilterEngine()
        let config = GPSFilterConfig.for(activityType: .running, maxAccuracy: 25.0)
        let t0 = Date(timeIntervalSince1970: 1_700_000_260)

        let p0 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819800), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0)
        let p1 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819840), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(2))
        let p2 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819880), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(4))
        let p3 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819920), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(6))

        _ = engine.evaluate(location: p0, config: config, now: t0)
        _ = engine.evaluate(location: p1, config: config, now: t0.addingTimeInterval(2))
        _ = engine.evaluate(location: p2, config: config, now: t0.addingTimeInterval(4))
        let d3 = engine.evaluate(location: p3, config: config, now: t0.addingTimeInterval(6))
        let expectedRouteSpeed = max(p3.distance(from: p0) / 6.0, p3.speed)
        XCTAssertEqual(
            d3,
            .accept(
                distanceDeltaMeters: p3.distance(from: p0),
                impliedSpeedMPS: min(expectedRouteSpeed, config.maxPlausibleSpeedMPS),
                movementState: .confirmedMoving,
                isRoutePoint: true
            )
        )

        let s1 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819929), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 1.0, timestamp: t0.addingTimeInterval(7))
        let ds1 = engine.evaluate(location: s1, config: config, now: t0.addingTimeInterval(7))
        if case .accept(let distS1, let speedS1, let stateS1, let isRouteS1) = ds1 {
            XCTAssertEqual(stateS1, .confirmedMoving)
            XCTAssertFalse(isRouteS1)
            XCTAssertEqual(distS1, 0, accuracy: 0.001)
            XCTAssertGreaterThan(speedS1, 0)
        } else {
            XCTFail("Expected sub-threshold reading to keep confirmedMoving")
        }

        controller.selectedActivityType = .running
        controller.beginWorkoutSession(now: t0)
        controller.handleIncomingLocation(p0, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0)
        controller.handleIncomingLocation(p1, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(2))
        controller.handleIncomingLocation(p2, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(4))
        XCTAssertEqual(controller.currentFilterMovementState, .unknownOrUnconfirmed)
        XCTAssertEqual(controller.acceptedPointCount, 0)

        controller.handleIncomingLocation(p3, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(6))
        XCTAssertEqual(controller.currentFilterMovementState, .confirmedMoving)
        XCTAssertEqual(controller.acceptedPointCount, 1)
        let distanceAfterP3 = controller.totalDistanceMeters

        controller.advanceClocks(to: t0.addingTimeInterval(7))
        XCTAssertEqual(controller.movingTimeSeconds, 1.0, accuracy: 0.01)

        controller.handleIncomingLocation(s1, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(7))
        XCTAssertEqual(controller.currentFilterMovementState, .confirmedMoving)
        XCTAssertEqual(controller.acceptedPointCount, 1)
        XCTAssertEqual(controller.totalDistanceMeters, distanceAfterP3, accuracy: 0.001)
        XCTAssertGreaterThan(controller.currentSpeedMPS, 0.0)
        XCTAssertNotNil(controller.currentPaceSecPerKm)

        controller.advanceClocks(to: t0.addingTimeInterval(9))
        XCTAssertEqual(controller.movingTimeSeconds, 3.0, accuracy: 0.01)
    }

    func testConfirmedMovementMaintainedThroughSubThresholdStepsAndEmitsDistanceOnceAtRoutePoint() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_265)
        controller.selectedActivityType = .running
        controller.beginWorkoutSession(now: t0)

        let p0 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819800), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0)
        let p1 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819840), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(2))
        let p2 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819880), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(4))
        let p3 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819920), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(6))

        controller.handleIncomingLocation(p0, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0)
        controller.handleIncomingLocation(p1, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(2))
        controller.handleIncomingLocation(p2, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(4))
        controller.handleIncomingLocation(p3, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(6))

        let firstRouteDistance = p3.distance(from: p0)
        XCTAssertEqual(controller.currentFilterMovementState, .confirmedMoving)
        XCTAssertEqual(controller.acceptedPointCount, 1)
        XCTAssertEqual(controller.totalDistanceMeters, firstRouteDistance, accuracy: 0.01)

        let s1 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819929), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 1.0, timestamp: t0.addingTimeInterval(7))
        let s2 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819938), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 1.0, timestamp: t0.addingTimeInterval(8))
        let s3 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819947), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 1.0, timestamp: t0.addingTimeInterval(9))
        let s4 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819956), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 1.0, timestamp: t0.addingTimeInterval(10))

        for (stepLoc, offset) in [(s1, 7.0), (s2, 8.0), (s3, 9.0)] {
            controller.handleIncomingLocation(stepLoc, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(offset))
            XCTAssertEqual(controller.currentFilterMovementState, .confirmedMoving)
            XCTAssertEqual(controller.acceptedPointCount, 1)
            XCTAssertEqual(controller.totalDistanceMeters, firstRouteDistance, accuracy: 0.01)
        }

        controller.handleIncomingLocation(s4, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(10))
        let expectedTotalAfterS4 = firstRouteDistance + s4.distance(from: p3)
        XCTAssertEqual(controller.currentFilterMovementState, .confirmedMoving)
        XCTAssertEqual(controller.acceptedPointCount, 2)
        XCTAssertEqual(controller.totalDistanceMeters, expectedTotalAfterS4, accuracy: 0.01)

        let s5 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819961), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 0.5, timestamp: t0.addingTimeInterval(11))
        controller.handleIncomingLocation(s5, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(11))
        XCTAssertEqual(controller.acceptedPointCount, 2)
        XCTAssertEqual(controller.totalDistanceMeters, expectedTotalAfterS4, accuracy: 0.01)
    }

    func testSubThresholdDisplacementWithInvalidSpeedDoesNotConfirmMovement() {
        let engine = GPSFilterEngine()
        let config = GPSFilterConfig.for(activityType: .walking, maxAccuracy: 25.0)
        let t0 = Date(timeIntervalSince1970: 1_700_000_305)

        let anchor = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819800), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: -1, timestamp: t0)
        let d0 = engine.evaluate(location: anchor, config: config, now: t0)
        XCTAssertEqual(d0, .accept(distanceDeltaMeters: 0, impliedSpeedMPS: 0, movementState: .unknownOrUnconfirmed, isRoutePoint: false))

        let samples: [(Double, TimeInterval)] = [
            (0.000020, 2.0),
            (0.000002, 4.0),
            (0.000022, 6.0),
            (0.000004, 8.0)
        ]

        for (dLon, dt) in samples {
            let loc = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819800 + dLon),
                altitude: 10,
                horizontalAccuracy: 5,
                verticalAccuracy: 5,
                course: 90,
                speed: -1,
                timestamp: t0.addingTimeInterval(dt)
            )
            let decision = engine.evaluate(location: loc, config: config, now: t0.addingTimeInterval(dt))
            if case .accept(let dist, _, let state, let isRoutePoint) = decision {
                XCTAssertNotEqual(state, .confirmedMoving)
                XCTAssertFalse(isRoutePoint)
                XCTAssertEqual(dist, 0, accuracy: 0.001)
            } else {
                XCTFail("Expected sub-threshold reading with speed=-1 to be accepted without confirming movement")
            }
        }
    }

    func testPositionalDriftExceedingAccuracyFloorWithInvalidSpeed() {
        let engine = GPSFilterEngine()
        let config = GPSFilterConfig.for(activityType: .walking, maxAccuracy: 25.0)
        let t0 = Date(timeIntervalSince1970: 1_700_000_315)

        let p0 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819800), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: -1, timestamp: t0)
        let p1 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819832), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: -1, timestamp: t0.addingTimeInterval(3))
        let p2 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819864), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: -1, timestamp: t0.addingTimeInterval(6))
        let p3 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819896), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: -1, timestamp: t0.addingTimeInterval(9))

        _ = engine.evaluate(location: p0, config: config, now: t0)
        _ = engine.evaluate(location: p1, config: config, now: t0.addingTimeInterval(3))
        _ = engine.evaluate(location: p2, config: config, now: t0.addingTimeInterval(6))
        let d3 = engine.evaluate(location: p3, config: config, now: t0.addingTimeInterval(9))

        guard case .accept(let dist, let speed, let state, let isRoutePoint) = d3 else {
            XCTFail("Expected evaluation to return .accept")
            return
        }
        XCTAssertEqual(state, .confirmedMoving)
        XCTAssertTrue(isRoutePoint)
        XCTAssertGreaterThanOrEqual(dist, config.minMovementThresholdMeters)
        XCTAssertGreaterThan(speed, 0)
        XCTAssertLessThanOrEqual(speed, config.maxPlausibleSpeedMPS)
    }

    func testFutureGPSTimestampIsRejected() {
        let engine = GPSFilterEngine()
        let config = GPSFilterConfig.for(activityType: .walking, maxAccuracy: 25.0, maxFutureToleranceSeconds: 2.0)
        let t0 = Date(timeIntervalSince1970: 1_700_000_280)

        let p1 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819800), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 1.2, timestamp: t0)
        let futureLoc = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819850), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 1.2, timestamp: t0.addingTimeInterval(10))

        _ = engine.evaluate(location: p1, config: config, now: t0)
        let decision = engine.evaluate(location: futureLoc, config: config, now: t0)
        XCTAssertEqual(decision, .reject(reason: "Future timestamp"))
    }

    func testGPSTeleportationJumpIsRejected() {
        let engine = GPSFilterEngine()
        let config = GPSFilterConfig.for(activityType: .walking, maxAccuracy: 25.0)
        let t0 = Date(timeIntervalSince1970: 1_700_000_300)

        let p1 = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 1.3521, longitude: 103.8198),
            altitude: 10,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 0,
            speed: 1.2,
            timestamp: t0
        )
        let jump = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 1.3620, longitude: 103.8198),
            altitude: 10,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 0,
            speed: 1.2,
            timestamp: t0.addingTimeInterval(2)
        )

        _ = engine.evaluate(location: p1, config: config, now: t0)
        let decision = engine.evaluate(location: jump, config: config, now: t0.addingTimeInterval(2))

        if case .reject = decision {
            // Expected jump rejection
        } else {
            XCTFail("Expected GPS teleportation jump to be rejected")
        }
    }

    func testSlowWalkingMovementIsRecognised() {
        let engine = GPSFilterEngine()
        let config = GPSFilterConfig.for(activityType: .walking, maxAccuracy: 25.0)
        let t0 = Date(timeIntervalSince1970: 1_700_000_400)

        let p1 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819800), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 0.9, timestamp: t0)
        let p2 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819842), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 0.9, timestamp: t0.addingTimeInterval(5))
        let p3 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819885), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 0.9, timestamp: t0.addingTimeInterval(10))

        _ = engine.evaluate(location: p1, config: config, now: t0)
        _ = engine.evaluate(location: p2, config: config, now: t0.addingTimeInterval(5))
        let d3 = engine.evaluate(location: p3, config: config, now: t0.addingTimeInterval(10))

        guard case .accept(let dist, _, let movementState, let isRoutePoint) = d3 else {
            XCTFail("Expected slow walk to be accepted")
            return
        }
        XCTAssertEqual(movementState, .confirmedMoving)
        XCTAssertTrue(isRoutePoint)
        XCTAssertGreaterThan(dist, 4.0)
    }

    func testMovingTimeExcludesStationaryAndAutoPauseGracePeriod() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_450)
        controller.selectedActivityType = .walking
        controller.beginWorkoutSession(now: t0)

        let m0 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.81980), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 1.5, timestamp: t0)
        let m4 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.81990), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 1.5, timestamp: t0.addingTimeInterval(4))
        let m8 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.82000), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 1.5, timestamp: t0.addingTimeInterval(8))
        controller.handleIncomingLocation(m0, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0)
        controller.handleIncomingLocation(m4, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(4))
        controller.handleIncomingLocation(m8, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(8))

        let movingAtT8 = controller.movingTimeSeconds
        XCTAssertEqual(movingAtT8, 0.0, accuracy: 0.01)

        let s10 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.82000), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 0.0, timestamp: t0.addingTimeInterval(10))
        let s12 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.82000), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 0.0, timestamp: t0.addingTimeInterval(12))
        controller.handleIncomingLocation(s10, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(10))
        controller.handleIncomingLocation(s12, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(12))
        controller.advanceClocks(to: t0.addingTimeInterval(24))

        XCTAssertEqual(controller.state, .paused(isAutomatic: true))
        XCTAssertEqual(controller.elapsedTimeSeconds, 24.0, accuracy: 0.01)
        XCTAssertEqual(controller.movingTimeSeconds, movingAtT8, accuracy: 0.01)
    }

    func testMovingTimeAfterConfirmationIncludesIntervalBeforeAutoPause() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_460)
        controller.selectedActivityType = .walking
        controller.beginWorkoutSession(now: t0)

        let m0 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.81980), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 1.5, timestamp: t0)
        let m4 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.81990), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 1.5, timestamp: t0.addingTimeInterval(4))
        let m8 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.82000), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 1.5, timestamp: t0.addingTimeInterval(8))
        controller.handleIncomingLocation(m0, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0)
        controller.handleIncomingLocation(m4, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(4))
        controller.handleIncomingLocation(m8, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(8))

        controller.advanceClocks(to: t0.addingTimeInterval(11))
        XCTAssertEqual(controller.movingTimeSeconds, 3.0, accuracy: 0.01)

        let s12 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.82000), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 0.0, timestamp: t0.addingTimeInterval(12))
        controller.handleIncomingLocation(s12, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(12))
        XCTAssertEqual(controller.movingTimeSeconds, 4.0, accuracy: 0.01)

        let s13 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.82000), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 0.0, timestamp: t0.addingTimeInterval(13))
        controller.handleIncomingLocation(s13, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(13))
        controller.advanceClocks(to: t0.addingTimeInterval(25))

        XCTAssertEqual(controller.state, .paused(isAutomatic: true))
        XCTAssertEqual(controller.movingTimeSeconds, 4.0, accuracy: 0.01)
    }

    func testMovingTimeStopsWhenGPSReadingsGoStaleOverSeveralMinutes() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_470)
        controller.selectedActivityType = .running
        controller.beginWorkoutSession(now: t0)

        let m0 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.81980), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0)
        let m2 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.81988), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(2))
        let m4 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.81998), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(4))
        controller.handleIncomingLocation(m0, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0)
        controller.handleIncomingLocation(m2, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(2))
        controller.handleIncomingLocation(m4, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(4))

        controller.advanceClocks(to: t0.addingTimeInterval(10))
        XCTAssertEqual(controller.movingTimeSeconds, 6.0, accuracy: 0.01)

        controller.advanceClocks(to: t0.addingTimeInterval(190))
        XCTAssertEqual(controller.movingTimeSeconds, 10.0, accuracy: 0.01)
    }

    func testStationaryDurationResetsAfterSlowMovement() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_480)
        controller.selectedActivityType = .walking
        controller.beginWorkoutSession(now: t0)

        let m0 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.81980), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 1.2, timestamp: t0)
        let m3 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.81986), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 1.2, timestamp: t0.addingTimeInterval(3))
        controller.handleIncomingLocation(m0, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0)
        controller.handleIncomingLocation(m3, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(3))

        let s5 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.81986), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 0.0, timestamp: t0.addingTimeInterval(5))
        let s7 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.81986), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 0.0, timestamp: t0.addingTimeInterval(7))
        controller.handleIncomingLocation(s5, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(5))
        controller.handleIncomingLocation(s7, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(7))
        controller.advanceClocks(to: t0.addingTimeInterval(14))
        XCTAssertEqual(controller.state, .recording)

        let slow16 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.81989), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 0.5, timestamp: t0.addingTimeInterval(16))
        let slow19 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.81993), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 0.5, timestamp: t0.addingTimeInterval(19))
        controller.handleIncomingLocation(slow16, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(16))
        controller.handleIncomingLocation(slow19, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(19))

        let stop21 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.81993), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 0.0, timestamp: t0.addingTimeInterval(21))
        let stop23 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.81993), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 0.0, timestamp: t0.addingTimeInterval(23))
        controller.handleIncomingLocation(stop21, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(21))
        controller.handleIncomingLocation(stop23, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(23))
        controller.advanceClocks(to: t0.addingTimeInterval(34))
        XCTAssertEqual(controller.state, .recording)
    }

    func testActualTwelveSecondAutoPauseTiming() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_500)
        controller.selectedActivityType = .walking
        controller.beginWorkoutSession(now: t0)

        let m1 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.81980), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 1.5, timestamp: t0)
        let m2 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.81990), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 1.5, timestamp: t0.addingTimeInterval(4))
        let m3 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.82000), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 1.5, timestamp: t0.addingTimeInterval(8))
        controller.handleIncomingLocation(m1, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0)
        controller.handleIncomingLocation(m2, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(4))
        controller.handleIncomingLocation(m3, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(8))
        XCTAssertEqual(controller.state, .recording)

        let stop14 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.82000), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 0.0, timestamp: t0.addingTimeInterval(14))
        let stop15 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.82000), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 0.0, timestamp: t0.addingTimeInterval(15))
        controller.handleIncomingLocation(stop14, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(14))
        controller.handleIncomingLocation(stop15, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(15))

        controller.advanceClocks(to: t0.addingTimeInterval(25))
        XCTAssertEqual(controller.state, .recording)

        controller.advanceClocks(to: t0.addingTimeInterval(26))
        XCTAssertEqual(controller.state, .recording)

        controller.advanceClocks(to: t0.addingTimeInterval(27))
        XCTAssertEqual(controller.state, .paused(isAutomatic: true))
    }

    func testActualFourSecondAutomaticResume() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_600)
        controller.selectedActivityType = .running
        controller.beginWorkoutSession(now: t0)
        controller.pauseWorkout(automatic: true, now: t0.addingTimeInterval(10))
        XCTAssertEqual(controller.state, .paused(isAutomatic: true))

        let r1 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819800), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(12.0))
        let r2 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819840), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(13.5))
        let r3 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819881), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(15.0))
        controller.handleIncomingLocation(r1, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(12.0))
        controller.handleIncomingLocation(r2, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(13.5))
        controller.handleIncomingLocation(r3, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(15.0))

        controller.advanceClocks(to: t0.addingTimeInterval(17.0))
        let r4 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819935), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(17.0))
        controller.handleIncomingLocation(r4, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(17.0))

        controller.advanceClocks(to: t0.addingTimeInterval(18.9))
        XCTAssertEqual(controller.state, .paused(isAutomatic: true))

        controller.advanceClocks(to: t0.addingTimeInterval(19.0))
        XCTAssertEqual(controller.state, .recording)
    }

    func testAutoResumeDoesNotCountIntervalBeforeFirstConfirmedMovementSample() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_665)
        controller.selectedActivityType = .running
        controller.beginWorkoutSession(now: t0)
        controller.pauseWorkout(automatic: true, now: t0.addingTimeInterval(10))

        let r1 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819800), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(12))
        let r2 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819827), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(13))
        let r3 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819854), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(14))
        controller.handleIncomingLocation(r1, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(12))
        controller.handleIncomingLocation(r2, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(13))
        controller.handleIncomingLocation(r3, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(14))

        controller.advanceClocks(to: t0.addingTimeInterval(17.9))
        XCTAssertEqual(controller.state, .paused(isAutomatic: true))

        controller.advanceClocks(to: t0.addingTimeInterval(18.0))
        XCTAssertEqual(controller.state, .recording)
    }

    func testAutoResumeTriggersFromClockAloneAfterMovementConfirmationWithoutExtraGPS() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_675)
        controller.selectedActivityType = .running
        controller.beginWorkoutSession(now: t0)
        controller.pauseWorkout(automatic: true, now: t0.addingTimeInterval(10))

        let r1 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819800), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(12))
        let r2 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819827), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(13))
        let r3 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819854), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(14))
        controller.handleIncomingLocation(r1, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(12))
        controller.handleIncomingLocation(r2, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(13))
        controller.handleIncomingLocation(r3, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(14))

        controller.advanceClocks(to: t0.addingTimeInterval(18))
        XCTAssertEqual(controller.state, .recording)
    }

    func testFourSecondAutoResumeThresholdAtSameTimestampAsStationaryReadingDoesNotResume() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_670)
        controller.selectedActivityType = .running
        controller.beginWorkoutSession(now: t0)
        controller.pauseWorkout(automatic: true, now: t0.addingTimeInterval(10))

        let r1 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819800), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(12))
        let r2 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819827), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(13))
        let r3 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819854), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(14))
        controller.handleIncomingLocation(r1, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(12))
        controller.handleIncomingLocation(r2, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(13))
        controller.handleIncomingLocation(r3, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(14))

        controller.advanceClocks(to: t0.addingTimeInterval(17.9))
        let stop18 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819854), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 0.0, timestamp: t0.addingTimeInterval(18.0))
        controller.handleIncomingLocation(stop18, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(18.0))

        XCTAssertEqual(controller.state, .paused(isAutomatic: true))
    }

    func testAutoResumeConfirmationFollowedByUnknownReadingResetsResumeState() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_660)
        controller.selectedActivityType = .running
        controller.beginWorkoutSession(now: t0)
        controller.pauseWorkout(automatic: true, now: t0.addingTimeInterval(10))

        let r1 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819800), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(12))
        let r2 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819827), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(13))
        let r3 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819854), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(14))
        controller.handleIncomingLocation(r1, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(12))
        controller.handleIncomingLocation(r2, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(13))
        controller.handleIncomingLocation(r3, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(14))

        controller.advanceClocks(to: t0.addingTimeInterval(16))
        let unknown16 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819854), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 0.0, timestamp: t0.addingTimeInterval(16))
        controller.handleIncomingLocation(unknown16, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(16))

        controller.advanceClocks(to: t0.addingTimeInterval(21))
        XCTAssertEqual(controller.state, .paused(isAutomatic: true))
    }

    func testStationaryConfirmationInterruptedByUnknownAndRejectedReadingsResetsTimer() {
        let engine = GPSFilterEngine()
        let config = GPSFilterConfig.for(activityType: .walking, maxAccuracy: 25.0)
        let t0 = Date(timeIntervalSince1970: 1_700_000_680)

        let p0 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819800), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0, timestamp: t0)
        let p2 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819800), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0, timestamp: t0.addingTimeInterval(2))
        let p4 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819800), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0, timestamp: t0.addingTimeInterval(4))
        _ = engine.evaluate(location: p0, config: config, now: t0)
        _ = engine.evaluate(location: p2, config: config, now: t0.addingTimeInterval(2))
        let d4 = engine.evaluate(location: p4, config: config, now: t0.addingTimeInterval(4))
        XCTAssertEqual(d4, .accept(distanceDeltaMeters: 0, impliedSpeedMPS: 0, movementState: .confirmedStationary, isRoutePoint: false))

        let cand6 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819842), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 1.2, timestamp: t0.addingTimeInterval(6))
        let d6 = engine.evaluate(location: cand6, config: config, now: t0.addingTimeInterval(6))
        XCTAssertEqual(d6, .accept(distanceDeltaMeters: 0, impliedSpeedMPS: 0, movementState: .unknownOrUnconfirmed, isRoutePoint: false))

        controller.selectedActivityType = .walking
        controller.beginWorkoutSession(now: t0)
        let m0 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819800), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 1.2, timestamp: t0)
        let m2 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819850), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 1.2, timestamp: t0.addingTimeInterval(2))
        let m4 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819920), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 1.2, timestamp: t0.addingTimeInterval(4))
        controller.handleIncomingLocation(m0, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0)
        controller.handleIncomingLocation(m2, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(2))
        controller.handleIncomingLocation(m4, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(4))

        let s6 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819920), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 0, timestamp: t0.addingTimeInterval(6))
        let s8 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819920), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 0, timestamp: t0.addingTimeInterval(8))
        controller.handleIncomingLocation(s6, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(6))
        controller.handleIncomingLocation(s8, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(8))
        controller.advanceClocks(to: t0.addingTimeInterval(14))
        XCTAssertEqual(controller.state, .recording)

        let cand14 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819970), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 1.2, timestamp: t0.addingTimeInterval(14))
        controller.handleIncomingLocation(cand14, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(14))

        let s16 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819970), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 0, timestamp: t0.addingTimeInterval(16))
        let s18 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819970), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 0, timestamp: t0.addingTimeInterval(18))
        controller.handleIncomingLocation(s16, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(16))
        controller.handleIncomingLocation(s18, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(18))
        controller.advanceClocks(to: t0.addingTimeInterval(24))
        XCTAssertEqual(controller.state, .recording)

        let poor24 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819970), altitude: 10, horizontalAccuracy: 95, verticalAccuracy: 5, course: 90, speed: 0, timestamp: t0.addingTimeInterval(24))
        controller.handleIncomingLocation(poor24, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(24))

        controller.advanceClocks(to: t0.addingTimeInterval(34))
        XCTAssertEqual(controller.state, .recording)
    }

    func testStationaryStaleGPSUpdatesDoNotTriggerAutoPause() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_690)
        controller.selectedActivityType = .walking
        controller.beginWorkoutSession(now: t0)

        let m0 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819800), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 1.2, timestamp: t0)
        let m2 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819860), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 1.2, timestamp: t0.addingTimeInterval(2))
        controller.handleIncomingLocation(m0, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0)
        controller.handleIncomingLocation(m2, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(2))

        let s4 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819860), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 0.0, timestamp: t0.addingTimeInterval(4))
        let s6 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819860), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 0.0, timestamp: t0.addingTimeInterval(6))
        controller.handleIncomingLocation(s4, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(4))
        controller.handleIncomingLocation(s6, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(6))

        controller.advanceClocks(to: t0.addingTimeInterval(60))
        XCTAssertEqual(controller.state, .recording)
    }

    func testBackwardsClockTimestampDoesNotProduceNegativeMovingOrElapsedTime() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_710)
        controller.selectedActivityType = .walking
        controller.beginWorkoutSession(now: t0)

        let m0 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819800), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 1.5, timestamp: t0)
        let m2 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819827), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 1.5, timestamp: t0.addingTimeInterval(2))
        let m4 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819854), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 1.5, timestamp: t0.addingTimeInterval(4))
        controller.handleIncomingLocation(m0, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0)
        controller.handleIncomingLocation(m2, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(2))
        controller.handleIncomingLocation(m4, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(4))
        XCTAssertEqual(controller.currentFilterMovementState, .confirmedMoving)

        controller.advanceClocks(to: t0.addingTimeInterval(8))
        let movingBeforeJump = controller.movingTimeSeconds
        let elapsedBeforeJump = controller.elapsedTimeSeconds
        XCTAssertEqual(movingBeforeJump, 4.0, accuracy: 0.01)
        XCTAssertEqual(elapsedBeforeJump, 8.0, accuracy: 0.01)

        controller.advanceClocks(to: t0.addingTimeInterval(5))
        XCTAssertEqual(controller.movingTimeSeconds, movingBeforeJump, accuracy: 0.01)
        XCTAssertEqual(controller.elapsedTimeSeconds, elapsedBeforeJump, accuracy: 0.01)

        controller.advanceClocks(to: t0.addingTimeInterval(6))
        XCTAssertEqual(controller.movingTimeSeconds, movingBeforeJump, accuracy: 0.01)
        XCTAssertEqual(controller.elapsedTimeSeconds, elapsedBeforeJump, accuracy: 0.01)
    }

    func testBackwardsClockTimestampDoesNotIncreaseStationaryDuration() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_720)
        controller.selectedActivityType = .walking
        controller.beginWorkoutSession(now: t0)

        let s0 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819800), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0.0, timestamp: t0)
        let s2 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819800), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0.0, timestamp: t0.addingTimeInterval(2))
        let s4 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819800), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0.0, timestamp: t0.addingTimeInterval(4))
        controller.handleIncomingLocation(s0, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0)
        controller.handleIncomingLocation(s2, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(2))
        controller.handleIncomingLocation(s4, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(4))
        XCTAssertEqual(controller.currentFilterMovementState, .confirmedStationary)

        controller.advanceClocks(to: t0.addingTimeInterval(7))
        let stationaryBeforeJump = controller.currentStationaryDurationSeconds
        let elapsedBeforeJump = controller.elapsedTimeSeconds
        XCTAssertEqual(stationaryBeforeJump, 3.0, accuracy: 0.01)

        controller.advanceClocks(to: t0.addingTimeInterval(5))
        XCTAssertEqual(controller.currentStationaryDurationSeconds, stationaryBeforeJump, accuracy: 0.01)
        XCTAssertEqual(controller.elapsedTimeSeconds, elapsedBeforeJump, accuracy: 0.01)

        controller.advanceClocks(to: t0.addingTimeInterval(6))
        XCTAssertEqual(controller.currentStationaryDurationSeconds, stationaryBeforeJump, accuracy: 0.01)
        XCTAssertEqual(controller.elapsedTimeSeconds, elapsedBeforeJump, accuracy: 0.01)
    }

    func testBackwardsClockTimestampDoesNotIncreaseAutoResumeDuration() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_730)
        controller.selectedActivityType = .running
        controller.beginWorkoutSession(now: t0)
        controller.pauseWorkout(automatic: true, now: t0.addingTimeInterval(10))

        let r18 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819800), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(18))
        let r19 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819827), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(19))
        let r20 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819854), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(20))
        controller.handleIncomingLocation(r18, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(18))
        controller.handleIncomingLocation(r19, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(19))
        controller.handleIncomingLocation(r20, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(20))
        XCTAssertEqual(controller.currentFilterMovementState, .confirmedMoving)

        controller.advanceClocks(to: t0.addingTimeInterval(22))
        let resumeDurationBeforeJump = controller.currentAutoResumeMovingDurationSeconds
        let elapsedBeforeJump = controller.elapsedTimeSeconds
        XCTAssertEqual(resumeDurationBeforeJump, 2.0, accuracy: 0.01)
        XCTAssertEqual(controller.state, .paused(isAutomatic: true))

        controller.advanceClocks(to: t0.addingTimeInterval(19))
        XCTAssertEqual(controller.currentAutoResumeMovingDurationSeconds, resumeDurationBeforeJump, accuracy: 0.01)
        XCTAssertEqual(controller.elapsedTimeSeconds, elapsedBeforeJump, accuracy: 0.01)
        XCTAssertEqual(controller.state, .paused(isAutomatic: true))

        controller.advanceClocks(to: t0.addingTimeInterval(21))
        XCTAssertEqual(controller.currentAutoResumeMovingDurationSeconds, resumeDurationBeforeJump, accuracy: 0.01)
        XCTAssertEqual(controller.elapsedTimeSeconds, elapsedBeforeJump, accuracy: 0.01)
        XCTAssertEqual(controller.state, .paused(isAutomatic: true))
    }

    func testResumeWorkoutResetsAutoResumeStateAndMarksSegmentBreakOnNextAcceptedPoint() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_740)
        controller.selectedActivityType = .running
        controller.beginWorkoutSession(now: t0)
        controller.pauseWorkout(automatic: true, now: t0.addingTimeInterval(10))

        let r12 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819800), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(12))
        let r13 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819827), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(13))
        let r14 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819854), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(14))
        controller.handleIncomingLocation(r12, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(12))
        controller.handleIncomingLocation(r13, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(13))
        controller.handleIncomingLocation(r14, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(14))
        controller.advanceClocks(to: t0.addingTimeInterval(16))
        XCTAssertEqual(controller.currentAutoResumeMovingDurationSeconds, 2.0, accuracy: 0.01)

        controller.resumeWorkout(now: t0.addingTimeInterval(16))
        XCTAssertEqual(controller.state, .recording)
        XCTAssertEqual(controller.currentAutoResumeMovingDurationSeconds, 0.0, accuracy: 0.01)

        let post16 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819854), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(16))
        let post17 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819881), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(17))
        let post18 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819908), altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(18))
        controller.handleIncomingLocation(post16, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(16))
        controller.handleIncomingLocation(post17, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(17))
        controller.handleIncomingLocation(post18, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(18))

        _ = store.flushPendingTrackPoints(now: t0.addingTimeInterval(18))
        let activity = store.fetchInProgressActivity()
        let firstAcceptedAfterResume = activity?.trackPoints
            .filter(\.isAccepted)
            .sorted { $0.timestamp < $1.timestamp }
            .first { $0.timestamp >= t0.addingTimeInterval(16) }

        XCTAssertEqual(firstAcceptedAfterResume?.isSegmentBreak, true)
    }

    func testPauseSurfacesBannerWhenPersistenceFails() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_700)
        controller.beginWorkoutSession(now: t0)

        shouldFailSave = true
        controller.pauseWorkout(automatic: false, now: t0.addingTimeInterval(10))

        XCTAssertEqual(controller.state, .paused(isAutomatic: false))
        XCTAssertTrue(controller.statusBanner?.contains("could not be saved") == true)
    }

    func testLifecycleTransitionSurfacesBannerWhenPersistenceFails() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_720)
        controller.beginWorkoutSession(now: t0)

        shouldFailSave = true
        controller.handleLifecycleTransition(isBackgroundOrInactive: true, now: t0.addingTimeInterval(5))

        XCTAssertTrue(controller.statusBanner?.contains("could not be saved") == true)
    }

    func testBannerClearsAfterPauseSaveRecoversOnLifecycleRetry() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_780)
        controller.beginWorkoutSession(now: t0)

        shouldFailSave = true
        controller.pauseWorkout(automatic: false, now: t0.addingTimeInterval(10))
        XCTAssertTrue(controller.statusBanner?.contains("could not be saved") == true)

        shouldFailSave = false
        controller.handleLifecycleTransition(isBackgroundOrInactive: false, now: t0.addingTimeInterval(20))

        XCTAssertNil(store.lastSaveError)
        XCTAssertFalse(controller.statusBanner?.contains("could not be saved") == true)
        XCTAssertEqual(controller.state, .paused(isAutomatic: false))
        XCTAssertEqual(store.fetchInProgressActivity()?.status, .pausedManual)
    }

    func testPausedWorkoutCanResumeAfterFailedPauseSave() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_800)
        controller.beginWorkoutSession(now: t0)

        shouldFailSave = true
        controller.pauseWorkout(automatic: false, now: t0.addingTimeInterval(10))
        shouldFailSave = false
        controller.resumeWorkout(now: t0.addingTimeInterval(20))

        XCTAssertEqual(controller.state, .recording)
        XCTAssertNil(store.lastSaveError)
        XCTAssertEqual(store.fetchInProgressActivity()?.status, .recording)
    }

    func testFailedResumeSaveShowsBannerAndRecoversOnNextSave() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_820)
        controller.beginWorkoutSession(now: t0)
        controller.pauseWorkout(automatic: false, now: t0.addingTimeInterval(10))

        shouldFailSave = true
        controller.resumeWorkout(now: t0.addingTimeInterval(20))
        XCTAssertEqual(controller.state, .recording)
        XCTAssertTrue(controller.statusBanner?.contains("could not be saved") == true)

        shouldFailSave = false
        controller.handleLifecycleTransition(isBackgroundOrInactive: false, now: t0.addingTimeInterval(25))

        XCTAssertNil(store.lastSaveError)
        XCTAssertFalse(controller.statusBanner?.contains("could not be saved") == true)
        XCTAssertEqual(store.fetchInProgressActivity()?.status, .recording)
    }

    func testImportedGPXActivityIsFlaggedAsHavingUnavailableMovingMetrics() throws {
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Test" xmlns="http://www.topografix.com/GPX/1/1"><trk><name>Flag</name><trkseg>
        <trkpt lat="1.3521" lon="103.8198"><time>2024-01-01T00:00:00Z</time></trkpt>
        <trkpt lat="1.3621" lon="103.8198"><time>2024-01-01T00:05:00Z</time></trkpt>
        </trkseg></trk></gpx>
        """
        try store.importGPX(Data(gpx.utf8))
        let imported = store.fetchCompletedActivities().first
        XCTAssertEqual(imported?.hasUnavailableMovingMetrics, true)
    }

    func testRecordedWorkoutWithoutDistanceIsNotFlaggedAsUnavailable() {
        let activity = WorkoutActivity(
            title: "Zero",
            activityType: .running,
            startDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertFalse(activity.hasUnavailableMovingMetrics)
    }

    private func firstBarometricAltitude(verticalAccuracy: Double, t0: Date) -> Double? {
        controller.beginWorkoutSession(now: t0)
        let loc = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 1.3521, longitude: 103.8198),
            altitude: 100,
            horizontalAccuracy: 5,
            verticalAccuracy: verticalAccuracy,
            course: 0,
            speed: 0,
            timestamp: t0
        )
        controller.handleIncomingLocation(loc, barometricRelativeAltitude: 2, isBarometerActive: true, now: t0)
        _ = store.flushPendingTrackPoints(now: t0.addingTimeInterval(1))
        return store.fetchInProgressActivity()?.trackPoints
            .sorted { $0.timestamp < $1.timestamp }
            .first?.normalisedElevationMeters
    }

    func testBarometerAnchorsToGPSWhenVerticalAccuracyIsAtThreshold() {
        let altitude = firstBarometricAltitude(verticalAccuracy: 25, t0: Date(timeIntervalSince1970: 1_700_000_740))
        XCTAssertEqual(altitude ?? .nan, 102, accuracy: 0.001)
    }

    func testBarometerUsesNeutralBaselineWhenVerticalAccuracyIsPoor() {
        let altitude = firstBarometricAltitude(verticalAccuracy: 26, t0: Date(timeIntervalSince1970: 1_700_000_760))
        XCTAssertEqual(altitude ?? .nan, 2, accuracy: 0.001)
    }

    func testFinishWorkoutRetainsSessionWhenPersistenceFailsAndCanRetry() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_650)
        controller.beginWorkoutSession(now: t0)

        shouldFailSave = true
        controller.finishWorkout(now: t0.addingTimeInterval(30))

        XCTAssertEqual(controller.state, .paused(isAutomatic: false))
        XCTAssertTrue(controller.statusBanner?.contains("could not be saved") == true)
        XCTAssertEqual(store.fetchInProgressActivity()?.status, .pausedManual)

        shouldFailSave = false
        controller.finishWorkout(now: t0.addingTimeInterval(31))

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(store.fetchCompletedActivities().count, 1)
        XCTAssertEqual(
            store.fetchCompletedActivities().first?.finishDate,
            t0.addingTimeInterval(31)
        )
    }

    func testManuallyPausedSessionsNeverAutoResume() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_700)
        controller.beginWorkoutSession(now: t0)
        controller.pauseWorkout(automatic: false, now: t0.addingTimeInterval(5))
        XCTAssertEqual(controller.state, .paused(isAutomatic: false))

        for step in [10.0, 15.0, 20.0, 25.0] {
            let loc = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.81980 + step * 0.0001),
                altitude: 10,
                horizontalAccuracy: 5,
                verticalAccuracy: 5,
                course: 90,
                speed: 4.0,
                timestamp: t0.addingTimeInterval(step)
            )
            controller.handleIncomingLocation(loc, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(step))
            controller.advanceClocks(to: t0.addingTimeInterval(step))
        }

        XCTAssertEqual(controller.state, .paused(isAutomatic: false))
    }

    func testRestoredPausedWorkoutRequiresManualResumeAndMarksSegmentBreak() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_800)
        let act = store.createActivity(title: "Saved Auto-Paused", activityType: .running, startDate: t0)
        act.status = .pausedAuto
        store.updateActivity(act, flushPoints: true, now: t0)

        controller.restoreInProgressWorkoutIfAvailable(now: t0.addingTimeInterval(10))
        XCTAssertEqual(controller.state, .paused(isAutomatic: false))

        let genuineLoc = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 1.3530, longitude: 103.8210),
            altitude: 12,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 90,
            speed: 3.0,
            timestamp: t0.addingTimeInterval(20)
        )
        controller.handleIncomingLocation(genuineLoc, barometricRelativeAltitude: 0, isBarometerActive: true, now: t0.addingTimeInterval(20))
        XCTAssertEqual(controller.state, .paused(isAutomatic: false))
    }

    func testLowPowerAutoPauseRecoveryAcceptsLowerAccuracyReading() {
        let config = GPSFilterConfig.autoPauseRecovery(for: .running)
        let engine = GPSFilterEngine()
        let t0 = Date(timeIntervalSince1970: 1_700_000_900)

        let p1 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.81980), altitude: 10, horizontalAccuracy: 80, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0)
        let p2 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.82000), altitude: 10, horizontalAccuracy: 80, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(5))
        let p3 = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.82025), altitude: 10, horizontalAccuracy: 80, verticalAccuracy: 5, course: 90, speed: 3.0, timestamp: t0.addingTimeInterval(10))

        _ = engine.evaluate(location: p1, config: config, now: t0)
        _ = engine.evaluate(location: p2, config: config, now: t0.addingTimeInterval(5))
        let d3 = engine.evaluate(location: p3, config: config, now: t0.addingTimeInterval(10))

        guard case .accept(_, _, let movementState, let isRoutePoint) = d3 else {
            XCTFail("Expected auto-pause recovery reading to be accepted")
            return
        }
        XCTAssertEqual(movementState, .confirmedMoving)
        XCTAssertTrue(isRoutePoint)
    }

    func testElevationSourceChangesPreservePreviousGainAndLoss() {
        var tracker = ElevationTracker(thresholdMeters: 3.0)

        _ = tracker.recordSample(altitude: 100.0, source: .barometer)
        let afterBaroClimb = tracker.recordSample(altitude: 110.0, source: .barometer)
        XCTAssertEqual(afterBaroClimb.gainMeters, 10.0, accuracy: 0.01)

        _ = tracker.recordSample(altitude: 50.0, source: .gps)
        let afterGpsDescent = tracker.recordSample(altitude: 42.0, source: .gps)
        XCTAssertEqual(afterGpsDescent.gainMeters, 10.0, accuracy: 0.01)
        XCTAssertEqual(afterGpsDescent.lossMeters, 8.0, accuracy: 0.01)

        _ = tracker.recordSample(altitude: 110.0, source: .barometer)
        let afterBaroReturn = tracker.recordSample(altitude: 115.0, source: .barometer)
        XCTAssertEqual(afterBaroReturn.gainMeters, 15.0, accuracy: 0.01)
        XCTAssertEqual(afterBaroReturn.lossMeters, 8.0, accuracy: 0.01)
    }

    func testActualDatabaseFailureRetainsPendingPointsAndRecoversOnRetry() {
        let t0 = Date(timeIntervalSince1970: 1_700_001_000)
        let act = store.createActivity(title: "Persistence Failure Test", activityType: .running, startDate: t0)

        let pt1 = TrackPoint(
            activityID: act.id,
            latitude: 1.3521,
            longitude: 103.8198,
            timestamp: t0.addingTimeInterval(2),
            horizontalAccuracy: 5,
            altitude: 10,
            isAccepted: true,
            activity: act
        )
        store.enqueueTrackPoint(pt1, forceFlush: false, now: t0.addingTimeInterval(2))
        XCTAssertEqual(store.pendingPointCount, 1)

        shouldFailSave = true
        let flushedWhileFailing = store.flushPendingTrackPoints(now: t0.addingTimeInterval(3))
        XCTAssertFalse(flushedWhileFailing)
        XCTAssertNotNil(store.lastSaveError)
        XCTAssertEqual(store.pendingPointCount, 1)

        shouldFailSave = false
        let retried = store.retryPendingFlush(now: t0.addingTimeInterval(5))
        XCTAssertTrue(retried)
        XCTAssertNil(store.lastSaveError)
        XCTAssertEqual(store.pendingPointCount, 0)
    }

    func testAutomaticKilometreSplitIsCreatedAndPersisted() {
        let t0 = Date(timeIntervalSince1970: 1_700_001_000)
        controller.selectedActivityType = .running
        settings.distanceUnitKilometers = true
        controller.beginWorkoutSession(now: t0)

        for index in 0...105 {
            let location = CLLocation(
                coordinate: CLLocationCoordinate2D(
                    latitude: 1.35210,
                    longitude: 103.819800 + Double(index) * 0.0001
                ),
                altitude: 10,
                horizontalAccuracy: 5,
                verticalAccuracy: 5,
                course: 90,
                speed: 3.0,
                timestamp: t0.addingTimeInterval(Double(index) * 2.0)
            )
            controller.handleIncomingLocation(
                location,
                barometricRelativeAltitude: nil,
                isBarometerActive: false,
                now: location.timestamp
            )
        }

        let inProgress = store.fetchInProgressActivity()
        XCTAssertNotNil(inProgress)
        XCTAssertEqual(inProgress?.splits.count, 1)
        XCTAssertEqual(inProgress?.splits.first?.distanceMeters ?? 0, 1_000, accuracy: 0.01)
    }

    func testGPXExportAndImportPreserveRoutePoints() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_001_200)
        let activity = store.createActivity(title: "GPX Test", activityType: .walking, startDate: t0)
        activity.status = .completed
        activity.finishDate = t0.addingTimeInterval(10)

        let first = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819800),
            altitude: 12,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 90,
            speed: 1.0,
            timestamp: t0
        )
        let second = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 1.35210, longitude: 103.819900),
            altitude: 14,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 90,
            speed: 1.0,
            timestamp: t0.addingTimeInterval(10)
        )
        store.enqueueTrackPoint(TrackPoint(location: first, activityID: activity.id, barometricRelativeAltitude: nil, normalisedElevationMeters: 12, elevationSource: .gps, isAccepted: true, activity: activity), forceFlush: true, now: t0)
        store.enqueueTrackPoint(TrackPoint(location: second, activityID: activity.id, barometricRelativeAltitude: nil, normalisedElevationMeters: 14, elevationSource: .gps, isAccepted: true, activity: activity), forceFlush: true, now: t0.addingTimeInterval(10))
        activity.totalDistanceMeters = first.distance(from: second)
        store.updateActivity(activity, flushPoints: true, now: t0.addingTimeInterval(10))

        let gpx = try store.makeGPXData(for: activity)
        XCTAssertTrue(String(decoding: gpx, as: UTF8.self).contains("<trkpt"))
        try store.importGPX(gpx)

        let imported = store.fetchCompletedActivities().first { $0.id != activity.id }
        XCTAssertNotNil(imported)
        XCTAssertEqual(imported?.trackPoints.filter(\.isAccepted).count, 2)
        XCTAssertGreaterThan(imported?.totalDistanceMeters ?? 0, 0)
        XCTAssertTrue(imported?.title.hasPrefix("Imported GPX - ") == true)
        XCTAssertEqual(imported?.movingTimeSeconds, 0)
        XCTAssertEqual(imported?.averageSpeedMPS, 0)
        XCTAssertNil(imported?.averagePaceSecPerKm)
    }

    func testJSONBackupCanBeRestoredIntoAnotherLocalStore() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_001_400)
        let activity = store.createActivity(title: "Backup Test", activityType: .hiking, startDate: t0)
        activity.status = .completed
        activity.finishDate = t0.addingTimeInterval(60)
        activity.totalDistanceMeters = 250
        settings.userWeightKg = 82
        settings.voiceAnnouncementsEnabled = true
        store.updateActivity(activity, flushPoints: true, now: t0.addingTimeInterval(60))

        let backup = try store.makeJSONBackup()
        let destinationSchema = Schema([WorkoutActivity.self, TrackPoint.self, ActivitySplit.self, AppSettings.self])
        let destinationConfiguration = ModelConfiguration(schema: destinationSchema, isStoredInMemoryOnly: true)
        let destinationContainer = try ModelContainer(for: destinationSchema, configurations: [destinationConfiguration])
        let destinationStore = LocalDatabaseStore(modelContext: ModelContext(destinationContainer))
        try destinationStore.importJSONBackup(backup)

        XCTAssertEqual(destinationStore.fetchAllActivities().count, 1)
        XCTAssertEqual(destinationStore.fetchAllActivities().first?.title, "Backup Test")
        XCTAssertEqual(destinationStore.fetchAllActivities().first?.totalDistanceMeters ?? 0, 250, accuracy: 0.001)
        let restoredSettings = destinationStore.fetchOrCreateSettings()
        XCTAssertEqual(restoredSettings.userWeightKg, 82, accuracy: 0.001)
        XCTAssertTrue(restoredSettings.voiceAnnouncementsEnabled)
    }

}
