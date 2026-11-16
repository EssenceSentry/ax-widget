# AX Widget

A native Mac companion for [ax](https://github.com/EssenceSentry/agent-skills).
Keep Claude and Codex allowance visible in two tiny floating rings. Click to
expand recent conversations, their latest agent-written update, and task progress.
Click a conversation title to open that exact chat in its native desktop app.

**Carbon**, **Porcelain**, and **Frost** share the same layout. System appearance
is the default; choose a theme from the menu-bar icon's **Appearance** submenu.
Frost uses native Liquid Glass on macOS 26 and newer, and the standard system
popover material on older versions. Its text colors and light/dark appearance
follow macOS, with no custom blue background tint or simulated glass border.
Reduce Transparency uses an opaque system background. The small system widget
uses the native widget material. Both the floating interface and a small native Notification Center widget
are included. There is no brand/count header and no built-in chat editor.

## Floating mode

- Codex has one remaining-allowance ring. Claude's inner ring shows five-hour
  allowance and the outer ring shows weekly allowance.
- Hover for percentage remaining, reset time, and observation age.
- Click the menu-bar icon or the small system widget to open the expanded panel.
  Right-click the menu-bar icon for options. **Keep floating** is off by default:
  closing the panel hides both windows. Enable it to keep the tiny usage pill
  visible while closed; explicit existing preferences are preserved. Its pin
  control sits immediately to the left of the new-conversation buttons.
- Drag the icon pair to position it. Its conversation panel opens just below it,
  with a small gap. Dragging moves the pair together. Click outside or press
  Escape to close, or click the menu-bar icon again. The position is remembered
  and constrained to the screen.
- Conversations are sorted by most recent activity, limited to the last 12 hours.
  Pinned conversations remain first, in pin order, even after 12 hours.
- The expanded panel shows the latest original agent prose, not tool logs or an
  invented summary. **More** appears only when the rendered preview actually
  clips content, and expands the text in place. The panel grows and shrinks
  with its content; scrolling begins only at the available screen height.
- Updates render native Markdown: bold, italics, links, headings, lists, code
  blocks, and wrapping tables. Internal memory-citation markup is hidden.
- Rendered prose uses regular text with medium-weight emphasis, headings, and table
  headers. Permanent titles, labels, controls, and usage figures retain their weight.
- Numeric progress comes from ax tasks. Reaching a task total does not imply
  that the conversation is complete.
- Each conversation has a separate numbered badge for its active ax jobs, even
  while a numeric progress counter is visible. If any active job has numeric
  progress, the most recent such counter stays visible alongside the total job count.
- **New Codex** and **New Claude** open a native new-chat composer using the most
  recent working folder for that provider. Opening the composer sends no prompt.
- A blue provider dot marks a pending question, in the floating pill and the
  small system widget. The expanded panel shows one question at a time, with
  previous/next arrows and a position counter. Choices and typed drafts are kept
  while navigating. A text field is included where allowed. **Send answer**
  submits the selected response to that same
  conversation; its pending indicator clears when the native transcript records it.
  When an agent asks several questions together, fill them in and use **Send answers**.
  Clicking the text field clears the selected choices. The send button appears
  only once the required answers have a selection or nonempty text.
- Claude inline answers require macOS Accessibility permission, because the
  installed client handles question submission inside its renderer. AX Widget
  matches the original question and submit control; ambiguous forms stay unanswered.
  Without this permission, **Open Claude** remains available.
  Choose **Enable window control and Claude replies…** from the menu-bar menu or the question form
  to request access, then enable **AX Widget** in macOS Accessibility settings.
  Background refresh never requests permission. Answers submitted in Claude
  clear from the widget when its native tool-result record is saved.
- Idle Codex keeps its last observed allowance until that allowance resets.
  After five minutes without a fresh observation, a small clock and a dimmer
  continuous ring mark the cached reading; hover for its age and reset time.
  Freshness validation remains separate from this display cache.
- Unknown, unavailable, expired, and stale Claude usage shows a neutral track and an em dash.
- All rings use continuous strokes. The supplied OpenAI and Claude SVG marks stay
  vector artwork; OpenAI adapts to the selected appearance.
- The menu-bar icon is a pure-white axe silhouette. Right-click it to control Keep floating,
  appearance, refresh, and quit.

## Conversation window group

Pin up to three conversations using the pin beside each title. Each pin opens
that exact conversation in its own native Claude or Codex window and arranges the
group side by side on the widget's display. Claude uses its compact, sidebar-free
conversation pop-outs. Codex uses separate native windows with the conversation
sidebar collapsed (its slim navigation rail remains). The separate toolbar pin still means
**Keep floating**; it does not pin a conversation.

- **Show group** (overlapping rectangles) restores and raises all pinned windows
  with one click. It is available in the expanded panel, the floating pill when
  enabled, and the menu-bar menu. Switch to Slack or any other app normally;
  click Show group when you want all the conversations back.
- **Minimize group** minimizes only the pinned windows. Other windows belonging
  to Claude and Codex are left alone.
- **Arrange side by side** is in the group button's context menu and menu-bar
  menu. Normal Show group preserves any positions and sizes you adjust manually.
  Pin changes arrange the group again. If the apps' minimum window sizes do not
  fit, the previous frames are restored and the panel explains the problem.
  Layout adapts to different native minimum widths instead of assuming equal minima.
- Unpinning leaves the conversation open and removes it from group control.
  Pin references survive widget restarts; restoring them never launches provider
  apps until you request Show group. No chat contents are stored in preferences.

These are ordinary app windows, without an always-on-top level. Group control
requires macOS Accessibility access for AX Widget. It uses native conversation
navigation and Open in New Window actions; it sends no prompts, creates no
conversations, and does not interrupt running agents. Ambiguous or unavailable
window targets produce an error rather than selecting another conversation.
Claude's main window exposes its session URL; its compact pop-outs expose a native
title and return-to-main-window control. Codex also exposes a native title. AX Widget
checks titles against the corresponding provider's local registration/history and
accepts only unique matches; duplicate titles must be renamed before pinning.
Use ordinary desktop windows on one display; leave full screen before arranging.

## Notification Center and desktop widget

The app contains one small WidgetKit usage widget: two provider icons, continuous
remaining-allowance rings, and compact percentages. Claude's five-hour percentage
uses the inner-ring color; its weekly percentage uses the outer-ring color.
There are no repeated provider names or reset-time rows. Hover a ring for details.
After launching the installed app, open Notification Center, choose Edit Widgets,
and search for **AX Widget**. The same widget can be placed on the desktop.
Conversation updates live in the floating panel; there is no large system widget.
Floating mode can be hidden independently.

The floating and menu-bar indicators update with the local reader. Pending-question
changes request an immediate system-widget reload; macOS still controls when a
Notification Center widget renders the new snapshot.

Claude and Codex can both be closed while AX Widget runs. It reads their saved
local histories and keeps the last available updates; clicking a conversation or
new-chat action launches its provider app. It never launches an agent just to
refresh a view. Idle Codex readings remain visible as cached until their recorded
reset. Expired or unavailable allowances stay unknown.

The widget reads a private snapshot written by the app; keep the app running for
new data. macOS controls its refresh timing, so it is a glanceable snapshot.
Hover for reset and observation details. Click the usage widget to open the floating
conversation panel. Conversation titles there open their exact provider chat;
they never submit a prompt.

The local-development extension has a narrow read-only sandbox exception for
`~/Library/Application Support/ax-widget/`. It cannot read provider histories or
modify ax state. An App Store distribution would replace this development bridge
with a provisioned App Group. No Apple signing identity or notarization is claimed.

## Build

Runs on macOS 14+. Building requires the macOS 26 SDK (Xcode 26 or newer),
Swift 6+, and installed ax for usage snapshots. Full system widgets require
Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
swift test --jobs 2
scripts/build.sh
scripts/install.sh
```

With Command Line Tools alone the build script produces the floating app.
With full Xcode and XcodeGen it builds and embeds the real widget extension.
The macOS CI workflow builds both and uploads an ad-hoc-signed app ZIP. This is a
local developer build, not a notarized public release.

For local development, a persistent **AX Widget Local Signing** certificate in
the login Keychain lets successive builds keep the same signing identity.
`scripts/setup-local-signing.py` prints the proposed Keychain changes without
making them; `--install` creates the identity after explicit approval. The
certificate is trusted only for code signing on this Mac, with no Apple account
or cloud copy of its private key. Builds and installations automatically reuse
it; `AX_WIDGET_SIGNING_IDENTITY` can select another identity. CI uses ad-hoc
signing. Moving from ad-hoc signing to the certificate requires a fresh
Accessibility grant; later updates retain the same designated requirement.

For design inspection without live histories:

```sh
swift run AXWidget --demo --expanded
swift run AXWidgetRender build/previews
```

Demo mode is labeled, never opens synthetic conversations, and never overwrites
the live widget snapshot. The renderer produces native SwiftUI previews of all three
appearances in the floating and small-widget layouts, plus a Markdown sample;
these are not evidence of system-widget hosting.

## Local data

The app reads ax's conversation catalog and queries running tasks through its
local daemon socket, supplements titles
and registration from the native local clients, and reads a bounded recent tail
of relevant transcripts for prose. Question cursors start at the latest Codex
turn, discard prompts from earlier or interrupted turns, and retain pending
questions through lengthy tool output within that turn. Existing conversation
files are watched for changes, coalesced over 200 milliseconds, with a four-second
discovery/fallback poll. Usage comes from `ax usage` once per minute, without
`--refresh`, on a separate queue so allowance reads cannot delay questions.
Reads are performed off the main thread. Shared snapshots have owner-only permissions.

Claude conversations need an existing Desktop registration. If one is absent,
the app explains that ax registers eligible sessions while Claude Desktop is
fully quit. No new conversation or paid continuation is created as a fallback.

Background refresh makes no model calls and sends no messages. Opening a native
new-chat composer is not a model turn. Sending an answer is an explicit user
action and can resume that conversation. The widget creates no ax tasks or alarms,
and has no notification service, HTTP server, Cloudflare, or analytics.
The approved concept images in [docs/design](docs/design) are illustrative design
references, not screenshots of shipped behavior. Provider names and icons belong
to their respective owners; this is an independent local companion.
