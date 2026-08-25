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

    /// Mines a batch of episodes' already-extracted collection-item blurbs for standalone
    /// "trivia" facts -- interesting, specific, surprising details about the show, not a
    /// product-by-product summary the way `synthesize` is. Grounding reuses the same trick
    /// `classify` uses for its `quote` field: rather than trust the model to report which
    /// episode a fact came from (it's seen dozens of episodes in one prompt, easy to misattribute),
    /// each fact instead returns a `sourceBlurb` that must be copied VERBATIM from one of the
    /// blurbs given below, or omitted entirely for a genuine cross-episode aggregate fact. The
    /// caller resolves `sourceBlurb` back to its `CollectionItem` via an exact-string lookup --
    /// zero hallucinated episode attribution possible, since a mismatched string just fails to
    /// resolve rather than silently pointing at the wrong episode.
    func generateTrivia(episodes: [(title: String, pubDate: String, blurbs: [String])]) async throws -> [(factText: String, sourceBlurb: String?)] {
        // No leading bullet/dash decoration on each blurb line -- an earlier version prefixed
        // each with "- " and the model would copy that prefix into `sourceBlurb` as if it were
        // part of the moment text, which then failed the caller's exact-string lookup (the
        // stored `collection_items.blurb` has no such prefix). Plain indentation avoids giving
        // the model any extra characters to mistake for part of the quotable span.
        let episodesText = episodes
            .filter { !$0.blurbs.isEmpty }
            .map { episode in
                let blurbLines = episode.blurbs.map { "    \($0)" }.joined(separator: "\n")
                return "\(episode.title) (\(episode.pubDate)):\n\(blurbLines)"
            }
            .joined(separator: "\n\n")

        let userContent = """
        You are mining a batch of episode moments from the vintage-Mac podcast RetroMacCast \
        (hosted by James and John) for standalone trivia facts -- the kind of surprising, \
        specific, concrete detail a fan would enjoy reading on its own, out of context. This is \
        NOT a product summary and NOT a recap -- avoid generic observations like "the hosts talk \
        about Macs a lot" or "they discussed several vintage computers." Favor the odd, the \
        funny, the specific number, the recurring bit, the surprising opinion.

        Name "James" or "John" specifically when a moment makes clear who said or did something; \
        otherwise say "the hosts." Never invent a detail the moments below don't support. Do not \
        mention episode numbers or titles in the fact text itself.

        For each fact, also record `sourceBlurb`: copy ONLY the moment's own text, verbatim and \
        character-for-character, with no leading indentation and nothing added -- it must be an \
        exact substring match against one of the moment lines below, not a paraphrase and not \
        that line plus any extra characters. If a fact instead synthesizes a pattern across \
        multiple moments below (e.g. a recurring joke or a running count) rather than coming \
        from one specific moment, leave `sourceBlurb` out entirely -- don't force a single-moment \
        citation onto a fact that's really an aggregate observation.

        Produce between 5 and 8 facts from this batch.

        Episode moments:
        \(episodesText)
        """

        let requestBody: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "tools": [[
                "name": "record_trivia",
                "description": "Record the trivia facts mined from this batch of episode moments.",
                "strict": true,
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "facts": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "factText": [
                                        "type": "string",
                                        "description": "A single self-contained trivia fact, 1-2 sentences.",
                                    ],
                                    "sourceBlurb": [
                                        "type": ["string", "null"],
                                        "description": "The exact moment text this fact was drawn from, copied verbatim, or null for a cross-episode aggregate fact.",
                                    ],
                                ],
                                "required": ["factText", "sourceBlurb"],
                                "additionalProperties": false,
                            ],
                        ]
                    ],
                    "required": ["facts"],
                    "additionalProperties": false,
                ],
            ]],
            "tool_choice": ["type": "tool", "name": "record_trivia"],
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
                  let facts = input["facts"] as? [[String: Any]] else { continue }
            return facts.compactMap { fact in
                guard let factText = fact["factText"] as? String else { return nil }
                let sourceBlurb = fact["sourceBlurb"] as? String
                return (factText: factText, sourceBlurb: sourceBlurb)
            }
        }
        return []
    }

    /// Mines ONE episode's full transcript (not pre-extracted blurbs, unlike `generateTrivia`
    /// -- a glossary term is often explained in passing, not necessarily inside a moment that
    /// already got matched to a product/collection) for moments where the hosts actually
    /// explain, define, or clarify a specific piece of vintage Mac/Apple jargon for the
    /// listener -- not just say the word in passing. Same verbatim-`quote` anchoring `classify`
    /// uses, resolved back to a real segment/timestamp by the caller via `resolveSegment`.
    func generateGlossaryTerms(transcript: String) async throws -> [GlossaryMatch] {
        let userContent = """
        You are mining a RetroMacCast (hosted by James and John) episode transcript for moments \
        where a host actually EXPLAINS, DEFINES, or CLARIFIES a specific piece of vintage \
        Macintosh/Apple terminology, jargon, or acronym for the listener -- not just mentions the \
        word in passing while assuming the listener already knows it. Skip anything not \
        genuinely explained here.

        Do NOT report the name of a specific Apple computer model or product line itself (e.g. \
        "Macintosh Plus", "Power Mac 6100", "Newton MessagePad", "PowerBook Duo", "iMac G3") as a \
        term, even if a host explains its history or specs at length -- this app has a separate, \
        dedicated Museum section covering every such product in depth, and reporting it here too \
        would just be redundant with that. This glossary is for GENERAL terminology instead: \
        jargon, acronyms, technologies, protocols, UI/OS concepts, accessories, brand names for a \
        *kind* of thing rather than one specific numbered model, and slang -- the vocabulary \
        someone would need explained to follow the show, not the products themselves.

        Many episodes genuinely have NO such moment. When that's the case here, call \
        record_glossary_terms with terms: [] -- a literal empty array, which is a completely \
        normal and fully expected result for an episode like that, worth exactly as much credit \
        as reporting several real terms. Every entry you do report must be something a listener \
        would actually recognize as a real, useful dictionary headword drawn from this specific \
        transcript.

        For each REAL term found, record:
        - term: the word or acronym itself, as it would appear as a dictionary headword (e.g. \
        "SCSI", "HyperCard", "Happy Mac").
        - expansion: if `term` is an acronym, its spelled-out full name (e.g. "Small Computer \
        System Interface"); null if `term` already is the full name.
        - definition: a clear, standalone 1-2 sentence dictionary-style definition IN YOUR OWN \
        WORDS -- not a paraphrase of exactly what was said, a genuine definition someone could \
        read with no other context and understand. Never invent detail the transcript doesn't \
        support.
        - quote: a short (5-15 word) VERBATIM substring copied exactly from the transcript, \
        anchoring where this explanation occurs.

        Transcript:
        \(transcript)
        """

        let requestBody: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "tools": [[
                "name": "record_glossary_terms",
                "description": "Record the vintage-Mac terminology explained in this episode transcript.",
                "strict": true,
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "terms": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "term": ["type": "string"],
                                    "expansion": [
                                        "type": ["string", "null"],
                                        "description": "The spelled-out acronym, or null if `term` already is the full name.",
                                    ],
                                    "definition": [
                                        "type": "string",
                                        "description": "A standalone 1-2 sentence dictionary-style definition, in the model's own words.",
                                    ],
                                    "quote": [
                                        "type": "string",
                                        "description": "A short (5-15 word) VERBATIM substring copied exactly from the transcript, anchoring where this explanation occurs.",
                                    ],
                                ],
                                "required": ["term", "expansion", "definition", "quote"],
                                "additionalProperties": false,
                            ],
                        ]
                    ],
                    "required": ["terms"],
                    "additionalProperties": false,
                ],
            ]],
            "tool_choice": ["type": "tool", "name": "record_glossary_terms"],
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
                  let terms = input["terms"] as? [[String: Any]] else { continue }
            return terms.compactMap { entry in
                guard let term = entry["term"] as? String,
                      let definition = entry["definition"] as? String,
                      let quote = entry["quote"] as? String else { return nil }
                let expansion = entry["expansion"] as? String
                return GlossaryMatch(term: term, expansion: expansion, definition: definition, quote: quote)
            }
        }
        return []
    }
}

struct GlossaryMatch {
    let term: String
    let expansion: String?
    let definition: String
    let quote: String
}
