//
//  SlackView.swift
//  boringNotch
//
//  Slack panel for the open notch: unread DMs, recent mentions, and
//  status/DND quick actions. Shown next to the music player like CalendarView.
//

import Defaults
import SwiftUI

struct SlackView: View {
    @ObservedObject private var slackManager = SlackManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            switch slackManager.connectionState {
            case .connected:
                content
            case .connecting:
                Text("Connecting to Slack…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .disconnected:
                Text("Add a Slack token in Settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "number.square.fill")
                .foregroundStyle(.white, .purple)
            Text("Slack")
                .font(.headline)
            if slackManager.totalUnreadDMs > 0 {
                Text("\(slackManager.totalUnreadDMs)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.red))
                    .foregroundStyle(.white)
            }
            if slackManager.isInHuddle {
                Image(systemName: "headphones")
                    .foregroundStyle(.green)
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
                    .foregroundStyle(slackManager.dndState.snoozeEnabled ? .purple : .secondary)
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
            VStack(alignment: .leading, spacing: 4) {
                if slackManager.dmSummaries.isEmpty && slackManager.mentions.isEmpty {
                    Text("All caught up 🎉")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(slackManager.dmSummaries) { dm in
                    HStack(spacing: 6) {
                        Image(systemName: dm.isGroup ? "person.2.fill" : "person.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(dm.name)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Text("\(dm.unreadCount)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 4)
                            .background(Capsule().fill(.red.opacity(0.8)))
                            .foregroundStyle(.white)
                    }
                }

                ForEach(slackManager.mentions.prefix(5)) { mention in
                    Button {
                        if let permalink = mention.permalink {
                            NSWorkspace.shared.open(permalink)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("@\(mention.userName) · #\(mention.channelName)")
                                .font(.caption2.bold())
                                .foregroundStyle(.purple)
                            Text(mention.text)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
