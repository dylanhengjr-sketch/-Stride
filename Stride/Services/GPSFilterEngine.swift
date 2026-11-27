import Foundation
import CoreLocation

enum GPSMovementState: Equatable, Sendable {
    case unknownOrUnconfirmed
    case confirmedMoving
    case confirmedStationary
}

struct GPSFilterConfig: Sendable {
    let maxHorizontalAccuracy: Double
    let minMovementThresholdMeters: Double
    let maxPlausibleSpeedMPS: Double
    let maxAgeSeconds: TimeInterval
    let maxFutureToleranceSeconds: TimeInterval
    let movingConfirmationSamples: Int
    let stationaryConfirmationSamples: Int

    static func `for`(
        activityType: ActivityType,
        maxAccuracy: Double,
        maxFutureToleranceSeconds: TimeInterval = 2.0,
        movingConfirmationSamples: Int = AppConfig.movingConfirmationSamples
    ) -> GPSFilterConfig {
        let minMove: Double
        switch activityType {
        case .walking, .hiking:
            minMove = 3.0
        case .running:
            minMove = 3.5
        case .cycling:
            minMove = 5.0
        }

        return GPSFilterConfig(
            maxHorizontalAccuracy: maxAccuracy,
            minMovementThresholdMeters: minMove,
            maxPlausibleSpeedMPS: activityType.maxPlausibleSpeedMPS,
            maxAgeSeconds: 20.0,
            maxFutureToleranceSeconds: maxFutureToleranceSeconds,
            movingConfirmationSamples: (activityType == .walking || activityType == .hiking)
                ? min(2, max(1, movingConfirmationSamples))
                : max(1, movingConfirmationSamples),
            stationaryConfirmationSamples: AppConfig.stationaryConfirmationSamples
        )
    }

    static func autoPauseRecovery(for activityType: ActivityType) -> GPSFilterConfig {
        let base = `for`(activityType: activityType, maxAccuracy: AppConfig.autoPauseRecoveryMaxHorizontalAccuracy)
        return GPSFilterConfig(
            maxHorizontalAccuracy: AppConfig.autoPauseRecoveryMaxHorizontalAccuracy,
            minMovementThresholdMeters: max(base.minMovementThresholdMeters, 5.0),
            maxPlausibleSpeedMPS: base.maxPlausibleSpeedMPS,
            maxAgeSeconds: base.maxAgeSeconds,
            maxFutureToleranceSeconds: base.maxFutureToleranceSeconds,
            movingConfirmationSamples: 2,
            stationaryConfirmationSamples: base.stationaryConfirmationSamples
        )
    }
}

enum GPSFilterDecision: Equatable, Sendable {
    case accept(distanceDeltaMeters: Double, impliedSpeedMPS: Double, movementState: GPSMovementState, isRoutePoint: Bool)
    case reject(reason: String)
}

final class GPSFilterEngine {
    private var anchorLocation: CLLocation?
    private var lastAcceptedRouteLocation: CLLocation?
    private var lastCandidateLocation: CLLocation?
    private var consecutiveMovingSamples: Int = 0
    private var consecutiveStationarySamples: Int = 0
    private var currentMovementState: GPSMovementState = .unknownOrUnconfirmed

    func reset() {
        anchorLocation = nil
        lastAcceptedRouteLocation = nil
        lastCandidateLocation = nil
        consecutiveMovingSamples = 0
        consecutiveStationarySamples = 0
        currentMovementState = .unknownOrUnconfirmed
    }

    func seed(lastLocation: CLLocation?) {
        anchorLocation = lastLocation
        lastAcceptedRouteLocation = lastLocation
        lastCandidateLocation = nil
        consecutiveMovingSamples = 0
        consecutiveStationarySamples = 0
        currentMovementState = .unknownOrUnconfirmed
    }

    func clearConfirmationStatePreservingAnchor() {
        lastCandidateLocation = nil
        consecutiveMovingSamples = 0
        consecutiveStationarySamples = 0
        currentMovementState = .unknownOrUnconfirmed
    }

    var movementState: GPSMovementState {
        currentMovementState
    }

    var stationarySampleCount: Int {
        consecutiveStationarySamples
    }

    var hasAnchor: Bool {
        anchorLocation != nil
    }

