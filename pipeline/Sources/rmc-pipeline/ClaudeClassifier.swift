import Foundation
import RMCCore

struct ClassificationMatch {
    let collectionSlug: String
    let quote: String
    let blurb: String
}

enum ClaudeClassifierError: Error {
    case missingAPIKey
    case badStatus(Int, String)
    case unexpectedResponseShape
}

struct ClaudeClassifier {
    private let apiKey: String
    private let model = "claude-opus-4-8"

    init() throws {
        guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
            throw ClaudeClassifierError.missingAPIKey
        }
        apiKey = key
    }

    func classify(transcript: String, collections: [EpisodeCollection]) async throws -> [ClassificationMatch] {
        let taxonomyText = collections
            .map { "- \($0.slug): \($0.title) -- \($0.collectionDescription)" }
            .joined(separator: "\n")
        let userContent = """
        You are tagging a podcast episode transcript against a fixed set of collections. \
        Only report a match when the transcript actually discusses that collection's topic -- \
        don't force matches. A single episode can match zero, one, or several collections.

        Collections:
        \(taxonomyText)

        Transcript:
        \(transcript)
        """

        // Forced tool_choice + strict:true guarantees parseable JSON, rather than
        // hoping a prompt-asked-for-JSON response comes back clean.
        let requestBody: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "tools": [[
                "name": "record_matches",
                "description": "Record which collections this episode transcript matches.",
                "strict": true,
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "matches": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "collectionSlug": ["type": "string"],
                                    "quote": [
                                        "type": "string",
                                        "description": "A short (5-15 word) VERBATIM substring copied exactly from the transcript, anchoring where this match occurs.",
                                    ],
                                    "blurb": [
                                        "type": "string",
                                        "description": "One sentence describing what happens at this moment.",
                                    ],
                                ],
                                "required": ["collectionSlug", "quote", "blurb"],
                                "additionalProperties": false,
                            ],
                        ]
                    ],
                    "required": ["matches"],
                    "additionalProperties": false,
                ],
            ]],
            "tool_choice": ["type": "tool", "name": "record_matches"],
            "messages": [["role": "user", "content": userContent]],
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ClaudeClassifierError.badStatus(status, String(data: data, encoding: .utf8) ?? "")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw ClaudeClassifierError.unexpectedResponseShape
        }

        for block in content where block["type"] as? String == "tool_use" {
            guard let input = block["input"] as? [String: Any],
                  let matches = input["matches"] as? [[String: Any]] else { continue }
            return matches.compactMap { match in
                guard let slug = match["collectionSlug"] as? String,
                      let quote = match["quote"] as? String,
                      let blurb = match["blurb"] as? String else { return nil }
                return ClassificationMatch(collectionSlug: slug, quote: quote, blurb: blurb)
            }
        }
        return []
    }

    /// Synthesizes a single paragraph summarizing how the show has discussed a product across
    /// every episode that matched it, from the already-recorded per-episode blurbs (not full
    /// transcripts -- keeps this pass cheap since classify already extracted the salient moments).
    func synthesize(productTitle: String, moments: [(episodeTitle: String, blurb: String)]) async throws -> String {
        let momentsText = moments
            .map { "- (\($0.episodeTitle)) \($0.blurb)" }
            .joined(separator: "\n")
        let userContent = """
        You are writing a single paragraph for a \"ON RETROMACCAST\" section of a fan app, summarizing \
        how James and John, the two hosts of the vintage-Mac podcast RetroMacCast, have talked about a \
        specific product across the show's history. Write 3-5 sentences, in the voice of a knowledgeable \
        fan describing the show's relationship with this product -- not a product review, a synthesis of \
        what these specific episodes reveal about how it's been discussed. Refer to them by name (James, \
        John, or "James and John") at least once if it reads naturally -- don't default to generic phrases \
        like \"the hosts\" or \"the crew\" every time, but don't force a name in if the moments don't make \
        clear who said what; it's fine to use "the hosts" when neither host is specifically identifiable \
        for a given moment. Do not invent details not supported by the moments below, including which host \
        said what unless a moment specifically names one of them. Do not mention episode numbers or titles \
        directly in the prose.

        Product: \(productTitle)

        Moments from episodes that discussed this product:
        \(momentsText)
        """

        let requestBody: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "tools": [[
                "name": "record_synthesis",
                "description": "Record the synthesized paragraph.",
                "strict": true,
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "paragraph": ["type": "string"],
                    ],
                    "required": ["paragraph"],
                    "additionalProperties": false,
                ],
            ]],
            "tool_choice": ["type": "tool", "name": "record_synthesis"],
            "messages": [["role": "user", "content": userContent]],
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ClaudeClassifierError.badStatus(status, String(data: data, encoding: .utf8) ?? "")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw ClaudeClassifierError.unexpectedResponseShape
        }

        for block in content where block["type"] as? String == "tool_use" {
            guard let input = block["input"] as? [String: Any],
                  let paragraph = input["paragraph"] as? String else { continue }
            return paragraph
        }
        throw ClaudeClassifierError.unexpectedResponseShape
    }
}
