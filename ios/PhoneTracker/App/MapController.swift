import GoogleMaps
import SwiftUI
import UIKit

let brandBlue = UIColor(red: 37 / 255, green: 99 / 255, blue: 235 / 255, alpha: 1)
private let cursorOrange = UIColor(red: 234 / 255, green: 88 / 255, blue: 12 / 255, alpha: 1)
/// BitmapDescriptorFactory.HUE_AZURE on Android.
private let azure = UIColor(hue: 210 / 360, saturation: 1, brightness: 1, alpha: 1)

/// Read once at launch from Info.plist (GMSApiKey, filled from ios/Secrets.xcconfig).
enum GoogleMapsKey {
  static let value = (Bundle.main.object(forInfoDictionaryKey: "GMSApiKey") as? String ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
  static var configured: Bool { !value.isEmpty && !value.hasPrefix("$(") }
}

/// Imperative map API mirroring the GoogleMap calls in the Android MainActivity.
final class MapController: NSObject, GMSMapViewDelegate {
  let mapView: GMSMapView
  var onUserGesture: (() -> Void)?
  var onAnnotationTap: ((GMSMarker) -> Void)?
  var onCursorDragStart: (() -> Void)?
  /// Reports the cursor position while dragging (finished = false) and where it was dropped (true).
  var onCursorDrag: ((CLLocationCoordinate2D, Bool) -> Void)?
  var isHistory = false

  private(set) var marker: GMSMarker?
  private(set) var cursor: GMSMarker?
  private var circle: GMSCircle?
  private var overlays: [GMSOverlay] = []
  private var displayLink: CADisplayLink?
  private var animation: (origin: CLLocationCoordinate2D, target: CLLocationCoordinate2D, longitudeDelta: Double,
                          start: CFTimeInterval, frame: (CLLocationCoordinate2D) -> Void)?

  override init() {
    let options = GMSMapViewOptions()
    options.camera = GMSCameraPosition(latitude: 23.7, longitude: 121.0, zoom: 7)
    mapView = GMSMapView(options: options)
    super.init()
    mapView.delegate = self
    mapView.settings.compassButton = true
    mapView.settings.indoorPicker = false
  }

  // MARK: Camera

  var zoom: Double { Double(mapView.camera.zoom) }

  func move(to center: CLLocationCoordinate2D, zoom: Double, animated: Bool) {
    let camera = GMSCameraPosition(target: center, zoom: Float(zoom))
    if animated { mapView.animate(to: camera) } else { mapView.camera = camera }
  }

  func zoomBy(_ delta: Double) { mapView.animate(with: GMSCameraUpdate.zoom(by: Float(delta))) }

  func fit(_ coordinates: [CLLocationCoordinate2D], padding: CGFloat) {
    guard let first = coordinates.first else { return }
    let bounds = coordinates.dropFirst().reduce(GMSCoordinateBounds(coordinate: first, coordinate: first)) { $0.includingCoordinate($1) }
    mapView.moveCamera(GMSCameraUpdate.fit(bounds, withPadding: padding))
  }

  // MARK: Drawing

  /// GoogleMap.clear(): everything, including markers.
  func clear() {
    cancelAnimation()
    mapView.clear()
    marker = nil; cursor = nil; circle = nil; overlays = []
  }

  /// History redraws replace only the track; markers are moved in place.
  func clearOverlays() {
    cancelAnimation()
    overlays.forEach { $0.map = nil }
    overlays = []
    circle?.map = nil; circle = nil
  }

  /// Live marker: create once, update title/alpha.
  func updateLiveMarker(target: CLLocationCoordinate2D, title: String, snippet: String, stale: Bool) {
    if marker == nil { marker = makePhoneMarker(target) }
    marker?.title = title
    marker?.snippet = snippet
    marker?.opacity = stale ? 0.45 : 1
  }

