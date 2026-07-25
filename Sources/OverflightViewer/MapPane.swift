import SwiftUI
import MapKit
import OverflightCore

struct MapPane: NSViewRepresentable {
	@Environment(ViewerModel.self) private var model

	final class BandMultiPolyline: MKMultiPolyline {
		var segmentClass: SegmentClass = .unknownAlt
	}

	final class ParcelAnnotation: MKPointAnnotation {}
	final class SiteAnnotation: MKPointAnnotation {}

	final class HeadAnnotation: NSObject, MKAnnotation {
		let coordinate: CLLocationCoordinate2D
		let headingDeg: Double?
		let colorIndex: Int
		let trackId: String

		init(head: TrackHead) {
			coordinate = CLLocationCoordinate2D(latitude: head.lat, longitude: head.lon)
			headingDeg = head.headingDeg
			colorIndex = head.colorIndex
			trackId = head.id
		}
	}

	func makeCoordinator() -> Coordinator {
		Coordinator()
	}

	func makeNSView(context: Context) -> MKMapView {
		let map = MKMapView()
		map.mapType = .satellite
		map.delegate = context.coordinator
		map.showsCompass = true
		map.showsZoomControls = true
		context.coordinator.model = model

		let center = CLLocationCoordinate2D(latitude: model.site.lat, longitude: model.site.lon)
		let saved = SiteViewState.load(slug: model.viewStateSlug)
		if let lat = saved.centerLat, let lon = saved.centerLon,
			let dLat = saved.spanLatDeg, let dLon = saved.spanLonDeg {
			map.setRegion(
				MKCoordinateRegion(
					center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
					span: MKCoordinateSpan(latitudeDelta: dLat, longitudeDelta: dLon)
				),
				animated: false
			)
		} else {
			let spanM = model.site.radiusNm * Geo.metersPerNm * 2.2
			map.setRegion(
				MKCoordinateRegion(center: center, latitudinalMeters: spanM, longitudinalMeters: spanM),
				animated: false
			)
		}

		let site = SiteAnnotation()
		site.coordinate = center
		site.title = model.isRemote ? model.site.displayName : "Field"
		map.addAnnotation(site)

		return map
	}

	func updateNSView(_ map: MKMapView, context: Context) {
		let coord = context.coordinator
		coord.model = model
		if coord.overlayRevision != model.mapRevision {
			coord.overlayRevision = model.mapRevision
			coord.rebuildTrackOverlays(map, segments: model.segmentsByClass, heads: model.trackHeads)
		}
		if !model.isRemote {
			coord.syncParcel(map, lat: model.parcelLat, lon: model.parcelLon, radiusM: model.parcelRadiusM)
		}
		if let focus = model.focusRequest, focus.seq != coord.handledFocusSeq {
			coord.handledFocusSeq = focus.seq
			coord.focus(map, trackId: focus.trackId)
		}
		if model.recenterSeq != coord.handledRecenterSeq {
			coord.handledRecenterSeq = model.recenterSeq
			let center = CLLocationCoordinate2D(latitude: model.site.lat, longitude: model.site.lon)
			let spanM = model.site.radiusNm * Geo.metersPerNm * 2.2
			map.setRegion(
				MKCoordinateRegion(center: center, latitudinalMeters: spanM, longitudinalMeters: spanM),
				animated: true
			)
		}
	}

	@MainActor
	final class Coordinator: NSObject, MKMapViewDelegate {
		var model: ViewerModel?
		var overlayRevision = -1
		var handledFocusSeq = 0
		var handledRecenterSeq = 0
		private var parcelAnnotation: ParcelAnnotation?
		private var parcelCircle: MKCircle?
		private var lastParcel: (lat: Double, lon: Double, radiusM: Double) = (.nan, .nan, .nan)

