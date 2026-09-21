//
//  SlackView.swift
//  boringNotch
//
//  Slack panel for the open notch: unread DMs, recent mentions, and
//  status/DND quick actions. Styled to echo Slack's own UI (brand palette,
//  the four-colour hashtag mark, avatar tiles, #channel mentions).
//

import Defaults
import SwiftUI

// MARK: - Brand

enum SlackBrand {
    static let aubergine = Color(.sRGB, red: 0.290, green: 0.082, blue: 0.294) // #4A154B
    static let blue = Color(.sRGB, red: 0.212, green: 0.773, blue: 0.941)      // #36C5F0
    static let green = Color(.sRGB, red: 0.180, green: 0.714, blue: 0.490)     // #2EB67D
    static let red = Color(.sRGB, red: 0.878, green: 0.118, blue: 0.353)       // #E01E5A
    static let yellow = Color(.sRGB, red: 0.925, green: 0.698, blue: 0.180)    // #ECB22E

    /// Deterministic brand colour for an avatar tile, from a seed string.
    static func avatarColor(for seed: String) -> Color {
        let palette = [blue, green, red, yellow, aubergine]
        var hash = 5381
        for byte in seed.utf8 { hash = ((hash << 5) &+ hash) &+ Int(byte) }
        return palette[abs(hash) % palette.count]
    }
}

/// The official Slack logo mark (bundled SVG asset, scales at any size).
struct SlackMark: View {
    var size: CGFloat = 16

    var body: some View {
        Image("SlackLogo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}

/// Square avatar tile, Slack-style rounded corners. Shows the user's real
/// profile picture when available, falling back to an initial/group glyph.
private struct SlackAvatar: View {
    let name: String
    var isGroup: Bool = false
    var avatarURL: URL? = nil
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let avatarURL, !isGroup {
                AsyncImage(url: avatarURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(SlackBrand.avatarColor(for: name))
            .overlay {
                if isGroup {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: size * 0.5))
                        .foregroundStyle(.white)
                } else {
                    Text(initial)
                        .font(.system(size: size * 0.55, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
    }

    private var initial: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return String(trimmed.first ?? "?").uppercased()
    }
}

// MARK: - Panel

struct SlackView: View {
    @ObservedObject private var slackManager = SlackManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            switch slackManager.connectionState {
            case .connected:
                content
            case .connecting:
                Label("Connecting to Slack…", systemImage: "ellipsis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .disconnected:
                Text("Add Slack credentials in Settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(SlackBrand.red)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            SlackMark(size: 15)
            Text("Slack")
                .font(.headline)
                .foregroundStyle(.white)
            if slackManager.totalUnreadDMs > 0 {
                Text("\(slackManager.totalUnreadDMs)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(SlackBrand.red))
                    .foregroundStyle(.white)
            }
            if slackManager.isInHuddle {
                Image(systemName: "headphones")
                    .font(.caption)
                    .foregroundStyle(SlackBrand.green)
                    .help("In a huddle")
            }
            Spacer()
            quickActions
        }
    }

    private var quickActions: some View {
        HStack(spacing: 8) {
            Menu {
                Button("30 minutes") { Task { await slackManager.snooze(minutes: 30) } }
                Button("1 hour") { Task { await slackManager.snooze(minutes: 60) } }
                Button("2 hours") { Task { await slackManager.snooze(minutes: 120) } }
                if slackManager.dndState.snoozeEnabled {
                    Divider()
                    Button("Turn off") { Task { await slackManager.endSnooze() } }
                }
            } label: {
                Image(systemName: slackManager.dndState.snoozeEnabled ? "moon.fill" : "moon")
                    .foregroundStyle(slackManager.dndState.snoozeEnabled ? SlackBrand.yellow : .secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Do Not Disturb")

            Menu {
                Button("🍽️ Lunch (30 min)") {
                    Task { await slackManager.setStatus(text: "Lunch", emoji: ":knife_fork_plate:", expiresIn: 30) }
                }
                Button("🎧 Focus (1 h)") {
                    Task { await slackManager.setStatus(text: "Focusing", emoji: ":headphones:", expiresIn: 60) }
                }
                Button("🚶 Away (15 min)") {
                    Task { await slackManager.setStatus(text: "Stepped away", emoji: ":walking:", expiresIn: 15) }
                }
                Divider()
                Button("Clear status") { Task { await slackManager.clearStatus() } }
            } label: {
                Image(systemName: "face.smiling")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Set status")
        }
    }

    private var content: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                if slackManager.dmSummaries.isEmpty && slackManager.mentions.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(SlackBrand.green)
                        Text("You're all caught up")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }

                if !slackManager.dmSummaries.isEmpty {
                    sectionHeader("Direct messages")
                    ForEach(slackManager.dmSummaries) { dm in
                        HStack(spacing: 8) {
                            SlackAvatar(name: dm.name, isGroup: dm.isGroup, avatarURL: dm.avatarURL)
                            Text(dm.name)
                                .font(.caption)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Spacer()
                            Text("\(dm.unreadCount)")
                                .font(.caption2.bold())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(SlackBrand.red))
                                .foregroundStyle(.white)
                        }
                    }
                }

                if !slackManager.mentions.isEmpty {
                    sectionHeader("Mentions")
                    ForEach(slackManager.mentions.prefix(5)) { mention in
                        Button {
                            if let permalink = mention.permalink {
                                NSWorkspace.shared.open(permalink)
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                SlackAvatar(name: mention.userName, avatarURL: mention.avatarURL)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(mention.userName)
                                            .font(.caption2.bold())
                                            .foregroundStyle(.white)
                                        Text("#\(mention.channelName)")
                                            .font(.caption2)
                                            .foregroundStyle(SlackBrand.blue)
                                    }
                                    Text(mention.text)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }
}
