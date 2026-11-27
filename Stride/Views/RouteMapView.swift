import SwiftUI
import MapKit

struct RouteMapView: View {
    let points: [TrackPoint]

    private var segments: [[CLLocationCoordinate2D]] {
        let sorted = points
            .filter(\.isAccepted)
            .sorted { $0.timestamp < $1.timestamp }
        var result: [[CLLocationCoordinate2D]] = []
        var current: [CLLocationCoordinate2D] = []

        for pt in sorted {
            let coord = CLLocationCoordinate2D(latitude: pt.latitude, longitude: pt.longitude)
            guard CLLocationCoordinate2DIsValid(coord) else { continue }
            if pt.isSegmentBreak && !current.isEmpty {
                result.append(current)
                current = [coord]
            } else {
                current.append(coord)
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    private var initialPosition: MapCameraPosition {
        if let last = segments.flatMap({ $0 }).last {
            let region = MKCoordinateRegion(
                center: last,
                span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
            )
            return .region(region)
        }
        return .userLocation(fallback: .automatic)
    }

    var body: some View {
        Map(initialPosition: initialPosition) {
            UserAnnotation()
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                if segment.count >= 2 {
                    MapPolyline(coordinates: segment)
                        .stroke(.tint, lineWidth: 4)
                }
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
    }
}
