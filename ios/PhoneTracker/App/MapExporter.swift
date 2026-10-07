import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Export the map snapshot with its labels below the map, preserving map attribution.
enum MapExporter {
  static func compose(_ map: UIImage, caption: String) throws -> URL {
    let scale = map.scale
    let width = map.size.width * scale // Work in pixels like the Android bitmap.
    let padding = max((width / 40).rounded(.down), 12)
    let font = UIFont.systemFont(ofSize: min(max(width / 32, 14), 32))
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font, .foregroundColor: UIColor(red: 30 / 255, green: 41 / 255, blue: 59 / 255, alpha: 1),
    ]
    let label = NSAttributedString(string: caption, attributes: attributes)
    let textHeight = ceil(label.boundingRect(with: CGSize(width: width - padding * 2, height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
    let mapHeight = map.size.height * scale
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1; format.opaque = true
    let output = UIGraphicsImageRenderer(size: CGSize(width: width, height: mapHeight + textHeight + padding * 2), format: format)
      .pngData { _ in
        UIColor.white.setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: width, height: mapHeight + textHeight + padding * 2))
        map.draw(in: CGRect(x: 0, y: 0, width: width, height: mapHeight))
        label.draw(with: CGRect(x: padding, y: mapHeight + padding, width: width - padding * 2, height: textHeight),
                   options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
      }
    let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("map_exports")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let week = Date().addingTimeInterval(-7 * 86_400)
    for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
      if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified < week {
        try? FileManager.default.removeItem(at: file)
      }
    }
    let file = directory.appendingPathComponent("PhoneTracker-\(UUID().uuidString).png")
    try output.write(to: file, options: .atomic)
    return file
  }
}

/// Wraps the exported PNG for the Files "儲存圖片" exporter.
struct PNGFile: FileDocument {
  static var readableContentTypes: [UTType] { [.png] }
  let data: Data
  init(url: URL) throws { data = try Data(contentsOf: url) }
  init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
