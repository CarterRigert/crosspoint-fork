import AppKit
import Foundation

enum SleepTextOrientation: String, CaseIterable, Identifiable {
  case upsideDown
  case rightSideUp
  case landscapeLeft
  case landscapeRight

  var id: String { rawValue }

  var label: String {
    switch self {
    case .upsideDown:
      return "Upside down"
    case .rightSideUp:
      return "Right side up"
    case .landscapeLeft:
      return "Landscape left"
    case .landscapeRight:
      return "Landscape right"
    }
  }
}

enum SleepRenderer {
  private static let width = 480
  private static let height = 800

  static func render(inputsDir: URL, outputURL: URL, orientation: SleepTextOrientation = .upsideDown) throws {
    try runInputHookIfPresent(inputsDir: inputsDir)

    let content = SleepContent(
      todos: readLines(inputsDir.appendingPathComponent("todos.txt")),
      calendar: readLines(inputsDir.appendingPathComponent("calendar.txt")),
      weather: readLines(inputsDir.appendingPathComponent("weather.txt")),
      notes: readLines(inputsDir.appendingPathComponent("notes.txt"))
    )

    let pageSize = logicalPageSize(for: orientation)
    let rep = try renderPage(content, pageSize: pageSize)
    let bmp = makeBMP(from: rep, orientation: orientation)
    try bmp.write(to: outputURL, options: .atomic)
  }

  private static func logicalPageSize(for orientation: SleepTextOrientation) -> NSSize {
    switch orientation {
    case .upsideDown, .rightSideUp:
      return NSSize(width: width, height: height)
    case .landscapeLeft, .landscapeRight:
      return NSSize(width: height, height: width)
    }
  }

