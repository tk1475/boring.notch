# Slack integration setup

The Slack integration polls the Slack Web API with a **personal user token** —
no shared OAuth app, no server. Each user creates their own Slack app once
(2 minutes) and pastes the token into Boring Notch's settings, where it is
stored in the macOS Keychain.

## Create your personal Slack app

1. Go to <https://api.slack.com/apps> → **Create New App** → **From an app manifest**.
2. Pick your workspace, then paste the contents of [`app-manifest.yml`](./app-manifest.yml).
3. Create the app, then open **Install App** in the sidebar and click
   **Install to Workspace** (some workspaces require admin approval here).
4. Copy the **User OAuth Token** (starts with `xoxp-`).
5. In Boring Notch: **Settings → Slack**, enable the integration, paste the
   token, and click **Save token**.

## What each feature uses

| Feature | Slack API | Scope |
|---|---|---|
| Unread DM badge | `conversations.list` + `conversations.info` | `im:read`, `mpim:read` |
| DM sender names | `users.info` | `users:read` |
| Mentions feed | `search.messages` | `search:read` |
| Set status | `users.profile.set` | `users.profile:write` |
| Do Not Disturb | `dnd.setSnooze` / `dnd.endSnooze` / `dnd.info` | `dnd:write`, `dnd:read` |
| Huddle indicator | none — detected locally via CoreAudio (is Slack capturing the mic) | — |

Notes:
- Polling respects Slack rate limits (backs off on HTTP 429 `Retry-After`).
- `search.messages` only sees messages in channels you are in; on free plans
  it is limited to the last 90 days of history.
- The token grants access as **you** — treat it like a password. Remove it any
  time with **Remove token** (deletes it from the Keychain).
