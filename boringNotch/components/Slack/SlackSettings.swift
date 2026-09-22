//
//  SlackSettings.swift
//  boringNotch
//
//  Settings pane for the Slack integration. Supports two auth modes:
//  a personal Slack app token (xoxp) or a browser session token (xoxc + xoxd).
//  Setup for both lives in docs/slack/README.md.
//

import Defaults
import SwiftUI

struct SlackSettings: View {
    @ObservedObject private var slackManager = SlackManager.shared
    @Default(.enableSlackIntegration) var enableSlackIntegration
    @Default(.slackAuthMode) var slackAuthMode
    @Default(.showSlackPanel) var showSlackPanel
    @Default(.slackShowBanners) var slackShowBanners
    @Default(.slackHuddleDetection) var slackHuddleDetection
    @Default(.slackPollIntervalSeconds) var slackPollIntervalSeconds

    @State private var appTokenInput: String = ""
    @State private var sessionTokenInput: String = ""
    @State private var sessionCookieInput: String = ""

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
                Text("See docs/slack/README.md for full setup. Secrets are stored in the macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(header: Text("Account")) {
                connectionRow
                Picker("Sign in with", selection: $slackAuthMode) {
                    Text("Slack app token").tag(SlackAuthMode.app)
                    Text("Browser session (advanced)").tag(SlackAuthMode.session)
                }
                .pickerStyle(.segmented)
            }

            switch slackAuthMode {
            case .app:
                appTokenSection
            case .session:
                sessionSection
            }

            Section(header: Text("Appearance")) {
                Defaults.Toggle(key: .showSlackPanel) {
                    Text("Show Slack panel in the notch")
                }
                Defaults.Toggle(key: .slackShowBanners) {
                    Text("Show a banner for new mentions and DMs")
                }
                Defaults.Toggle(key: .slackNotifyDMs) {
                    Text("Notify in the notch for new direct messages")
                }
                .disabled(!slackShowBanners)
                Defaults.Toggle(key: .slackShowStatusOnNotch) {
                    Text("Keep my status showing on the notch")
                }
                Defaults.Toggle(key: .slackHuddleDetection) {
                    Text("Detect huddles (via Slack's microphone use)")
                }
                Button("Preview notification") {
                    slackManager.previewBanner()
                }
                .disabled(!slackShowBanners)
            }

            Section {
                Picker("Refresh every", selection: $slackPollIntervalSeconds) {
                    Text("5 seconds").tag(5.0)
                    Text("15 seconds").tag(15.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                }
            } header: {
                Text("Polling")
            } footer: {
                Text("Faster refresh means quicker notifications but more requests. 5 seconds is fine for a single workspace; back off if Slack rate-limits you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if slackManager.hasCredentials {
                Section {
                    Button("Remove Slack credentials", role: .destructive) {
                        slackManager.clearCredentials()
                        appTokenInput = ""
                        sessionTokenInput = ""
                        sessionCookieInput = ""
                    }
                }
            }
        }
    }

    private var appTokenSection: some View {
        Section {
            SecureField("User OAuth token (xoxp-…)", text: $appTokenInput)
                .textFieldStyle(.roundedBorder)
            Button("Save token") {
                slackManager.setAppToken(appTokenInput)
                appTokenInput = ""
            }
            .disabled(appTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            Text("Slack app token")
        } footer: {
            Text("Create a personal Slack app from docs/slack/app-manifest.yml, install it to a workspace you can install apps in, and paste its User OAuth Token.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sessionSection: some View {
        Section {
            SecureField("Workspace token (xoxc-…)", text: $sessionTokenInput)
                .textFieldStyle(.roundedBorder)
            SecureField("Cookie value (xoxd-…)", text: $sessionCookieInput)
                .textFieldStyle(.roundedBorder)
            Button("Save session") {
                slackManager.setSessionCredentials(
                    token: sessionTokenInput,
                    cookie: sessionCookieInput
                )
                sessionTokenInput = ""
                sessionCookieInput = ""
            }
            .disabled(
                sessionTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || sessionCookieInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        } header: {
            Text("Browser session")
        } footer: {
            Text("No app install required. In a browser signed in to Slack, open DevTools: copy the `d` cookie value (xoxd-…) and the workspace token (xoxc-…) from Local Storage. Session tokens rotate, so you may need to re-paste them occasionally. See docs/slack/README.md.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
