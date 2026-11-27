# ClaudeBar ✳

**Claude Code on your MacBook's Touch Bar.**

When a Claude Code session is running in your terminal, the Touch Bar
switches into *Claude mode*:

```
┌─────┬────┬────────────────────┬───────────────────────────────────────────┐
│ esc │ ✳  │ ctx 41k · out 2.3k │  /code-review  /simplify   ⚡ skip perms  │
└─────┴────┴────────────────────┴───────────────────────────────────────────┘
```

And when Claude asks for permission, the bar becomes the answer:

```
┌─────┬────┬──────────────────────────────┬────────────────────────────────┐
│ esc │ ✳  │ Claude needs your permission │ Allow Once │ Always Allow │ ✕  │
└─────┴────┴──────────────────────────────┴────────────────────────────────┘
```

When the session ends (or you switch away from your terminal), the bar
goes back to normal.

## Features

- **Permission prompts on the bar** — Allow Once / Always Allow / Reject,
  one tap each. Reject maps to Escape, just like in the terminal. Answer
  at the keyboard instead and the buttons get out of the way.
- **Skill shortcuts** — your most-used slash commands as buttons.
  Configure them in `~/.claudebar/config.json`.
- **Live usage** — how full the context window is (`ctx`) and how much
  Claude has written this session (`out`), read straight from the session
  transcript. With several sessions open, it follows whichever one spoke last.
- **`⚡ skip perms`** — types `claude --dangerously-skip-permissions` for
  you (without pressing Return — that part is on you, deliberately).
- **esc never leaves** — it's the only Esc this keyboard has, so it's
  always the leftmost button.
- **Works with the Claude desktop app too** — `com.anthropic.claudefordesktop`
  is in the default app list alongside the usual terminals.
- **A menu bar ✳** — shows how many sessions are live and whether Claude
  is working, flags a broken config or missing Accessibility access, and
  has Reload Config / Forget Sessions.
- **A tiny Claude** — the ✳ starburst breathes on the bar while Claude
  works, and rests while it waits for you. That's the easter egg. Hi.

## Requirements

- A MacBook Pro with a Touch Bar (2016–2020 models), macOS 12+
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- Xcode Command Line Tools (`xcode-select --install`) to build

## Install

```sh
git clone https://github.com/TouchMyBar/claudebar
cd claudebar
make install
```

The installer:

1. builds `ClaudeBar.app` and copies it to `~/Applications`
2. registers small [Claude Code hooks](https://docs.anthropic.com/en/docs/claude-code/hooks)
   in `~/.claude/settings.json` (merged carefully — your existing hooks
   are untouched, and a `.claudebar-backup` copy is kept)
3. writes a starter config to `~/.claudebar/config.json`

On first launch, macOS asks for **Accessibility** access. ClaudeBar needs
it to press keys in your terminal when you tap a button — that's all it's
used for. Approve it in System Settings → Privacy & Security →
Accessibility.

## How it works

```
claude (terminal) ──hooks──▶ claudebar-relay.sh ──unix socket──▶ ClaudeBar.app
                                                                     │
                                              NSTouchBar ◀───────────┤
                                              keystrokes ───────────▶ terminal
```

- Claude Code's official **hooks** fire on session start/end, prompt
  submit, tool completion, notifications, and turn completion. A tiny
  shell script relays the hook JSON to ClaudeBar over a unix socket
  (owner-only permissions); ClaudeBar hangs up the moment it has the
  payload, so hooks return in milliseconds. If ClaudeBar isn't running,
  the relay is a no-op — your sessions are never affected.
- Any hook event counts as a sign of life, so sessions that were already
  running when ClaudeBar launched get picked up on their next event. A
  session that goes quiet for 6 hours (say, a crashed terminal that never
  sent SessionEnd) is dropped until it speaks again.
- The bar only takes over while a **terminal app is frontmost** *and* a
  session is alive. The list of terminal apps is configurable.
- Buttons work by sending **keystrokes** to the frontmost app
  (`1` = allow once, `2` = always allow, Escape = reject), because Claude
  Code's prompts are keyboard-driven.

### The fine print on APIs

The Touch Bar UI is built entirely with official AppKit `NSTouchBar` API.
There is one exception, clearly contained in
[`SystemModalTouchBar.swift`](Sources/ClaudeBar/SystemModalTouchBar.swift):
Apple never shipped a public way for a background app to present on the
Touch Bar, so we use the same two stable-since-10.14 AppKit class methods
every Touch Bar customizer (Pock, MTMR, …) uses. They're looked up at
runtime and ClaudeBar simply does nothing if they ever disappear.

## Configuration

`~/.claudebar/config.json` — every key is optional:

```json
{
  "skills": ["/code-review", "/simplify", "/init"],
  "showUsage": true,
  "offerSkipPermissions": true,
  "terminalBundleIDs": ["com.apple.Terminal", "com.googlecode.iterm2"]
}
```

After editing, choose **Reload Config** from the menu bar ✳. If the
file doesn't parse, the menu says so and ClaudeBar uses defaults.

`terminalBundleIDs` replaces the default list rather than adding to it.
Running Claude Code in an editor's built-in terminal? Add the editor,
e.g. `"com.microsoft.VSCode"` — the bar will then take over whenever
that editor is frontmost and a session is live.

## Known quirks

- macOS draws a small ✕ at the left edge of any system-modal Touch Bar.
  Tapping it hides ClaudeBar until the next event brings it back.
- The Allow/Always Allow buttons press `1`/`2` in your terminal. If a
  particular prompt orders its options differently, glance at the screen
  before tapping — or just use the keyboard for that one.
- `ctx` is the input size of the latest API call (fresh + cached
  tokens), which tracks context-window fill — it drops after `/compact`.
  It isn't a billing number.
- If Claude runs an auto-approved tool at the same moment it's asking
  permission for another, the buttons may step aside early. The prompt
  is still there in the terminal.
- If a session vanished without ending cleanly and the bar won't let go,
  menu bar ✳ → **Forget Sessions**.

## Uninstall

```sh
make uninstall
```

This quits ClaudeBar, removes only its own entries from the `hooks`
section of `~/.claude/settings.json`, and deletes
`~/Applications/ClaudeBar.app` and `~/.claudebar`.

## License

MIT — see [LICENSE](LICENSE).
