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
struct SlackAvatar: View {
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
            if slackManager.status.isSet || slackManager.dndState.snoozeEnabled {
                statusRow
            }
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
        HStack(spacing: 5) {
            SlackMark(size: 14)
            Text("Slack")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
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

    /// Compact readout of the current custom status and/or snooze, under the header.
    private var statusRow: some View {
        HStack(spacing: 5) {
            if slackManager.status.isSet {
                if let glyph = slackManager.statusGlyph {
                    Text(glyph).font(.system(size: 11))
                } else {
                    Image(systemName: "face.smiling.inverse")
                        .font(.system(size: 10))
                        .foregroundStyle(SlackBrand.yellow)
                }
                Text(slackManager.status.text.isEmpty ? "Status set" : slackManager.status.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if slackManager.dndState.snoozeEnabled {
                Image(systemName: "moon.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(SlackBrand.yellow)
                Text(dndRemainingText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else if let ends = slackManager.status.expiresAt {
                Text("· \(Self.relativeTime(until: ends))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var quickActions: some View {
        HStack(spacing: 10) {
            Menu {
                Section("Pause notifications") {
                    Button("For 30 minutes") { Task { await slackManager.snooze(minutes: 30) } }
                    Button("For 1 hour") { Task { await slackManager.snooze(minutes: 60) } }
                    Button("For 2 hours") { Task { await slackManager.snooze(minutes: 120) } }
                    Button("Until tomorrow") { Task { await slackManager.snooze(minutes: minutesUntilTomorrow9am()) } }
                }
                if slackManager.dndState.snoozeEnabled {
                    Divider()
                    Button("Resume notifications") { Task { await slackManager.endSnooze() } }
                }
            } label: {
                Image(systemName: slackManager.dndState.snoozeEnabled ? "moon.fill" : "moon")
                    .font(.system(size: 13))
                    .foregroundStyle(slackManager.dndState.snoozeEnabled ? SlackBrand.yellow : .secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(slackManager.dndState.snoozeEnabled ? "Do Not Disturb on · \(dndRemainingText)" : "Pause notifications")

            Menu {
                Section("Set a status") {
                    Button("🍽  Lunch · 30 min") {
                        Task { await slackManager.setStatus(text: "Lunch", emoji: ":knife_fork_plate:", expiresIn: 30) }
                    }
                    Button("🎧  Focusing · 1 hour") {
                        Task { await slackManager.setStatus(text: "Focusing", emoji: ":headphones:", expiresIn: 60) }
                    }
                    Button("🚶  Stepped away · 15 min") {
                        Task { await slackManager.setStatus(text: "Stepped away", emoji: ":walking:", expiresIn: 15) }
                    }
                    Button("🏠  Working remotely · today") {
                        Task { await slackManager.setStatus(text: "Working remotely", emoji: ":house:", expiresIn: minutesUntilTomorrow9am()) }
                    }
                    Button("📅  In a meeting · 1 hour") {
                        Task { await slackManager.setStatus(text: "In a meeting", emoji: ":spiral_calendar_pad:", expiresIn: 60) }
                    }
                }
                if slackManager.status.isSet {
                    Divider()
                    Button("Clear status") { Task { await slackManager.clearStatus() } }
                }
            } label: {
                Image(systemName: slackManager.status.isSet ? "face.smiling.inverse" : "face.smiling")
                    .font(.system(size: 13))
                    .foregroundStyle(slackManager.status.isSet ? SlackBrand.yellow : .secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Set status")
        }
    }

    private var dndRemainingText: String {
        guard let ends = slackManager.dndState.snoozeEndsAt else { return "on" }
        return Self.relativeTime(until: ends)
    }

    /// Minutes from now until 9am tomorrow, for "until tomorrow" style actions.
    private func minutesUntilTomorrow9am() -> Int {
        let calendar = Calendar.current
        let now = Date()
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
              let nine = calendar.date(
                bySettingHour: 9, minute: 0, second: 0, of: tomorrow
              ) else { return 720 }
        return max(30, Int(nine.timeIntervalSince(now) / 60))
    }

    /// Short "1h 20m" / "45m left"-style label until a future date.
    static func relativeTime(until date: Date) -> String {
        let seconds = Int(date.timeIntervalSinceNow)
        guard seconds > 0 else { return "ending" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m left" }
        return "\(max(1, minutes))m left"
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
                        Button {
                            slackManager.openDM(dm)
                        } label: {
                            HStack(spacing: 6) {
                                SlackAvatar(name: dm.name, isGroup: dm.isGroup, avatarURL: dm.avatarURL, size: 18)
                                Text(dm.name)
                                    .font(.caption2)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 4)
                                Text("\(dm.unreadCount)")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(SlackBrand.red))
                                    .foregroundStyle(.white)
                                    .layoutPriority(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !slackManager.mentions.isEmpty {
                    sectionHeader("Mentions")
                    ForEach(slackManager.mentions.prefix(4)) { mention in
                        Button {
                            slackManager.openMention(mention)
                        } label: {
                            HStack(alignment: .top, spacing: 6) {
                                SlackAvatar(name: mention.userName, avatarURL: mention.avatarURL, size: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 3) {
                                        Text(mention.userName)
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        Text("#\(mention.channelName)")
                                            .font(.system(size: 10))
                                            .foregroundStyle(SlackBrand.blue)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                    Text(mention.text)
                                        .font(.system(size: 10))
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
