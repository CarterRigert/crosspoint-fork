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

    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    draw(content, orientation: orientation)
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff)
    else {
      throw NSError(domain: "SleepRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not render sleep image."])
    }

    let bmp = makeBMP(from: rep)
    try bmp.write(to: outputURL, options: .atomic)
  }

  private static func draw(_ content: SleepContent, orientation: SleepTextOrientation) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }

    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    context.saveGState()

    let logicalSize: NSSize
    switch orientation {
    case .upsideDown:
      logicalSize = NSSize(width: width, height: height)
    case .rightSideUp:
      logicalSize = NSSize(width: width, height: height)
      context.translateBy(x: CGFloat(width), y: CGFloat(height))
      context.rotate(by: .pi)
    case .landscapeLeft:
      logicalSize = NSSize(width: height, height: width)
      context.translateBy(x: CGFloat(width), y: 0)
      context.rotate(by: .pi / 2)
    case .landscapeRight:
      logicalSize = NSSize(width: height, height: width)
      context.translateBy(x: 0, y: CGFloat(height))
      context.rotate(by: -.pi / 2)
    }

    drawPage(content, pageSize: logicalSize)
    context.restoreGState()
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

  private static func makeBMP(from rep: NSBitmapImageRep) -> Data {
    let rowBytes = ((width * 3 + 3) / 4) * 4
    let pixelBytes = rowBytes * height
    let fileSize = 14 + 40 + pixelBytes

    var data = Data()
    data.reserveCapacity(fileSize)

    data.append(contentsOf: [0x42, 0x4D])
    data.appendUInt32LE(UInt32(fileSize))
    data.appendUInt16LE(0)
    data.appendUInt16LE(0)
    data.appendUInt32LE(54)
    data.appendUInt32LE(40)
    data.appendInt32LE(Int32(width))
    data.appendInt32LE(Int32(height))
    data.appendUInt16LE(1)
    data.appendUInt16LE(24)
    data.appendUInt32LE(0)
    data.appendUInt32LE(UInt32(pixelBytes))
    data.appendInt32LE(2835)
    data.appendInt32LE(2835)
    data.appendUInt32LE(0)
    data.appendUInt32LE(0)

    let padding = [UInt8](repeating: 0, count: rowBytes - width * 3)
    for y in 0..<height {
      for x in 0..<width {
        let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) ?? .white
        let red = UInt8(max(0, min(255, Int(round(color.redComponent * 255)))))
        let green = UInt8(max(0, min(255, Int(round(color.greenComponent * 255)))))
        let blue = UInt8(max(0, min(255, Int(round(color.blueComponent * 255)))))
        data.append(blue)
        data.append(green)
        data.append(red)
      }
      data.append(contentsOf: padding)
    }

    return data
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