    func evaluate(
        location: CLLocation,
        config: GPSFilterConfig,
        now: Date = Date()
    ) -> GPSFilterDecision {
        guard CLLocationCoordinate2DIsValid(location.coordinate),
              abs(location.coordinate.latitude) <= 90,
              abs(location.coordinate.longitude) <= 180,
              !(location.coordinate.latitude == 0 && location.coordinate.longitude == 0) else {
            return .reject(reason: "Invalid coordinate")
        }

        guard location.horizontalAccuracy > 0,
              location.horizontalAccuracy <= config.maxHorizontalAccuracy else {
            return .reject(reason: "Poor horizontal accuracy")
        }

        let futureDelta = location.timestamp.timeIntervalSince(now)
        guard futureDelta <= config.maxFutureToleranceSeconds else {
            return .reject(reason: "Future timestamp")
        }

        let age = now.timeIntervalSince(location.timestamp)
        guard age <= config.maxAgeSeconds else {
            return .reject(reason: "Stale reading")
        }

        guard let anchor = anchorLocation else {
            anchorLocation = location
            lastAcceptedRouteLocation = location
            lastCandidateLocation = nil
            consecutiveMovingSamples = 0
            consecutiveStationarySamples = 0
            currentMovementState = .unknownOrUnconfirmed
            return .accept(distanceDeltaMeters: 0, impliedSpeedMPS: 0, movementState: .unknownOrUnconfirmed, isRoutePoint: false)
        }

        if location.timestamp <= anchor.timestamp {
            return .reject(reason: "Duplicate or out-of-order timestamp")
        }

        let dtFromAnchor = location.timestamp.timeIntervalSince(anchor.timestamp)
        guard dtFromAnchor > 0.05 else {
            return .reject(reason: "Interval too short")
        }

        let displacementFromAnchor = location.distance(from: anchor)
        let impliedSpeedFromAnchor = displacementFromAnchor / dtFromAnchor

        if impliedSpeedFromAnchor > config.maxPlausibleSpeedMPS {
            return .reject(reason: "Implausible speed")
        }

        let referenceForStep = lastCandidateLocation ?? anchor
        if location.timestamp <= referenceForStep.timestamp {
            return .reject(reason: "Candidate timestamp out of order")
        }

        let stepDistance = location.distance(from: referenceForStep)
        let stepDt = max(0.05, location.timestamp.timeIntervalSince(referenceForStep.timestamp))
        let stepSpeed = stepDistance / stepDt

        if stepSpeed > config.maxPlausibleSpeedMPS {
            return .reject(reason: "Implausible step speed")
        }

        let accuracyFloor = max(
            config.minMovementThresholdMeters,
            min(12.0, max(location.horizontalAccuracy, referenceForStep.horizontalAccuracy) * 0.5)
        )
        let validReportedSpeed: Double? = location.speed >= 0 ? location.speed : nil
        let reportedSpeed = validReportedSpeed ?? stepSpeed
        let hasValidInitialSpeed = (validReportedSpeed ?? 0) >= 0.55
        let hasValidConfirmedSpeed = (validReportedSpeed ?? 0) >= 0.65

        let confirmationStepFloor = max(1.5, config.minMovementThresholdMeters * 0.5)
        let hasInitialConfirmationProgression: Bool
        if lastCandidateLocation != nil {
            hasInitialConfirmationProgression = stepDistance >= confirmationStepFloor
        } else {
            hasInitialConfirmationProgression = true
        }

        let sampleIndicatesInitialMovement =
            hasInitialConfirmationProgression &&
            (displacementFromAnchor >= accuracyFloor ||
             (hasValidInitialSpeed && stepDistance >= (config.minMovementThresholdMeters * 0.5)))

        let maintainsConfirmedMovement =
            currentMovementState == .confirmedMoving &&
            stepDistance > 0.5 &&
            hasValidConfirmedSpeed

        if sampleIndicatesInitialMovement || maintainsConfirmedMovement {
            if sampleIndicatesInitialMovement {
                consecutiveMovingSamples += 1
            } else {
                consecutiveMovingSamples = max(consecutiveMovingSamples, config.movingConfirmationSamples)
            }
            consecutiveStationarySamples = 0

            if consecutiveMovingSamples >= config.movingConfirmationSamples {
                currentMovementState = .confirmedMoving
            }

            let routeAnchor = lastAcceptedRouteLocation ?? anchor
            let dtFromRouteAnchor = location.timestamp.timeIntervalSince(routeAnchor.timestamp)
            let distanceFromRouteAnchor = location.distance(from: routeAnchor)
            let speedFromRouteAnchor = dtFromRouteAnchor > 0
                ? distanceFromRouteAnchor / dtFromRouteAnchor
                : 0
            let qualifiesAsRoutePoint =
                currentMovementState == .confirmedMoving &&
                dtFromRouteAnchor > 0 &&
                distanceFromRouteAnchor >= config.minMovementThresholdMeters &&
                speedFromRouteAnchor <= config.maxPlausibleSpeedMPS

            if qualifiesAsRoutePoint {
                // Keep speed consistent with the distance and elapsed time used for this route segment.
                let effectiveSpeed = min(speedFromRouteAnchor, config.maxPlausibleSpeedMPS)
                lastAcceptedRouteLocation = location
                anchorLocation = location
                lastCandidateLocation = nil
                return .accept(
                    distanceDeltaMeters: distanceFromRouteAnchor,
                    impliedSpeedMPS: effectiveSpeed,
                    movementState: .confirmedMoving,
                    isRoutePoint: true
                )
            } else {
                anchorLocation = location
                lastCandidateLocation = location
                if currentMovementState == .confirmedMoving {
                    let candidateSpeed = min(
                        max(speedFromRouteAnchor, 0.5),
                        config.maxPlausibleSpeedMPS
                    )
                    return .accept(
                        distanceDeltaMeters: 0,
                        impliedSpeedMPS: candidateSpeed,
                        movementState: .confirmedMoving,
                        isRoutePoint: false
                    )
                } else {
                    return .accept(
                        distanceDeltaMeters: 0,
                        impliedSpeedMPS: 0,
                        movementState: .unknownOrUnconfirmed,
                        isRoutePoint: false
                    )
                }
            }
        } else {
            consecutiveStationarySamples += 1
            consecutiveMovingSamples = 0
            lastCandidateLocation = nil

            if consecutiveStationarySamples >= config.stationaryConfirmationSamples {
                currentMovementState = .confirmedStationary
            } else {
                currentMovementState = .unknownOrUnconfirmed
            }

            if currentMovementState == .confirmedStationary &&
               location.horizontalAccuracy + 3.0 < anchor.horizontalAccuracy &&
               displacementFromAnchor < accuracyFloor {
                anchorLocation = location
            }

            return .accept(
                distanceDeltaMeters: 0,
                impliedSpeedMPS: 0,
                movementState: currentMovementState,
                isRoutePoint: false
            )
        }
    }
}
