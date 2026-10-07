# MacAutoBridge

State-aware macOS GUI automation proxy for AI agents. Lets LLMs control desktop applications through the [Model Context Protocol](https://modelcontextprotocol.io/) (MCP).

Written in Swift. Uses macOS Accessibility API, Apple Vision OCR, CGEvent synthesis, and ONNX Runtime for the optional local PaddleOCR fallback.

## Why

AI coding agents (Claude Code, Cursor, etc.) can edit files and run terminal commands, but they can't interact with GUI applications. MacAutoBridge bridges that gap -- it exposes 28 MCP tools that let an AI agent observe screen state, click buttons, type text, and verify results, all through structured JSON-RPC calls over stdio.

## Architecture

Five-pillar design:

```
Perception (read-only)          Action (write-only)
  AX API tree snapshots           CGEvent mouse/keyboard
  Vision OCR + ScreenCaptureKit   App focus management
  Multi-display topology

         Transaction (observe-judge-act-verify)
           Multi-step sequences with conditions
           Poll-based verification (500ms interval)

         Facade (high-level convenience)
           Composite operations (-60% tool calls)

         Server (MCP JSON-RPC 2.0 over stdio)
           Tool registry + request dispatch
```

Key design decisions:
- **Focus safety**: Every write action verifies the target app holds focus before execution. Focus loss aborts immediately.
- **Screen-global coordinates**: All coordinates are in screen-global space, auto-scaled for Retina displays and multi-monitor setups.
- **Local OCR**: Apple Vision uses accurate recognition for Chinese and English; locally supplied PP-OCRv5 ONNX models provide an optional PaddleOCR fallback.
- **AX-first resolution**: The locator engine tries Accessibility API first, falls back to OCR, then raw coordinates.

## Tools (28)

### Perception (read-only)

| Tool | Description |
|------|-------------|
| `snapshot` | All-in-one: window list + focused window AX tree + optional OCR in one call |
| `focus_app` | Focus an application by bundle ID, optionally verify window title |
| `list_windows` | List visible windows, optionally filtered by bundle ID |
| `list_displays` | List active displays with bounds and scale factors |
| `ax_snapshot` | Get the accessibility tree for an app's focused window |
| `capture_window` | Capture a window screenshot + OCR, returns text entries with coordinates |
| `find_text_on_screen` | Find text on screen via OCR across all displays |
| `get_selection` | Read selected text from the target application |

### Action (write-only)

| Tool | Description |
|------|-------------|
| `click` | Click at a target (OCR text / AX element / coordinates) |
| `click_text` | Click on text found via OCR in the target app |
| `right_click` | Right-click to open context menus |
| `drag` | Drag from one point to another (10-step interpolated) |
| `type_text` | Type text into the focused application |
| `type_in_focused_field` | Type into focused field with AX + OCR verification |
| `scroll` | Scroll at a position (positive = down, negative = up) |
| `press_key` | Press a keyboard key with optional modifiers |

### Transaction

| Tool | Description |
|------|-------------|
| `wait_until` | Wait until a condition is met (text appears/disappears, AX element exists, window appears) |

### Composite

| Tool | Description |
|------|-------------|
| `focus_and_assert` | Focus app and assert expected window title |
| `capture_app` | Screenshot + OCR, returns text entries with screen-global coordinates |
| `goto_folder` | Navigate to a folder in macOS file dialogs (Cmd+Shift+G workflow) |
| `look` | Observe the target application with screenshot and OCR |
| `capture_to_file` | Save a screenshot to a local file |
| `context_menu_click` | Open a context menu and select an item |
| `watch_progress` | Observe progress until a completion condition is met |
| `scroll_until_text` | Scroll until matching text becomes visible |
| `subtitle_workflow` | Run a subtitle recognition workflow |
| `export_srt` | Export subtitles as SRT |

### Diagnostic

| Tool | Description |
|------|-------------|
| `diagnose` | Reports runtime environment: permissions, app visibility, window server access |

## Requirements

- macOS 14+
- Swift 5.10+
- **Accessibility permission** -- System Settings > Privacy & Security > Accessibility
- **Screen Recording permission** -- System Settings > Privacy & Security > Screen Recording

Both permissions must be granted to the process that runs MacAutoBridge (typically your terminal app or the MCP host).

## Build

```bash
# Debug build
swift build

# Release build
swift build -c release

# Binary location
.build/release/MacAutoBridge
```

OCR model weights are not included in this repository or its source archives. Apple Vision OCR remains available without them. To enable the optional PaddleOCR fallback, place compatible `pp_ocrv5_det.onnx`, `pp_ocrv5_cls.onnx`, and `pp_ocrv5_rec.onnx` files in `Sources/MacAutoBridge/Resources/models/` before building; these files are ignored by Git. The recognition model must match the included `ppocrv5_dict.txt` vocabulary. Swift Package Manager downloads ONNX Runtime during the first build.

## MCP Integration

### Claude Code

Add to `~/.claude/settings.json`:

```json
{
  "mcpServers": {
    "mac-auto-bridge": {
      "command": "/path/to/MacAutoBridge"
    }
  }
}
```

Or with a debug build:

```json
{
  "mcpServers": {
    "mac-auto-bridge": {
      "command": "swift",
      "args": ["run", "MacAutoBridge"],
      "cwd": "/path/to/mac-auto-bridge"
    }
  }
}
```

### Other MCP Hosts

MacAutoBridge uses stdio transport (JSON-RPC 2.0). It reads JSON-RPC requests from stdin and writes responses to stdout. Diagnostic logs go to stderr.

## Usage Example

A typical AI agent workflow to interact with a GUI app:

```
1. snapshot(bundle_id: "com.apple.finder")
   -> Returns window list + AX tree of Finder's focused window

2. click_text(bundle_id: "com.apple.finder", text: "Downloads")
   -> Finds "Downloads" via OCR and clicks it

3. wait_until(bundle_id: "com.apple.finder", text_appears: "Downloads")
   -> Waits until "Downloads" appears in the window

4. capture_app(bundle_id: "com.apple.finder")
   -> Screenshots + OCR to see current state with coordinates
```

For file dialog navigation:

```
1. goto_folder(bundle_id: "com.lemon.lvpro", path: "/Users/me/project/assets")
   -> Sends Cmd+Shift+G, types path, presses Enter -- all in one call
```

## How It Works

MacAutoBridge runs as a child process of the MCP host. It keeps the main thread alive with `RunLoop.main.run()` for AppKit/Accessibility API access, and reads stdin on a detached thread.

When a tool is called:
1. **Focus acquisition** -- For write operations, the target app is brought to front (NSRunningApplication + AppleScript fallback, 4s timeout)
2. **Target resolution** -- The locator engine resolves targets through an AX -> OCR -> coordinate fallback chain
3. **Action execution** -- CGEvent synthesis for mouse/keyboard, with focus re-verification during long operations
4. **Result verification** -- Optional post-action verification via AX value reads or OCR

All coordinates are in screen-global space. Multi-display setups are handled automatically -- OCR scans all connected displays and transforms coordinates per-display.

## Privacy

Request and response payloads are not copied to stderr. Workflow details remain in the MCP response, where the host may still retain them. Screenshot tools write local PNG files under `/tmp`; these files may contain private screen content and currently have no automatic retention cleanup. Do not commit screenshots or host logs.

## License

MIT
