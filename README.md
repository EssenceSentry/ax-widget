# AX Widget

A native Mac companion for [ax](https://github.com/EssenceSentry/agent-skills).
Keep Claude and Codex allowance visible in two tiny floating rings. Click to
expand recent conversations, their latest agent-written update, and task progress.
Click a conversation title to open that exact chat in its native desktop app.

**Carbon** and **Porcelain** share the same layout and follow system appearance
by default. Both the floating interface and native Notification Center widgets
are included. There is no brand/count header and no built-in chat editor.

## Floating mode

- Codex has one remaining-allowance ring. Claude's inner ring shows five-hour
  allowance and the outer ring shows weekly allowance.
- Hover for percentage remaining, reset time, and observation age.
- Drag the icon pair to position it. Click to expand; click outside or press
  Escape to collapse. The position is remembered and constrained to the screen.
- The same icon pair and usage rings stay visible at the top when expanded.
- The expanded panel shows the latest original agent prose, not tool logs or an
  invented summary. More expands the text in place. The panel grows and shrinks
  with its content; scrolling begins only at the available screen height.
- Updates render inline Markdown (bold, italics, code, and links), preserving
  paragraph breaks when expanded.
- Numeric progress comes from ax tasks. Reaching a task total does not imply
  that the conversation is complete.
- Unknown, stale, or expired usage shows a neutral continuous track and an em dash.
- All rings use continuous strokes. The supplied OpenAI and Claude SVG marks stay
  vector artwork; OpenAI adapts to the selected appearance.
- The menu-bar item controls floating visibility, appearance, refresh, and quit.

## Notification Center and desktop widgets

The app contains a real WidgetKit extension with a small usage widget and a
large conversation widget. After launching the installed app, open Notification
Center, choose Edit Widgets, and search for **AX Widget**. The same widgets can
be placed on the desktop. Floating mode can be hidden independently.

Widgets read a private snapshot written by the app; keep the app running for new
data. macOS controls their refresh timing, so they are glanceable snapshots.
Reset times and an update age remain visible. Conversation links open the app
and then the exact provider conversation; they never submit a prompt.

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
appearances in all four layouts; these are not evidence of system-widget hosting.

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

This repository makes no model calls, sends no messages, creates no tasks or
alarms, and has no notification service, HTTP server, Cloudflare, or analytics.
The approved concept images in [docs/design](docs/design) are illustrative design
references, not screenshots of shipped behavior. Provider names and icons belong
to their respective owners; this is an independent local companion.
