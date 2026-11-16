# AX Widget

A native Mac companion for [ax](https://github.com/EssenceSentry/agent-skills).
Keep Claude and Codex allowance visible in two tiny floating rings. Click to
expand recent conversations, their latest agent-written update, and task progress.
Click a conversation title to open that exact chat in its native desktop app.

**Carbon** and **Porcelain** share the same layout and follow system appearance
by default. Both the floating interface and a small native Notification Center widget
are included. There is no brand/count header and no built-in chat editor.

## Floating mode

- Codex has one remaining-allowance ring. Claude's inner ring shows five-hour
  allowance and the outer ring shows weekly allowance.
- Hover for percentage remaining, reset time, and observation age.
- Click the menu-bar icon or the small system widget to open the expanded panel.
  Right-click the menu-bar icon for options. **Keep floating** is off by default:
  closing the panel hides both windows. Enable it to keep the tiny usage pill
  visible while closed; explicit existing preferences are preserved.
- Drag the icon pair to position it. Its conversation panel opens just below it,
  with a small gap. Dragging moves the pair together. Click outside or press
  Escape to close, or click the menu-bar icon again. The position is remembered
  and constrained to the screen.
- Conversations are sorted by most recent activity, limited to the last 12 hours.
- The expanded panel shows the latest original agent prose, not tool logs or an
  invented summary. More expands the text in place. The panel grows and shrinks
  with its content; scrolling begins only at the available screen height.
- Updates render native Markdown: bold, italics, links, headings, lists, code
  blocks, and wrapping tables. Internal memory-citation markup is hidden.
- Rendered prose uses regular text with medium-weight emphasis, headings, and table
  headers. Permanent titles, labels, controls, and usage figures retain their weight.
- Numeric progress comes from ax tasks. Reaching a task total does not imply
  that the conversation is complete.
- Each conversation has a separate numbered badge for its active ax jobs, even
  while a numeric progress counter is visible.
- **New Codex** and **New Claude** open a native new-chat composer using the most
  recent working folder for that provider. Opening the composer sends no prompt.
- An orange provider dot marks a pending question, in the floating pill and the
  small system widget; the menu-bar **ax** label also turns orange. The expanded panel shows the original choices and a text
  field where allowed. **Send answer** submits the selected response to that same
  conversation; its pending indicator clears when the native transcript records it.
- Claude inline answers require macOS Accessibility permission, because the
  installed client handles question submission inside its renderer. AX Widget
  matches the original question and submit control; ambiguous forms stay unanswered.
  Without this permission, **Open Claude** remains available.
- Unknown, stale, or expired usage shows a neutral continuous track and an em dash.
- All rings use continuous strokes. The supplied OpenAI and Claude SVG marks stay
  vector artwork; OpenAI adapts to the selected appearance.
- The menu-bar icon reads **ax**. Right-click it to control Keep floating,
  appearance, refresh, and quit.

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
refresh a view. Usage that is no longer fresh stays unknown.

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

Requires macOS 14+, Swift 6+, and installed ax for usage snapshots. Full system
widgets require Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
swift test --jobs 2
scripts/build.sh
scripts/install.sh
```

With Command Line Tools alone the build script produces the floating app.
With full Xcode and XcodeGen it builds and embeds the real widget extension.
The macOS CI workflow builds both and uploads an ad-hoc-signed app ZIP. This is a
local developer build, not a notarized public release.

For design inspection without live histories:

```sh
swift run AXWidget --demo --expanded
swift run AXWidgetRender build/previews
```

Demo mode is labeled, never opens synthetic conversations, and never overwrites
the live widget snapshot. The renderer produces native SwiftUI previews of both
appearances in the floating and small-widget layouts, plus a Markdown sample;
these are not evidence of system-widget hosting.

## Local data

The app reads ax's conversation catalog and queries running tasks through its
local daemon socket, supplements titles
and registration from the native local clients, and reads a bounded recent tail
of relevant transcripts. Usage comes from `ax usage` once per minute, without
`--refresh`. Conversation updates poll every four seconds; reads are performed
off the main thread. Shared snapshots have owner-only permissions.

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
