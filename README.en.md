# Ambient Context MCP

[![MCP](https://img.shields.io/badge/MCP-server-1f6feb?logo=anthropic&logoColor=white)](https://modelcontextprotocol.io)
[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS-0078d6)](#requirements)
[![.NET](https://img.shields.io/badge/.NET-8.0-512bd4?logo=dotnet&logoColor=white)](https://dotnet.microsoft.com)
[![Swift](https://img.shields.io/badge/Swift-6-fa7343?logo=swift&logoColor=white)](https://swift.org)
[![Release](https://img.shields.io/github/v/release/nassie256/ambient-context-mcp?logo=github&logoColor=white)](https://github.com/nassie256/ambient-context-mcp/releases)
[![License: MIT](https://img.shields.io/github/license/nassie256/ambient-context-mcp)](LICENSE)

**en** | [ja](README.md)

A resident process (Windows tray / macOS menu bar) that exposes local ambient context (presence, foreground app category, battery, power events, system load, long-session detection, etc.) to AI clients (Claude Code, Claude Desktop, etc.) as privacy-classified MCP tools.

> The screenshots show the Windows build. The macOS build (menu bar resident, native Swift) speaks the same MCP contract and uses the same settings schema; see [macOS differences](#macos-differences).

<p align="center">
  <img src="screenshot1.png" alt="Settings dialog – MCP Server tab" width="45%" />
  <img src="screenshot2.png" alt="Settings dialog – Transmission tab" width="45%" />
</p>

## Features

- **Local-only**: Listens on 127.0.0.1 only — no outbound network traffic
- **Off by default**: Medium / high sensitivity fields are not transmitted unless explicitly opted in
- **Small footprint**: A single tray / menu bar resident process
- **Cross-platform**: Native on both Windows (WinUI 3 / .NET 8) and macOS (Swift 6 / AppKit), sharing the tool contract, settings schema and privacy classifications
- **MCP Streamable HTTP**: Served at `http://127.0.0.1:37690/mcp`, Bearer token required
- **Privacy diagnostics**: `ambient_context_get_policy` lets clients self-diagnose "why this value is not being sent"
- **Bilingual UI**: Japanese / English, follows OS culture by default; switchable from the settings dialog

## Four exposed tools

| Tool | Description |
|---|---|
| `ambient_context_get_states` | Current context states (presence, battery, foreground app category, etc.) |
| `ambient_context_poll_events` | Unread events past the per-client cursor (user_returned, ac_power_connected, etc.) |
| `ambient_context_describe_events` | Static payload schema catalog for all events (sensitivity, descriptions, examples; no live data) |
| `ambient_context_get_policy` | Sensitivity classifications and effective transmit decisions (no live data) |

## Quick start

### A. Claude Desktop (MCPB bundle) — Windows and macOS

Download `ambient-context-mcp-vX.Y.Z.mcpb` from the [Releases](https://github.com/nassie256/ambient-context-mcp/releases) page, then install it from Claude Desktop's **Settings → Extensions**. The `.mcpb` is a single cross-platform file containing both the Windows and macOS payloads; the right stdio bridge is picked automatically. Once installed, Claude Desktop auto-spawns the app and the tools become available.

> The app stays a single process to preserve the single LocalContextHub. The MCPB bridge only spawns it if it isn't already running; otherwise it attaches to the existing one.

> **macOS note**: the bundled app is ad-hoc signed (no Apple Developer Program), so Gatekeeper has to be told to allow it once. If the tools do not respond, open **System Settings → Privacy & Security** and press **Open Anyway**.

> **macOS note on updates**: with ad-hoc signing the designated requirement is a bare cdhash, so **every app update voids the existing Accessibility / Automation grants** — and macOS does not prompt again, it just silently degrades the context that needs them (window title, media). After updating, open **System Settings → Privacy & Security → Accessibility / Automation**, **remove the old entry and add the app again**. A Developer ID signature would fix this; it is not currently used.

### B. Claude Code / other clients (Streamable HTTP)

#### Windows

Extract the archive (`ambient-context-mcp-vX.Y.Z-win-x64.zip`) and run `ambient-mcp.exe`.

1. Launch the app → the tray shows `[●] Ambient Context MCP — :37690`
2. Click the tray icon → the settings dialog opens
3. On the **Transmission** tab, check the contexts you want to expose → Save
4. Tray menu → **Copy Claude Code config**
5. Paste into any terminal

```cmd
claude mcp add ambient-context \
  --transport http http://127.0.0.1:37690/mcp \
  --header "Authorization: Bearer <TOKEN>"
```

6. From Claude Code you can now call `ambient_context_get_states` and so on.

#### macOS

Download `ambient-context-mcp-vX.Y.Z-macos-universal.zip` (or the `.dmg`). Releases are universal binaries; a locally built single-arch package (`scripts/package-release.sh --arch arm64`) carries that arch in place of `universal`.

1. Extract it and **move `Ambient Context MCP.app` to `/Applications` first**.
   (Opening it in place makes macOS run it read-only from a random App Translocation path, which breaks the discovery file and the login item.)
2. **First launch**: the app is ad-hoc signed and not notarized, so Gatekeeper blocks it. Do one of:
   - Try to open it once in Finder, then go to **System Settings → Privacy & Security** and press **Open Anyway**
   - Or strip the quarantine attribute from a terminal (`-r` is required):
     ```bash
     xattr -d -r com.apple.quarantine "/Applications/Ambient Context MCP.app"
     ```
   > On macOS 15 and later, the old "right-click → Open" trick no longer works. One of the two steps above is required.
3. Launch it → the Ambient Context MCP icon appears in the menu bar
4. **Left-click** the icon → settings window. On the **Transmission** tab, check the contexts you want to expose → Save
5. **Right-click** the icon → **Copy Claude Code config**
6. Paste into any terminal

```bash
claude mcp add ambient-context \
  --transport http http://127.0.0.1:37690/mcp \
  --header "Authorization: Bearer <TOKEN>"
```

7. Turning on the window-title or media contexts prompts for **Accessibility** / **Automation** permission. Denying them never crashes the app — the corresponding fields just come back empty (see [docs/macos-implementation.md](docs/macos-implementation.md), written in Japanese).

> **UI language**: defaults to your OS culture. To switch, open **MCP Server → Display language**, choose Japanese / English, save, and restart the app. The privacy classification rationales returned by `ambient_context_get_policy` follow the same setting.

## macOS differences

Both builds expose the same MCP contract, but the underlying OS APIs differ:

| Item | Windows | macOS |
|---|---|---|
| Media session | Every SMTC-aware app (browsers included) | Music.app / Spotify only (Apple Events, needs Automation permission). Browser playback cannot be read |
| Window title | No permission needed | Needs Accessibility permission |
| `system_resume_automatic` | Fires | Never fires (always `system_resume_user`) |
| `system.timeZoneId` value | Windows name (`Tokyo Standard Time`) | IANA name (`Asia/Tokyo`) |
| `foregroundApp.processName` | `code.exe` | `Code` (no extension); app classification keys off the bundle id |
| `network.interfaceKinds` | Always empty | Can report wifi / wired / cellular |
| Media `albumArtist` / `trackNumber` / `genres` | Available | Not available (empty / 0) |
| Unsigned distribution | SmartScreen warning | Blocked by Gatekeeper (macOS 15+ also blocks right-click → Open). Move to `/Applications`, then "Open Anyway" or remove the quarantine attribute |
| Permissions across updates | Preserved | Ad-hoc signing changes the cdhash, so Accessibility / Automation grants are voided on every update (no re-prompt); remove and re-add the app in System Settings |

## Documentation

- [docs/tool-spec.md](docs/tool-spec.md) — MCP tool contract (input/output, scope, auth)
- [docs/privacy-classifications.md](docs/privacy-classifications.md) — Default transmission policy
- [docs/client-config.md](docs/client-config.md) — Claude Code / Desktop config examples
- [docs/windows-implementation.md](docs/windows-implementation.md) — Windows-specific implementation notes
- [docs/macos-implementation.md](docs/macos-implementation.md) — macOS-specific implementation notes (Japanese)

## Requirements

### Windows

- Windows 10 version 2004 (10.0.19041, May 2020 Update) or later
- .NET 8 Runtime + ASP.NET Core 8 Runtime x64 (only for framework-dependent builds)
- Windows App Runtime 1.8 x64 — if missing, the app guides you to the [download page](https://aka.ms/windowsappsdk/1.8/latest/windowsappruntimeinstall-x64.exe) on first launch

### macOS

- macOS 14 Sonoma or later
- Apple Silicon / Intel (Universal binary; no extra runtime to install)
- Optional: Accessibility permission for window titles, Automation permission for media info (requested only when you turn those options on)

## Build

### Windows

```powershell
# Dev build
dotnet build src\windows\AmbientContextMcp.sln

# Release artifacts (produces both the zip and the .mcpb)
pwsh tools\build-release.ps1                  # version is read from mcpb/manifest.json
pwsh tools\build-release.ps1 -Version 0.4.0   # explicit
pwsh tools\build-release.ps1 -SkipZip         # mcpb only
pwsh tools\build-release.ps1 -SkipMcpb        # zip only
```

To enable `mcpb validate`, install the CLI first with `npm i -g @anthropic-ai/mcpb`. Without it, the script falls back to `Compress-Archive` to build the `.mcpb` (manifest validation is skipped).

### macOS

Xcode is not required — the Command Line Tools (`xcode-select --install`) are enough.

```bash
cd src/macos

# Dev build
swift build

# Tests (the wrapper adds the Testing.framework search paths needed on CLT-only machines)
scripts/run-tests.sh

# Release artifacts (.app + stdio bridge → zip + dmg)
scripts/package-release.sh                      # version comes from mcpb/manifest.json
scripts/package-release.sh --version 0.8.0
scripts/build-app.sh --arch arm64               # just the .app, fast, for local checks
```

The `.mcpb` contains both the Windows and macOS binaries, so it cannot be produced on one OS alone. CI collects the artifacts from both runners and merges them with `src/macos/scripts/assemble-mcpb.sh`:

```bash
src/macos/scripts/assemble-mcpb.sh \
  --win-server dist/win-server \
  --mac-server dist/macos
```

Releases are ad-hoc signed (`codesign -s -`) and never notarized, so `spctl -a -t exec` reports `rejected` by design.

## File layout

Windows:

```
%LOCALAPPDATA%\AmbientContextMcp\
├── settings.json          # User settings (transmission opt-in, port, token)
├── ambient-context.json   # Local cache of the latest snapshot (for debugging)
├── events.jsonl           # Event history (only when persistence is enabled)
└── mcp-api.json           # Discovery info for the running MCP (removed on exit)
```

macOS (same file names and JSON schema as Windows):

```
~/Library/Application Support/AmbientContextMcp/
├── settings.json
├── ambient-context.json
├── events.jsonl
└── mcp-api.json
```

## License

[MIT](LICENSE)
