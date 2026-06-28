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

struct SleepRenderSections: Equatable {
  var weather: Bool
  var calendar: Bool
  var todo: Bool
  var notes: Bool
  var hn: Bool

  static let all = SleepRenderSections(weather: true, calendar: true, todo: true, notes: true, hn: true)
}

enum SleepRenderer {
  private static let width = 480
  private static let height = 800

  static func render(
    inputsDir: URL,
    outputURL: URL,
    orientation: SleepTextOrientation = .upsideDown,
    sections: SleepRenderSections = .all
  ) throws {
    try runInputHookIfPresent(inputsDir: inputsDir)

    let content = SleepContent(
      todos: readLines(inputsDir.appendingPathComponent("todos.txt")),
      calendar: readLines(inputsDir.appendingPathComponent("calendar.txt")),
      weather: readLines(inputsDir.appendingPathComponent("weather.txt")),
      notes: readLines(inputsDir.appendingPathComponent("notes.txt")),
      hn: readLines(inputsDir.appendingPathComponent("hn.txt"))
    )

    let pageSize = logicalPageSize(for: orientation)
    let rep = try renderPage(content, pageSize: pageSize, sections: sections)
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

  private static func renderPage(_ content: SleepContent, pageSize: NSSize, sections: SleepRenderSections) throws -> NSBitmapImageRep {
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
    drawPage(content, pageSize: pageSize, sections: sections)
    NSGraphicsContext.restoreGraphicsState()

    return rep
  }

  private static func drawPage(_ content: SleepContent, pageSize: NSSize, sections: SleepRenderSections) {
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: pageSize.width, height: pageSize.height).fill()

    if pageSize.width > pageSize.height {
      drawLandscapePage(content, pageSize: pageSize, sections: sections)
    } else {
      drawPortraitPage(content, pageSize: pageSize, sections: sections)
    }
  }

  private static func drawPortraitPage(_ content: SleepContent, pageSize: NSSize, sections: SleepRenderSections) {
    drawText("Today", x: 28, top: 28, width: 424, pageHeight: pageSize.height, fontSize: 38, weight: .bold)
    drawText(dateString(), x: 30, top: 76, width: 424, pageHeight: pageSize.height, fontSize: 17, weight: .regular, color: .darkGray)

    drawStackedSections(
      sectionSpecs(content: content, sections: sections),
      x: 30,
      top: 128,
      width: 420,
      bottomTop: 738,
      pageHeight: pageSize.height
    )

    drawText("Last updated \(lastUpdatedString())", x: 30, top: 758, width: 420, pageHeight: pageSize.height, fontSize: 13, weight: .regular, color: .darkGray)
  }

  private static func drawLandscapePage(_ content: SleepContent, pageSize: NSSize, sections: SleepRenderSections) {
    let margin: CGFloat = 28
    let gutter: CGFloat = 24
    let columnWidth = (pageSize.width - margin * 2 - gutter) / 2

    drawText("Today", x: margin, top: 22, width: 360, pageHeight: pageSize.height, fontSize: 32, weight: .bold)
    drawText(dateString(), x: margin, top: 62, width: 360, pageHeight: pageSize.height, fontSize: 15, weight: .regular, color: .darkGray)
    drawText("Last updated \(lastUpdatedString())", x: pageSize.width - margin - 250, top: 36, width: 250, pageHeight: pageSize.height, fontSize: 12, weight: .regular, color: .darkGray)

    let specs = sectionSpecs(content: content, sections: sections)
    guard !specs.isEmpty else {
      drawText("No sections enabled", x: margin, top: 160, width: pageSize.width - margin * 2, pageHeight: pageSize.height, fontSize: 20, weight: .regular, color: .gray)
      return
    }

    if specs.count == 1 {
      drawStackedSections(specs, x: margin, top: 112, width: pageSize.width - margin * 2, bottomTop: 430, pageHeight: pageSize.height)
      return
    }

    let split = Int(ceil(Double(specs.count) / 2.0))
    drawStackedSections(
      Array(specs.prefix(split)),
      x: margin,
      top: 112,
      width: columnWidth,
      bottomTop: 430,
      pageHeight: pageSize.height,
      gap: 16
    )
    drawStackedSections(
      Array(specs.dropFirst(split)),
      x: margin + columnWidth + gutter,
      top: 112,
      width: columnWidth,
      bottomTop: 430,
      pageHeight: pageSize.height,
      gap: 16
    )
  }

