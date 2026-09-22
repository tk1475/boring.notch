//
//  SlackMessageFormatter.swift
//  boringNotch
//
//  Converts Slack "mrkdwn" message text into human-readable text for display.
//  Slack encodes mentions, channels, links, and special references as tokens
//  like <@U123>, <#C123|general>, <https://x|label>, <!here>, and escapes
//  &, <, > as HTML entities. Emoji arrive as :shortcode:.
//

import Foundation

enum SlackMessageFormatter {
    /// Formats one Slack message. `resolveUserName` maps a user id to a display
    /// name (without the leading @) and may return nil if unknown.
    static func format(
        _ raw: String,
        resolveUserName: (String) async -> String?
    ) async -> String {
        var text = raw

        // User mentions: <@U123> or <@U123|label>. Resolve unlabeled ids.
        text = await replaceUserMentions(in: text, resolveUserName: resolveUserName)

        // Channel mentions: <#C123|name> or <#C123>.
        text = replace(pattern: "<#[CG][A-Z0-9]+\\|([^>]+)>", in: text) { groups in
            "#\(groups[1])"
        }
        text = replace(pattern: "<#[CG][A-Z0-9]+>", in: text) { _ in "#channel" }

        // Special mentions: <!here>, <!channel>, <!everyone>, <!subteam^S|name>,
        // and the labeled forms like <!here|here>.
        text = replace(pattern: "<!subteam\\^[A-Z0-9]+\\|([^>]+)>", in: text) { groups in
            "@\(groups[1])"
        }
        text = replace(pattern: "<!([a-zA-Z0-9_]+)(\\|[^>]+)?>", in: text) { groups in
            "@\(groups[1])"
        }

        // Links: <https://x|label> or <https://x> (also mailto:, tel:, etc).
        text = replace(pattern: "<([a-zA-Z][a-zA-Z0-9+.-]*:[^>|]+)\\|([^>]+)>", in: text) { groups in
            groups[2]
        }
        text = replace(pattern: "<([a-zA-Z][a-zA-Z0-9+.-]*:[^>|]+)>", in: text) { groups in
            groups[1]
        }

        // Emoji shortcodes for a common set; unknown ones are left as :name:.
        text = replaceEmoji(in: text)

        // HTML entities last, so decoded &, <, > cannot be mistaken for tokens.
        text = text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - User mentions

    private static func replaceUserMentions(
        in text: String,
        resolveUserName: (String) async -> String?
    ) async -> String {
        let pattern = "<@([UW][A-Z0-9]+)(?:\\|([^>]+))?>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        // Resolve replacements first (async), then splice back to front so
        // earlier ranges stay valid.
        var replacements: [(range: NSRange, value: String)] = []
        for match in matches {
            let userID = nsText.substring(with: match.range(at: 1))
            let labelRange = match.range(at: 2)
            let display: String
            if labelRange.location != NSNotFound {
                display = nsText.substring(with: labelRange)
            } else {
                display = await resolveUserName(userID) ?? "someone"
            }
            replacements.append((match.range, "@\(display)"))
        }

        var result = text
        for replacement in replacements.reversed() {
            let ns = result as NSString
            result = ns.replacingCharacters(in: replacement.range, with: replacement.value)
        }
        return result
    }

    // MARK: - Regex helper

    private static func replace(
        pattern: String,
        in text: String,
        transform: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            var groups: [String] = []
            for index in 0..<match.numberOfRanges {
                let range = match.range(at: index)
                groups.append(range.location == NSNotFound ? "" : nsText.substring(with: range))
            }
            let ns = result as NSString
            result = ns.replacingCharacters(in: match.range, with: transform(groups))
        }
        return result
    }

    // MARK: - Emoji

    /// Returns the unicode glyph for a single Slack shortcode (with or without
    /// the surrounding colons), or nil if it isn't in the known set. Used to
    /// render a user's status emoji.
    static func emojiGlyph(for shortcode: String) -> String? {
        let trimmed = shortcode.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        guard !trimmed.isEmpty else { return nil }
        let base = trimmed.components(separatedBy: "::").first ?? trimmed
        return emojiMap[base]
    }

