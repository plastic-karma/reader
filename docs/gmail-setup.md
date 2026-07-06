# Gmail newsletters — one-time setup

reader can pull newsletters straight out of your Gmail account: you register
rules (sender + optional subject regex) and matching messages appear as
articles, rendered offline like any feed. After a message is imported the app
archives it and marks it read in Gmail (per-rule toggle), so newsletters stop
cluttering your inbox.

There is no backend server: the app talks to the Gmail API directly with
credentials that stay on your Mac. That requires a **one-time ~10 minute
setup** — you create your *own* Google Cloud OAuth client, so you are not
trusting anyone else's.

## 1. Create a Google Cloud project

1. Open [console.cloud.google.com](https://console.cloud.google.com) and sign
   in with the Gmail account your newsletters arrive at.
2. Project picker (top bar) → **New Project** → name it anything (e.g.
   `reader-gmail`) → **Create**, and make sure it's selected.

## 2. Enable the Gmail API

**APIs & Services → Library** → search "Gmail API" → **Enable**.

## 3. Configure the OAuth consent screen

**APIs & Services → OAuth consent screen** (Google may call this *Audience*
under *Google Auth Platform*):

1. User type: **External** → Create.
2. App name (e.g. `reader`), your email for both support fields → Save.
3. Scopes: **Add or remove scopes** → filter for the Gmail API and check
   `https://www.googleapis.com/auth/gmail.modify` → Update → Save.
   (modify is what lets the app archive + mark read; it cannot delete mail
   or send it.)
4. **Publish the app to Production.** This matters: while the consent screen
   stays in *Testing*, Google expires refresh tokens after **7 days**, which
   would force you to sign in again every week. Production mode with an
   unverified app is fine for personal use — see the note below.

## 4. Create the OAuth client ID

**APIs & Services → Credentials → Create credentials → OAuth client ID**:

- Application type: **iOS** — yes, even though reader is a macOS app. The
  iOS client type is the one that is *secret-less* (PKCE serves as the
  proof) and registers the custom-scheme redirect the sign-in flow uses.
- Bundle ID: `plastic-karma.reader`
- **Create**, then copy the client ID — it looks like
  `1234567890-abcdef.apps.googleusercontent.com`.

## 5. Connect reader

1. reader → **Settings (⌘,) → Newsletters**.
2. Paste the client ID and click **Sign in with Google…**
3. Your browser session opens. Because the app is unverified, Google shows a
   **"Google hasn't verified this app"** interstitial once — click
   **Advanced → Go to reader (unsafe)**. That wording is aimed at apps
   distributed to strangers; here *you* are the developer, the client is
   yours, and the tokens never leave your Mac. Approve the requested Gmail
   permission.
4. Settings should now show "Signed in as *you@gmail.com*".

## 6. Add a rule

Main window → **＋ → Add Newsletter Rule…** (also offered when the sidebar is
empty, and existing rules are edited from their sidebar context menu):

- **Sender** — an address (`money@bloomberg.net`) or domain
  (`stratechery.com`); Gmail `from:` semantics.
- **Subject pattern** — optional, case-insensitive regex; leave empty to
  import everything from the sender. Useful when one sender mixes content
  you want with content you don't (`^Money Stuff` keeps the column, skips
  the account notices).
- **Test Against Recent Mail** shows the sender's last 30 days of subjects
  with live match marks while you tune the pattern.
- **Archive and mark read in Gmail after import** — on by default. Turn it
  off for a rule whose messages you also want to keep seeing in Gmail.

The first sync backfills the last 30 days. Each rule is its own feed in the
sidebar: unread badge, mark-all-read, j/k, delete — all the usual behavior.

## What the app does (and doesn't do) in Gmail

- It archives and marks read **only messages it has imported** — matched by
  your rule and saved as articles first, in that order, so nothing can be
  archived that the reader didn't keep. Archived mail stays in All Mail;
  nothing is ever deleted.
- Messages from a sender that don't match your subject pattern are never
  touched.
- Deleting a rule removes its articles from reader but changes nothing in
  Gmail (already-archived messages stay archived).
- Signing out revokes the app's access with Google and deletes the local
  tokens (kept in the macOS Keychain, never in the database or defaults).

**Privacy note — tracking pixels.** Newsletters embed 1×1 "open tracking"
images with per-recipient URLs. reader strips the declared-1×1 ones before
downloading images and its reading pane blocks *all* network access at render
time, so repeated opens are never observable. A pixel that hides its size in
CSS can still be fetched **once** at import time — comparable to any mail
client that loads remote images, and strictly better than most.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Sign-in required again after ~a week (`invalid_grant`) | Consent screen still in **Testing** — publish it to Production (step 3.4), then sign in again. |
| "Google didn't return a refresh token" | A previous grant already exists. Remove the app at [myaccount.google.com/permissions](https://myaccount.google.com/permissions), then sign in again. |
| "Not an iOS-type Google OAuth client ID" | The pasted ID doesn't end in `.apps.googleusercontent.com` — copy the **client ID**, not the client secret or project ID, from an **iOS-type** client. |
| Sidebar shows ⚠️ "Gmail: sign in required" | No tokens stored (first run, or after sign-out) — Settings → Newsletters → Sign in. |
| Sidebar shows ⚠️ "Gmail: session expired" | The grant was revoked or expired — sign in again from Settings. |
| A newsletter still sits in the Gmail inbox | Archiving happens at sync time (no push). It clears on the next refresh; the sidebar refresh interval is in Settings → General. |