  private static func sectionSpecs(content: SleepContent, sections: SleepRenderSections) -> [SleepSectionSpec] {
    var specs: [SleepSectionSpec] = []
    if sections.weather {
      specs.append(SleepSectionSpec(title: "Weather", lines: content.weather, maxLines: 3, lineHeight: 25, weight: 1.0))
    }
    if sections.calendar {
      specs.append(SleepSectionSpec(title: "Calendar", lines: content.calendar, maxLines: 5, lineHeight: 25, weight: 1.35))
    }
    if sections.todo {
      specs.append(SleepSectionSpec(title: "Todo", lines: content.todos, maxLines: 12, lineHeight: 28, weight: 2.2))
    }
    if sections.notes {
      specs.append(SleepSectionSpec(title: "Notes", lines: content.notes, maxLines: 4, lineHeight: 25, weight: 1.0))
    }
    if sections.hn {
      specs.append(SleepSectionSpec(title: "HN Top 3", lines: content.hn, maxLines: 3, lineHeight: 62, weight: 4.2, style: .hackerNews))
    }
    return specs
  }

  private static func drawStackedSections(
    _ specs: [SleepSectionSpec],
    x: CGFloat,
    top: CGFloat,
    width: CGFloat,
    bottomTop: CGFloat,
    pageHeight: CGFloat,
    gap: CGFloat = 18
  ) {
    guard !specs.isEmpty else {
      drawText("No sections enabled", x: x, top: top + 30, width: width, pageHeight: pageHeight, fontSize: 18, weight: .regular, color: .gray)
      return
    }

    let totalGap = gap * CGFloat(max(0, specs.count - 1))
    let availableHeight = max(0, bottomTop - top - totalGap)
    let totalWeight = max(1, specs.reduce(CGFloat(0)) { $0 + $1.weight })
    var currentTop = top

    for spec in specs {
      let height = availableHeight * (spec.weight / totalWeight)
      let visibleRows = max(1, min(spec.maxLines, Int((height - 34) / spec.lineHeight)))
      if spec.style == .hackerNews {
        hackerNewsSection(
          spec.title,
          lines: spec.lines,
          x: x,
          top: currentTop,
          width: width,
          pageHeight: pageHeight,
          maxStories: visibleRows,
          storyHeight: spec.lineHeight
        )
      } else {
        section(
          spec.title,
          lines: spec.lines,
          x: x,
          top: currentTop,
          width: width,
          pageHeight: pageHeight,
          maxLines: visibleRows,
          lineHeight: spec.lineHeight
        )
      }
      currentTop += height + gap
    }
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

  private static func hackerNewsSection(
    _ title: String,
    lines: [String],
    x: CGFloat,
    top: CGFloat,
    width: CGFloat,
    pageHeight: CGFloat,
    maxStories: Int,
    storyHeight: CGFloat
  ) {
    drawRule(x: x, top: top - 14, width: width, pageHeight: pageHeight)
    drawText(title.uppercased(), x: x, top: top, width: width, pageHeight: pageHeight, fontSize: 13, weight: .semibold, color: .darkGray)

    let stories = hackerNewsStories(from: lines)
    if stories.isEmpty {
      drawText("No items", x: x, top: top + 30, width: width, pageHeight: pageHeight, fontSize: 18, weight: .regular, color: .gray)
      return
    }

    for (index, story) in stories.prefix(maxStories).enumerated() {
      let storyTop = top + 30 + CGFloat(index) * storyHeight
      drawFittingText(story.title, x: x, top: storyTop, width: width, pageHeight: pageHeight, fontSize: 18, minimumFontSize: 10, weight: .regular)
      if !story.stats.isEmpty {
        drawText(story.stats, x: x, top: storyTop + 24, width: width, pageHeight: pageHeight, fontSize: 13, weight: .regular, color: .darkGray)
      }
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

  private static func drawFittingText(
    _ text: String,
    x: CGFloat,
    top: CGFloat,
    width: CGFloat,
    pageHeight: CGFloat,
    fontSize: CGFloat,
    minimumFontSize: CGFloat,
    weight: NSFont.Weight,
    color: NSColor = .black
  ) {
    var size = fontSize
    while size > minimumFontSize {
      let font = NSFont.systemFont(ofSize: size, weight: weight)
      let measured = (text as NSString).size(withAttributes: [.font: font]).width
      if measured <= width {
        break
      }
      size -= 1
    }
    drawText(text, x: x, top: top, width: width, pageHeight: pageHeight, fontSize: size, weight: weight, color: color)
  }

  private static func hackerNewsStories(from lines: [String]) -> [HackerNewsSleepStory] {
    var stories: [HackerNewsSleepStory] = []
    var index = 0
    while index < lines.count && stories.count < 3 {
      let title = lines[index]
      let stats = index + 1 < lines.count ? lines[index + 1] : ""
      stories.append(HackerNewsSleepStory(title: title, stats: stats))
      index += 2
    }
    return stories
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
  let hn: [String]
}

private struct SleepSectionSpec {
  let title: String
  let lines: [String]
  let maxLines: Int
  let lineHeight: CGFloat
  let weight: CGFloat
  var style: SleepSectionStyle = .standard
}

private enum SleepSectionStyle {
  case standard
  case hackerNews
}

private struct HackerNewsSleepStory {
  let title: String
  let stats: String
}