		/// Clicking an Active-now row: recenter (same zoom) if the arrow is
		/// offscreen, then pulse it — 1s growing to 4x, 1s back.
		func focus(_ map: MKMapView, trackId: String) {
			guard let ann = map.annotations.compactMap({ $0 as? HeadAnnotation }).first(where: { $0.trackId == trackId }) else {
				return
			}
			let visible = map.visibleMapRect.contains(MKMapPoint(ann.coordinate))
			if !visible {
				map.setCenter(ann.coordinate, animated: true)
			}
			// After a recenter, the annotation view may not exist until the
			// pan settles; delay the pulse to land on the visible view.
			let delay: TimeInterval = visible ? 0 : 0.45
			DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak map] in
				guard let map, let view = map.view(for: ann) else { return }
				Self.pulse(view)
			}
		}

		private static func pulse(_ view: MKAnnotationView) {
			view.wantsLayer = true
			guard let layer = view.layer else { return }
			// Scale around the view's center without touching anchorPoint —
			// MapKit repositions annotation views assuming the default anchor,
			// so mutating it makes the view lurch mid-animation. Instead the
			// centering is composed into the transform: p' = c + s(p - c).
			let cx = layer.bounds.midX
			let cy = layer.bounds.midY
			func scaledAboutCenter(_ s: CGFloat) -> CATransform3D {
				var t = CATransform3DMakeTranslation((1 - s) * cx, (1 - s) * cy, 0)
				t = CATransform3DScale(t, s, s, 1)
				return t
			}
			let anim = CAKeyframeAnimation(keyPath: "transform")
			anim.values = [
				NSValue(caTransform3D: CATransform3DIdentity),
				NSValue(caTransform3D: scaledAboutCenter(4)),
				NSValue(caTransform3D: CATransform3DIdentity),
			]
			anim.keyTimes = [0, 0.5, 1]
			anim.timingFunctions = [
				CAMediaTimingFunction(name: .easeOut),
				CAMediaTimingFunction(name: .easeIn),
			]
			anim.duration = 1
			layer.add(anim, forKey: "pulse")
		}

		func rebuildTrackOverlays(_ map: MKMapView, segments: [SegmentClass: [[CLLocationCoordinate2D]]], heads: [TrackHead]) {
			map.removeAnnotations(map.annotations.filter { $0 is HeadAnnotation })
			map.addAnnotations(heads.map(HeadAnnotation.init))
			map.removeOverlays(map.overlays.filter { $0 is BandMultiPolyline })
			// Draw order: ground first, then high bands down to low, so the
			// low-altitude traffic — the interesting signal — sits on top.
			var order: [SegmentClass] = [.ground, .unknownAlt, .vessel, .train]
			order += AltitudeBand.allCases.reversed().map { .band($0.rawValue) }
			for cls in order {
				guard let runs = segments[cls], !runs.isEmpty else { continue }
				let polylines = runs.map { run in
					MKPolyline(coordinates: run, count: run.count)
				}
				let multi = BandMultiPolyline(polylines)
				multi.segmentClass = cls
				map.addOverlay(multi, level: .aboveLabels)
			}
		}

		func syncParcel(_ map: MKMapView, lat: Double, lon: Double, radiusM: Double) {
			guard lastParcel != (lat, lon, radiusM) else { return }
			lastParcel = (lat, lon, radiusM)

			let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
			if parcelAnnotation == nil {
				let ann = ParcelAnnotation()
				ann.title = "Parcel"
				parcelAnnotation = ann
				map.addAnnotation(ann)
			}
			parcelAnnotation?.coordinate = coordinate

			if let old = parcelCircle {
				map.removeOverlay(old)
			}
			let circle = MKCircle(center: coordinate, radius: radiusM)
			map.addOverlay(circle, level: .aboveLabels)
			parcelCircle = circle
		}

		/// Fires at the end of every pan/zoom (and after programmatic region
		/// changes) — remember where this site's map was left.
		func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
			guard let model else { return }
			let region = mapView.region
			SiteViewState.update(slug: model.viewStateSlug) {
				$0.centerLat = region.center.latitude
				$0.centerLon = region.center.longitude
				$0.spanLatDeg = region.span.latitudeDelta
				$0.spanLonDeg = region.span.longitudeDelta
			}
			model.mapRegionChanged(
				centerLat: region.center.latitude, centerLon: region.center.longitude,
				spanLat: region.span.latitudeDelta, spanLon: region.span.longitudeDelta)
		}

		func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
			if let multi = overlay as? BandMultiPolyline {
				let r = MKMultiPolylineRenderer(multiPolyline: multi)
				switch multi.segmentClass {
				case .band(let i):
					r.strokeColor = Viz.mapBand[min(max(i, 0), Viz.mapBand.count - 1)]
				case .ground:
					r.strokeColor = Viz.mapGround
				case .unknownAlt:
					r.strokeColor = Viz.mapUnknown
				case .vessel:
					r.strokeColor = Viz.mapVessel
				case .train:
					r.strokeColor = Viz.mapTrain
				}
				r.lineWidth = 2
				return r
			}
			if let circle = overlay as? MKCircle {
				let r = MKCircleRenderer(circle: circle)
				r.fillColor = Viz.parcelFill
				r.strokeColor = Viz.parcelStroke
				r.lineWidth = 1.5
				return r
			}
			return MKOverlayRenderer(overlay: overlay)
		}

		private struct HeadImageKey: Hashable {
			let colorIndex: Int
			let headingBucket: Int
		}

		private var headImageCache: [HeadImageKey: NSImage] = [:]

		/// An arrowhead in the aircraft's identity color, rotated to its course.
		/// The rotation is baked into the drawn path in screen coordinates
		/// (flipped context: y down, north = up, compass heading clockwise), so
		/// it cannot be mirrored by view-hierarchy flipping the way
		/// frameCenterRotation was. Headings are bucketed to 10 degrees for the
		/// cache.
		private func headImage(colorIndex: Int, headingDeg: Double) -> NSImage {
			let bucket = ((Int((headingDeg / 10).rounded()) % 36) + 36) % 36
			let key = HeadImageKey(colorIndex: colorIndex, headingBucket: bucket)
			if let cached = headImageCache[key] { return cached }
			let color = Viz.identityColor(colorIndex)
			let h = Double(bucket) * 10 * .pi / 180
			// Screen-space unit vectors: d = direction of travel, r = right of travel.
			let d = (x: sin(h), y: -cos(h))
			let r = (x: cos(h), y: sin(h))
			let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
				let c = (x: rect.midX, y: rect.midY)
				func pt(_ alongD: Double, _ alongR: Double) -> NSPoint {
					NSPoint(x: c.x + alongD * d.x + alongR * r.x, y: c.y + alongD * d.y + alongR * r.y)
				}
				let path = NSBezierPath()
				path.move(to: pt(7, 0))       // nose
				path.line(to: pt(-5, 4.5))    // right tail corner
				path.line(to: pt(-2.5, 0))    // tail notch
				path.line(to: pt(-5, -4.5))   // left tail corner
				path.close()
				color.setFill()
				path.fill()
				NSColor.white.withAlphaComponent(0.9).setStroke()
				path.lineWidth = 1
				path.stroke()
				return true
			}
			headImageCache[key] = image
			return image
		}

		func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
			if let head = annotation as? HeadAnnotation {
				let id = "head"
				let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
					?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
				view.annotation = annotation
				view.canShowCallout = false
				view.displayPriority = .required
				// Reused views may carry rotation from the old implementation.
				view.frameCenterRotation = 0
				view.image = headImage(colorIndex: head.colorIndex, headingDeg: head.headingDeg ?? 0)
				return view
			}
			if annotation is ParcelAnnotation {
				let id = "parcel"
				let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
					?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
				view.annotation = annotation
				view.isDraggable = true
				view.canShowCallout = false
				view.markerTintColor = Viz.parcelStroke
				view.glyphImage = NSImage(systemSymbolName: "scope", accessibilityDescription: "parcel")
				return view
			}
			if annotation is SiteAnnotation {
				let id = "site"
				let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
					?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
				view.annotation = annotation
				view.isDraggable = false
				view.canShowCallout = true
				view.markerTintColor = .gray
				view.glyphImage = NSImage(systemSymbolName: "airplane", accessibilityDescription: "field")
				return view
			}
			return nil
		}

		func mapView(
			_ mapView: MKMapView, annotationView view: MKAnnotationView,
			didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState
		) {
			guard view.annotation is ParcelAnnotation else { return }
			switch newState {
			case .ending:
				view.setDragState(.none, animated: true)
				if let coordinate = view.annotation?.coordinate {
					model?.parcelMoved(lat: coordinate.latitude, lon: coordinate.longitude)
				}
			case .canceling:
				view.setDragState(.none, animated: false)
			default:
				break
			}
		}
	}
}