    private static func replaceEmoji(in text: String) -> String {
        replace(pattern: ":([a-z0-9_+-]+):", in: text) { groups in
            let name = groups[1]
            // Slack allows a skin-tone suffix like :wave::skin-tone-3:; drop it.
            let base = name.components(separatedBy: "::").first ?? name
            return emojiMap[base] ?? groups[0]
        }
    }

    private static let emojiMap: [String: String] = [
        "pray": "\u{1F64F}", "+1": "\u{1F44D}", "thumbsup": "\u{1F44D}",
        "-1": "\u{1F44E}", "thumbsdown": "\u{1F44E}", "smile": "\u{1F604}",
        "smiley": "\u{1F603}", "grin": "\u{1F601}", "joy": "\u{1F602}",
        "rofl": "\u{1F923}", "sweat_smile": "\u{1F605}", "wink": "\u{1F609}",
        "blush": "\u{1F60A}", "slightly_smiling_face": "\u{1F642}",
        "upside_down_face": "\u{1F643}", "thinking_face": "\u{1F914}",
        "thinking": "\u{1F914}", "face_with_rolling_eyes": "\u{1F644}",
        "sunglasses": "\u{1F60E}", "sob": "\u{1F62D}", "cry": "\u{1F622}",
        "laughing": "\u{1F606}", "sweat": "\u{1F613}", "grimacing": "\u{1F62C}",
        "heart": "\u{2764}\u{FE0F}", "hearts": "\u{1F495}", "fire": "\u{1F525}",
        "tada": "\u{1F389}", "party_popper": "\u{1F389}", "rocket": "\u{1F680}",
        "eyes": "\u{1F440}", "wave": "\u{1F44B}", "clap": "\u{1F44F}",
        "raised_hands": "\u{1F64C}", "muscle": "\u{1F4AA}", "ok_hand": "\u{1F44C}",
        "100": "\u{1F4AF}", "white_check_mark": "\u{2705}",
        "heavy_check_mark": "\u{2714}\u{FE0F}", "x": "\u{274C}",
        "warning": "\u{26A0}\u{FE0F}", "bug": "\u{1F41B}", "sparkles": "\u{2728}",
        "star": "\u{2B50}", "zap": "\u{26A1}", "boom": "\u{1F4A5}",
        "bulb": "\u{1F4A1}", "rainbow": "\u{1F308}", "coffee": "\u{2615}",
        "beer": "\u{1F37A}", "pizza": "\u{1F355}", "checkered_flag": "\u{1F3C1}",
        "hourglass": "\u{23F3}", "alarm_clock": "\u{23F0}", "calendar": "\u{1F4C5}",
        "memo": "\u{1F4DD}", "pushpin": "\u{1F4CC}", "lock": "\u{1F512}",
        "key": "\u{1F511}", "mag": "\u{1F50D}", "gear": "\u{2699}\u{FE0F}",
        "hammer": "\u{1F528}", "wrench": "\u{1F527}", "package": "\u{1F4E6}",
        "robot_face": "\u{1F916}", "skull": "\u{1F480}", "poop": "\u{1F4A9}",
        "see_no_evil": "\u{1F648}", "raised_hand": "\u{270B}",
        "handshake": "\u{1F91D}", "point_up": "\u{261D}\u{FE0F}",
        "point_down": "\u{1F447}", "point_right": "\u{1F449}",
        "point_left": "\u{1F448}", "heavy_plus_sign": "\u{2795}",
        "tada_face": "\u{1F389}", "smiling_face_with_tear": "\u{1F972}",
        "headphones": "\u{1F3A7}", "knife_fork_plate": "\u{1F37D}\u{FE0F}",
        "walking": "\u{1F6B6}", "house": "\u{1F3E0}", "palm_tree": "\u{1F334}",
        "spiral_calendar_pad": "\u{1F5D3}\u{FE0F}", "no_entry": "\u{26D4}",
        "zzz": "\u{1F4A4}", "clock1": "\u{1F550}", "coffee_break": "\u{2615}",
    ]
}