  private static func renderPage(_ content: SleepContent, pageSize: NSSize) throws -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(pageSize.width),
      pixelsHigh: Int(pageSize.height),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
      throw NSError(domain: "SleepRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not render sleep image."])
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.setShouldAntialias(true)
    context.cgContext.setAllowsAntialiasing(true)
    drawPage(content, pageSize: pageSize)
    NSGraphicsContext.restoreGraphicsState()

    return rep
  }

  private static func drawPage(_ content: SleepContent, pageSize: NSSize) {
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: pageSize.width, height: pageSize.height).fill()

    if pageSize.width > pageSize.height {
      drawLandscapePage(content, pageSize: pageSize)
    } else {
      drawPortraitPage(content, pageSize: pageSize)
    }
  }

  private static func drawPortraitPage(_ content: SleepContent, pageSize: NSSize) {
    drawText("Today", x: 28, top: 28, width: 424, pageHeight: pageSize.height, fontSize: 38, weight: .bold)
    drawText(dateString(), x: 30, top: 76, width: 424, pageHeight: pageSize.height, fontSize: 17, weight: .regular, color: .darkGray)

    section("Weather", lines: content.weather, x: 30, top: 128, width: 420, pageHeight: pageSize.height, maxLines: 3)
    section("Calendar", lines: content.calendar, x: 30, top: 238, width: 420, pageHeight: pageSize.height, maxLines: 5)
    section("Todo", lines: content.todos, x: 30, top: 420, width: 420, pageHeight: pageSize.height, maxLines: 7)
    section("Notes", lines: content.notes, x: 30, top: 656, width: 420, pageHeight: pageSize.height, maxLines: 3)

    drawText("Last updated \(lastUpdatedString())", x: 30, top: 758, width: 420, pageHeight: pageSize.height, fontSize: 13, weight: .regular, color: .darkGray)
  }

  private static func drawLandscapePage(_ content: SleepContent, pageSize: NSSize) {
    let margin: CGFloat = 28
    let gutter: CGFloat = 24
    let columnWidth = (pageSize.width - margin * 2 - gutter) / 2

    drawText("Today", x: margin, top: 22, width: 360, pageHeight: pageSize.height, fontSize: 32, weight: .bold)
    drawText(dateString(), x: margin, top: 62, width: 360, pageHeight: pageSize.height, fontSize: 15, weight: .regular, color: .darkGray)
    drawText("Last updated \(lastUpdatedString())", x: pageSize.width - margin - 250, top: 36, width: 250, pageHeight: pageSize.height, fontSize: 12, weight: .regular, color: .darkGray)

    let leftX = margin
    let rightX = margin + columnWidth + gutter

    section("Weather", lines: content.weather, x: leftX, top: 112, width: columnWidth, pageHeight: pageSize.height, maxLines: 3, lineHeight: 25)
    section("Calendar", lines: content.calendar, x: rightX, top: 112, width: columnWidth, pageHeight: pageSize.height, maxLines: 5, lineHeight: 25)
    section("Todo", lines: content.todos, x: leftX, top: 288, width: columnWidth, pageHeight: pageSize.height, maxLines: 5, lineHeight: 25)
    section("Notes", lines: content.notes, x: rightX, top: 288, width: columnWidth, pageHeight: pageSize.height, maxLines: 5, lineHeight: 25)
  }

  private static func section(
    _ title: String,
    lines: [String],
    x: CGFloat,
    top: CGFloat,
    width: CGFloat,
    pageHeight: CGFloat,
    maxLines: Int,
    lineHeight: CGFloat = 28
  ) {
    drawRule(x: x, top: top - 14, width: width, pageHeight: pageHeight)
    drawText(title.uppercased(), x: x, top: top, width: width, pageHeight: pageHeight, fontSize: 13, weight: .semibold, color: .darkGray)

    let shown = Array(lines.prefix(maxLines))
    if shown.isEmpty {
      drawText("No items", x: x, top: top + 30, width: width, pageHeight: pageHeight, fontSize: 18, weight: .regular, color: .gray)
      return
    }

    for (index, line) in shown.enumerated() {
      drawText(line, x: x, top: top + 30 + CGFloat(index) * lineHeight, width: width, pageHeight: pageHeight, fontSize: 20, weight: .regular)
    }
  }

  private static func drawRule(x: CGFloat, top: CGFloat, width: CGFloat, pageHeight: CGFloat) {
    NSColor.black.withAlphaComponent(0.18).setFill()
    NSRect(x: x, y: pageHeight - top - 1, width: width, height: 1).fill()
  }

  private static func drawText(
    _ text: String,
    x: CGFloat,
    top: CGFloat,
    width: CGFloat,
    pageHeight: CGFloat,
    fontSize: CGFloat,
    weight: NSFont.Weight,
    color: NSColor = .black
  ) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail

    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
      .foregroundColor: color,
      .paragraphStyle: paragraph
    ]

    let height = fontSize * 1.4
    let rect = NSRect(x: x, y: pageHeight - top - height, width: width, height: height)
    NSAttributedString(string: text, attributes: attrs).draw(in: rect)
  }

  private static func readLines(_ url: URL) -> [String] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private static func runInputHookIfPresent(inputsDir: URL) throws {
    let hook = inputsDir.appendingPathComponent("build_sleep_inputs.sh")
    guard FileManager.default.isExecutableFile(atPath: hook.path) else { return }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [hook.path]
    process.currentDirectoryURL = inputsDir
    try process.run()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
      throw NSError(
        domain: "SleepRenderer",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: "Sleep input hook failed with exit code \(process.terminationStatus)."]
      )
    }
  }

  private static func makeBMP(from rep: NSBitmapImageRep, orientation: SleepTextOrientation) -> Data {
    let bitsPerPixel = 2
    let paletteBytes = 4 * 4
    let pixelOffset = 14 + 40 + paletteBytes
    let rowBytes = ((width * bitsPerPixel + 31) / 32) * 4
    let rowPixelBytes = (width * bitsPerPixel + 7) / 8
    let rowPadding = rowBytes - rowPixelBytes
    let pixelBytes = rowBytes * height
    let fileSize = pixelOffset + pixelBytes

    var data = Data()
    data.reserveCapacity(fileSize)

    data.append(contentsOf: [0x42, 0x4D])
    data.appendUInt32LE(UInt32(fileSize))
    data.appendUInt16LE(0)
    data.appendUInt16LE(0)
    data.appendUInt32LE(UInt32(pixelOffset))
    data.appendUInt32LE(40)
    data.appendInt32LE(Int32(width))
    data.appendInt32LE(-Int32(height))
    data.appendUInt16LE(1)
    data.appendUInt16LE(UInt16(bitsPerPixel))
    data.appendUInt32LE(0)
    data.appendUInt32LE(UInt32(pixelBytes))
    data.appendInt32LE(2835)
    data.appendInt32LE(2835)
    data.appendUInt32LE(4)
    data.appendUInt32LE(4)

    for level in [UInt8(0), UInt8(85), UInt8(170), UInt8(255)] {
      data.append(level)
      data.append(level)
      data.append(level)
      data.append(0)
    }

    for y in 0..<height {
      var currentByte: UInt8 = 0
      for x in 0..<width {
        let source = sourcePixel(forOutputX: x, outputY: y, sourceWidth: rep.pixelsWide, sourceHeight: rep.pixelsHigh, orientation: orientation)
        let color = rep.colorAt(x: source.x, y: source.y)?.usingColorSpace(.deviceRGB) ?? .white
        let red = max(0, min(255, Int(round(color.redComponent * 255))))
        let green = max(0, min(255, Int(round(color.greenComponent * 255))))
        let blue = max(0, min(255, Int(round(color.blueComponent * 255))))
        let luminance = (77 * red + 150 * green + 29 * blue) >> 8
        let level = UInt8(max(0, min(3, (luminance + 42) / 85)))
        currentByte |= level << (6 - ((x & 3) * 2))
        if (x & 3) == 3 {
          data.append(currentByte)
          currentByte = 0
        }
      }
      if (width & 3) != 0 {
        data.append(currentByte)
      }
      for _ in 0..<rowPadding {
        data.append(0)
      }
    }

    return data
  }

  private static func sourcePixel(
    forOutputX x: Int,
    outputY y: Int,
    sourceWidth: Int,
    sourceHeight: Int,
    orientation: SleepTextOrientation
  ) -> (x: Int, y: Int) {
    switch orientation {
    case .rightSideUp:
      return (x, y)
    case .upsideDown:
      return (sourceWidth - 1 - x, sourceHeight - 1 - y)
    case .landscapeLeft:
      return (sourceWidth - 1 - y, x)
    case .landscapeRight:
      return (y, sourceHeight - 1 - x)
    }
  }

  private static func dateString() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, MMM d"
    return formatter.string(from: Date())
  }

  private static func lastUpdatedString() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d, h:mm a"
    return formatter.string(from: Date())
  }
}

private struct SleepContent {
  let todos: [String]
  let calendar: [String]
  let weather: [String]
  let notes: [String]
}