  /// Animate to a new fix over 900 ms, reporting each frame's coordinate (Android ValueAnimator).
  func animateMarker(to target: CLLocationCoordinate2D, frame: @escaping (CLLocationCoordinate2D) -> Void) {
    guard let marker else { return }
    displayLink?.invalidate()
    let origin = marker.position
    let longitudeDelta = (target.longitude - origin.longitude + 540).truncatingRemainder(dividingBy: 360) - 180
    animation = (origin, target, longitudeDelta, CACurrentMediaTime(), frame)
    let link = CADisplayLink(target: self, selector: #selector(step))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  func cancelAnimation() { displayLink?.invalidate(); displayLink = nil; animation = nil }

  @objc private func step(_ link: CADisplayLink) {
    guard let animation, let marker else { cancelAnimation(); return }
    let fraction = min((CACurrentMediaTime() - animation.start) / 0.9, 1)
    let coordinate = CLLocationCoordinate2D(
      latitude: animation.origin.latitude + (animation.target.latitude - animation.origin.latitude) * fraction,
      longitude: animation.origin.longitude + animation.longitudeDelta * fraction)
    marker.position = coordinate
    animation.frame(coordinate)
    if fraction >= 1 { cancelAnimation() }
  }

  func setAccuracyCircle(center: CLLocationCoordinate2D, radius: Double) {
    if circle == nil {
      let circle = GMSCircle(position: center, radius: radius)
      circle.strokeColor = brandBlue.withAlphaComponent(0x55 / 255)
      circle.fillColor = brandBlue.withAlphaComponent(0x18 / 255)
      circle.strokeWidth = 1
      circle.map = mapView
      self.circle = circle
    }
    circle?.position = center
    circle?.radius = radius
  }

  func addPolyline(_ coordinates: [CLLocationCoordinate2D]) {
    let path = GMSMutablePath()
    coordinates.forEach { path.add($0) }
    let line = GMSPolyline(path: path)
    line.strokeColor = brandBlue
    line.strokeWidth = 4
    line.map = mapView
    overlays.append(line)
  }

  func addDot(_ center: CLLocationCoordinate2D) {
    let dot = GMSCircle(position: center, radius: 3)
    dot.strokeColor = brandBlue; dot.fillColor = brandBlue
    dot.map = mapView
    overlays.append(dot)
  }

  func setMarker(_ coordinate: CLLocationCoordinate2D?, title: String, snippet: String) {
    guard let coordinate else { marker?.map = nil; marker = nil; return }
    if marker == nil { marker = makePhoneMarker(coordinate) }
    marker?.position = coordinate
    marker?.title = title
    marker?.snippet = snippet
    marker?.opacity = 1
  }

  /// The orange triangle: tip at the marked point, long-press to drag (like Android's draggable marker).
  func setCursor(_ coordinate: CLLocationCoordinate2D?, title: String) {
    guard let coordinate else { cursor?.map = nil; cursor = nil; return }
    if cursor == nil {
      let cursor = GMSMarker(position: coordinate)
      cursor.icon = Self.cursorImage
      cursor.groundAnchor = CGPoint(x: 0.5, y: 1)
      cursor.isDraggable = true
      cursor.zIndex = 10
      cursor.map = mapView
      self.cursor = cursor
    }
    cursor?.position = coordinate
    cursor?.title = title
  }

  func moveCursor(to coordinate: CLLocationCoordinate2D, title: String) {
    cursor?.position = coordinate
    cursor?.title = title
  }

  func screenPoint(_ coordinate: CLLocationCoordinate2D) -> CGPoint { mapView.projection.point(for: coordinate) }

  /// Same as GoogleMap.snapshot: what is on screen, including the track and markers.
  func snapshot() -> UIImage? {
    guard mapView.bounds.width > 0, mapView.bounds.height > 0 else { return nil }
    let renderer = UIGraphicsImageRenderer(bounds: mapView.bounds)
    var drawn = false
    let image = renderer.image { _ in drawn = mapView.drawHierarchy(in: mapView.bounds, afterScreenUpdates: true) }
    return drawn ? image : nil
  }

  private func makePhoneMarker(_ coordinate: CLLocationCoordinate2D) -> GMSMarker {
    let marker = GMSMarker(position: coordinate)
    marker.icon = GMSMarker.markerImage(with: azure)
    marker.map = mapView
    return marker
  }

  // MARK: GMSMapViewDelegate

  func mapView(_ mapView: GMSMapView, willMove gesture: Bool) {
    if gesture { onUserGesture?() } // REASON_GESTURE
  }

  func mapView(_ mapView: GMSMapView, didTap marker: GMSMarker) -> Bool {
    guard isHistory else { return false } // Live mode shows the info window (title + snippet).
    mapView.selectedMarker = nil
    onAnnotationTap?(marker)
    return true
  }

  func mapView(_ mapView: GMSMapView, didBeginDragging marker: GMSMarker) {
    guard marker === cursor else { return }
    mapView.selectedMarker = nil
    onCursorDragStart?()
  }

  func mapView(_ mapView: GMSMapView, didDrag marker: GMSMarker) {
    if marker === cursor { onCursorDrag?(marker.position, false) }
  }

  func mapView(_ mapView: GMSMapView, didEndDragging marker: GMSMarker) {
    if marker === cursor { onCursorDrag?(marker.position, true) }
  }

  private static let cursorImage: UIImage = {
    let size: CGFloat = 32
    return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
      let path = UIBezierPath()
      path.move(to: CGPoint(x: size * 0.12, y: size * 0.15))
      path.addLine(to: CGPoint(x: size * 0.88, y: size * 0.15))
      path.addLine(to: CGPoint(x: size * 0.5, y: size * 0.95))
      path.close()
      cursorOrange.setFill(); path.fill()
      UIColor.white.setStroke(); path.lineWidth = 2; path.stroke()
    }
  }()
}

struct MapViewHost: UIViewRepresentable {
  let controller: MapController
  func makeUIView(context: Context) -> GMSMapView { controller.mapView }
  func updateUIView(_ uiView: GMSMapView, context: Context) {}
}
