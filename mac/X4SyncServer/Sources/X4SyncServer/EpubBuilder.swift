import Foundation

enum EpubBuilder {
  static func buildHNLatest(stories: [HNStory], outputURL: URL) throws {
    let builder = ZipWriter()
    let now = ISO8601DateFormatter().string(from: Date())
    let lastUpdated = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
    let uuid = UUID().uuidString

    builder.add(path: "mimetype", data: Data("application/epub+zip".utf8))
    builder.add(path: "META-INF/container.xml", data: Data(containerXML.utf8))
    builder.add(path: "OEBPS/content.opf", data: Data(contentOPF(stories: stories, uuid: uuid, updated: now).utf8))
    builder.add(path: "OEBPS/nav.xhtml", data: Data(navXHTML(stories: stories, lastUpdated: lastUpdated).utf8))

    for (index, story) in stories.enumerated() {
      builder.add(path: "OEBPS/story-\(index + 1).xhtml", data: Data(storyXHTML(story, index: index + 1).utf8))
    }

    let data = builder.finalize()
    try data.write(to: outputURL, options: .atomic)
  }

  private static let containerXML = """
  <?xml version="1.0" encoding="UTF-8"?>
  <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
    <rootfiles>
      <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
    </rootfiles>
  </container>
  """

  private static func contentOPF(stories: [HNStory], uuid: String, updated: String) -> String {
    let manifestItems = stories.enumerated().map { index, _ in
      """
          <item id="story\(index + 1)" href="story-\(index + 1).xhtml" media-type="application/xhtml+xml"/>
      """
    }.joined(separator: "\n")

    let spineItems = stories.enumerated().map { index, _ in
      """
          <itemref idref="story\(index + 1)"/>
      """
    }.joined(separator: "\n")

    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <package version="3.0" unique-identifier="bookid" xmlns="http://www.idpf.org/2007/opf">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="bookid">urn:uuid:\(uuid)</dc:identifier>
        <dc:title>HN Latest</dc:title>
        <dc:language>en</dc:language>
        <dc:creator>X4 Sync Server</dc:creator>
        <meta property="dcterms:modified">\(updated)</meta>
      </metadata>
      <manifest>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    \(manifestItems)
      </manifest>
      <spine>
        <itemref idref="nav"/>
    \(spineItems)
      </spine>
    </package>
    """
  }

  private static func navXHTML(stories: [HNStory], lastUpdated: String) -> String {
    let items = stories.enumerated().map { index, story in
      let points = story.score.map { "\($0) points" } ?? "no points"
      return """
          <li>
            <a href="story-\(index + 1).xhtml">
              <span class="story-title">\(xml(story.title))</span>
              <span class="points">\(xml(points))</span>
            </a>
          </li>
      """
    }.joined(separator: "\n")

    return page(title: "HN Front Page") {
      """
      <h1>Hacker News</h1>
      <p class="meta">Last updated \(xml(lastUpdated))</p>
      <nav epub:type="toc" id="toc" class="front-page">
        <ol class="front-list">
      \(items)
        </ol>
      </nav>
      """
    }
  }

  private static func storyXHTML(_ story: HNStory, index: Int) -> String {
    let meta = [
      story.by.map { "by \($0)" },
      story.score.map { "\($0) points" }
    ].compactMap { $0 }.joined(separator: " · ")

    let link = story.url.map { "<p><a href=\"\(xml($0))\">\(xml($0))</a></p>" } ?? ""
    let comments = story.comments.isEmpty ? "<p>No comments captured.</p>" : story.comments.map(commentHTML).joined(separator: "\n")

    return page(title: story.title) {
      """
      <h1>\(xml(story.title))</h1>
      <p class="meta">#\(index) \(xml(meta))</p>
      \(link)
      <h2>Top Comments</h2>
      \(comments)
      """
    }
  }

  private static func commentHTML(_ comment: HNComment) -> String {
    let author = comment.by ?? "anonymous"
    let replies = comment.replies.map { reply in
      """
      <blockquote>
      \(commentHTML(reply))
      </blockquote>
      """
    }.joined(separator: "\n")

    return """
    <section class="comment">
      <p class="meta">\(xml(author))</p>
      <p>\(paragraphs(comment.text))</p>
      \(replies)
    </section>
    """
  }

  private static func page(title: String, body: () -> String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE html>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
    <head>
      <title>\(xml(title))</title>
      <style>
        body { font-family: serif; line-height: 1.35; }
        h1 { font-size: 1.6em; }
        h2 { font-size: 1.2em; margin-top: 1.4em; }
        .meta { color: #555; font-size: 0.9em; }
        .front-list { margin: 0.4em 0 0; padding-left: 1.35em; }
        .front-list li { margin: 0 0 0.45em; padding-left: 0.1em; }
        .front-list a { color: inherit; text-decoration: none; }
        .story-title { display: block; font-size: 0.96em; }
        .points { color: #555; display: block; font-size: 0.78em; margin-top: 0.05em; }
        .comment { border-top: 1px solid #ddd; margin-top: 1em; padding-top: 0.6em; }
        blockquote { border-left: 3px solid #ddd; margin-left: 0.5em; padding-left: 0.8em; }
      </style>
    </head>
    <body>
    \(body())
    </body>
    </html>
    """
  }

  private static func paragraphs(_ text: String) -> String {
    text.components(separatedBy: "\n\n")
      .map { xml($0).replacingOccurrences(of: "\n", with: "<br/>") }
      .joined(separator: "</p><p>")
  }

  private static func xml(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }
}
