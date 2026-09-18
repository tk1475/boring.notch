//
//  SlackSettings.swift
//  boringNotch
//
//  Settings pane for the Slack integration. Token setup instructions and
//  the Slack app manifest live in docs/slack/README.md.
//

import Defaults
import SwiftUI

struct SlackSettings: View {
    @ObservedObject private var slackManager = SlackManager.shared
    @Default(.enableSlackIntegration) var enableSlackIntegration
    @Default(.showSlackPanel) var showSlackPanel
    @Default(.slackShowBanners) var slackShowBanners
    @Default(.slackHuddleDetection) var slackHuddleDetection
    @Default(.slackPollIntervalSeconds) var slackPollIntervalSeconds

    @State private var tokenInput: String = ""

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .enableSlackIntegration) {
                    Text("Enable Slack integration")
                }
                .onChange(of: enableSlackIntegration) { _, enabled in
                    if enabled { slackManager.start() } else { slackManager.stop() }
                }
            } header: {
                Text("Slack")
            } footer: {
                Text("Create a personal Slack app from the manifest in docs/slack/README.md, install it to your workspace, and paste its user OAuth token (xoxp-…) below. The token is stored in the macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(header: Text("Account")) {
                connectionRow

                SecureField("User OAuth token (xoxp-…)", text: $tokenInput)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Save token") {
                        slackManager.setToken(tokenInput)
                        tokenInput = ""
                    }
                    .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if slackManager.hasToken {
                        Button("Remove token", role: .destructive) {
                            slackManager.clearToken()
                        }
                    }
                }
            }

            Section(header: Text("Appearance")) {
                Defaults.Toggle(key: .showSlackPanel) {
                    Text("Show Slack panel in the notch")
                }
                Defaults.Toggle(key: .slackShowBanners) {
                    Text("Show a banner for new mentions and DMs")
                }
                Defaults.Toggle(key: .slackHuddleDetection) {
                    Text("Detect huddles (via Slack's microphone use)")
                }
            }

            Section(header: Text("Polling")) {
                Picker("Refresh every", selection: $slackPollIntervalSeconds) {
                    Text("15 seconds").tag(15.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                }
            }
        }
    }

    private var connectionRow: some View {
        HStack(spacing: 6) {
            switch slackManager.connectionState {
            case .connected(let identity):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Connected as \(identity.userName) (\(identity.teamName))")
            case .connecting:
                ProgressView().controlSize(.small)
                Text("Connecting…")
            case .disconnected:
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                Text("Not connected")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(message).lineLimit(2)
            }
        }
        .font(.callout)
    }
}
