import Foundation

struct ElevationTracker: Sendable {
    private let thresholdMeters: Double
    private var gainMeters: Double
    private var lossMeters: Double
    private var activeSource: ElevationSource?
    private var referenceAltitude: Double?
    private var candidateExtremum: Double?

    init(
        thresholdMeters: Double = 3.0,
        initialGainMeters: Double = 0,
        initialLossMeters: Double = 0
    ) {
        self.thresholdMeters = max(0.5, thresholdMeters)
        self.gainMeters = max(0, initialGainMeters)
        self.lossMeters = max(0, initialLossMeters)
    }

    mutating func commitActiveSeries() {
        if let ref = referenceAltitude, let ext = candidateExtremum {
            let delta = ext - ref
            if delta >= thresholdMeters {
                gainMeters += delta
                referenceAltitude = ext
            } else if -delta >= thresholdMeters {
                lossMeters += -delta
                referenceAltitude = ext
            }
        }
        candidateExtremum = nil
    }

    mutating func recordSample(
        altitude: Double,
        source: ElevationSource
    ) -> (gainMeters: Double, lossMeters: Double) {
        guard altitude.isFinite else {
            return (gainMeters, lossMeters)
        }

        if activeSource != source {
            commitActiveSeries()
            activeSource = source
            referenceAltitude = altitude
            candidateExtremum = nil
            return (gainMeters, lossMeters)
        }

        guard let ref = referenceAltitude else {
            referenceAltitude = altitude
            candidateExtremum = nil
            return (gainMeters, lossMeters)
        }

        if let extremum = candidateExtremum {
            if extremum >= ref {
                if altitude >= extremum {
                    candidateExtremum = altitude
                } else if (extremum - altitude) >= thresholdMeters {
                    let climb = extremum - ref
                    if climb >= thresholdMeters {
                        gainMeters += climb
                    }
                    referenceAltitude = extremum
                    candidateExtremum = altitude
                }
            } else {
                if altitude <= extremum {
                    candidateExtremum = altitude
                } else if (altitude - extremum) >= thresholdMeters {
                    let descent = ref - extremum
                    if descent >= thresholdMeters {
                        lossMeters += descent
                    }
                    referenceAltitude = extremum
                    candidateExtremum = altitude
                }
            }
        } else {
            let delta = altitude - ref
            if abs(delta) >= thresholdMeters {
                candidateExtremum = altitude
            }
        }

        let provisionalDelta = (candidateExtremum ?? referenceAltitude ?? 0) - (referenceAltitude ?? candidateExtremum ?? 0)
        return (
            gainMeters + max(0, provisionalDelta),
            lossMeters + max(0, -provisionalDelta)
        )
    }
}
