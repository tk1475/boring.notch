# Slack integration setup

The Slack integration polls the Slack Web API for unread DMs, mentions, and
DND state, and detects huddles locally. There are two ways to authenticate —
pick one in **Settings → Slack → Sign in with**. Whichever you use, secrets are
stored in the macOS Keychain, never in preferences.

## Option A — Slack app token (recommended)

Stable and sanctioned. Requires being able to install an app in the target
workspace (some workspaces gate this behind admin approval).

1. Go to <https://api.slack.com/apps> → **Create New App** → **From an app manifest**.
2. Pick your workspace, paste [`app-manifest.yml`](./app-manifest.yml), create the app.
3. Open **Install App** → **Install to Workspace** (approve, or "Request to Install").
4. Copy the **User OAuth Token** (`xoxp-…`).
5. In Boring Notch: **Settings → Slack**, choose **Slack app token**, paste, **Save token**.

## Option B — Browser session (advanced, no app install)

Uses the token and cookie your browser already holds for Slack. No app, no
scopes, no admin approval — but the credentials **rotate periodically**, so
you'll re-paste them from time to time, and this speaks Slack's internal client
API rather than the public app API.

> Note: use this against a workspace where it's appropriate for you to do so.
> Some organizations disable app installs deliberately; session tokens bypass
> that control.

1. Open <https://app.slack.com> in a browser and sign in.
2. Open DevTools (⌥⌘I on macOS).
3. **Cookie (`xoxd-…`)**: **Application → Cookies → https://app.slack.com** →
   the cookie named **`d`** → copy its value (starts with `xoxd-`).
4. **Token (`xoxc-…`)**: in the **Console**, run:
   ```js
   JSON.parse(localStorage.localConfig_v2).teams[
     document.location.pathname.match(/^\/client\/(T[A-Z0-9]+)/)?.[1]
       ?? Object.keys(JSON.parse(localStorage.localConfig_v2).teams)[0]
   ].token
   ```
   Copy the `xoxc-…` string it prints.
5. In Boring Notch: **Settings → Slack**, choose **Browser session**, paste both
   values, **Save session**.

## What each feature uses

| Feature | Slack API | App-token scope |
|---|---|---|
| Unread DM badge | `conversations.list` + `conversations.info` | `im:read`, `mpim:read` |
| DM sender names | `users.info` | `users:read` |
| Mentions feed | `search.messages` | `search:read` |
| Set status | `users.profile.set` | `users.profile:write` |
| Do Not Disturb | `dnd.setSnooze` / `dnd.endSnooze` / `dnd.info` | `dnd:write`, `dnd:read` |
| Huddle indicator | none — detected locally via CoreAudio (is Slack capturing the mic) | — |

Notes:
- Polling respects Slack rate limits (backs off on HTTP 429 `Retry-After`).
- `search.messages` only sees messages in channels you're in; on free plans it
  is limited to the last 90 days.
- Either credential acts as **you** — treat it like a password. Remove it any
  time with **Remove Slack credentials** (deletes it from the Keychain).
