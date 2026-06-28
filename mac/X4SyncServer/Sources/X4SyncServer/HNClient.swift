import Foundation

struct HNStory: Sendable {
  let id: Int
  let title: String
  let url: String?
  let by: String?
  let score: Int?
  let commentCount: Int?
  let comments: [HNComment]
}

struct HNComment: Sendable {
  let by: String?
  let text: String
  let replies: [HNComment]
}

final class HNClient: @unchecked Sendable {
  private struct Item: Decodable {
    let id: Int
    let type: String?
    let by: String?
    let time: Int?
    let text: String?
    let title: String?
    let url: String?
    let score: Int?
    let descendants: Int?
    let kids: [Int]?
    let dead: Bool?
    let deleted: Bool?
  }

  private let baseURL = URL(string: "https://hacker-news.firebaseio.com/v0")!
  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func frontPageStories(limit: Int, commentsPerStory: Int) async throws -> [HNStory] {
    let ids: [Int] = try await getJSON(baseURL.appendingPathComponent("topstories.json"))
    var stories: [HNStory] = []

    for id in ids.prefix(limit) {
      guard let item = try await item(id), item.deleted != true, item.dead != true else {
        continue
      }

      let commentIds = Array((item.kids ?? []).prefix(commentsPerStory))
      var comments: [HNComment] = []
      for commentId in commentIds {
        if let comment = try await comment(commentId, depth: 1) {
          comments.append(comment)
        }
      }

      stories.append(
        HNStory(
          id: item.id,
          title: item.title ?? "Untitled",
          url: item.url,
          by: item.by,
          score: item.score,
          commentCount: item.descendants,
          comments: comments
        )
      )
    }

    return stories
  }

  private func item(_ id: Int) async throws -> Item? {
    try await getJSON(baseURL.appendingPathComponent("item/\(id).json"))
  }

  private func comment(_ id: Int, depth: Int) async throws -> HNComment? {
    guard let item = try await item(id),
          item.deleted != true,
          item.dead != true,
          item.type == "comment",
          let rawText = item.text,
          !rawText.isEmpty
    else {
      return nil
    }

    var replies: [HNComment] = []
    if depth > 0 {
      for replyId in (item.kids ?? []).prefix(2) {
        if let reply = try await comment(replyId, depth: depth - 1) {
          replies.append(reply)
        }
      }
    }

    return HNComment(by: item.by, text: htmlToText(rawText), replies: replies)
  }

  private func getJSON<T: Decodable>(_ url: URL) async throws -> T {
    let (data, response) = try await session.data(from: url)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw NSError(domain: "HNClient", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Hacker News returned HTTP \(http.statusCode)."])
    }
    return try JSONDecoder().decode(T.self, from: data)
  }

  private func htmlToText(_ html: String) -> String {
    var text = html
      .replacingOccurrences(of: "<p>", with: "\n\n", options: .caseInsensitive)
      .replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
      .replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
      .replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)

    text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

    let entities: [String: String] = [
      "&amp;": "&",
      "&lt;": "<",
      "&gt;": ">",
      "&quot;": "\"",
      "&#x27;": "'",
      "&#x2F;": "/",
      "&#039;": "'"
    ]

    for (entity, replacement) in entities {
      text = text.replacingOccurrences(of: entity, with: replacement)
    }

    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
