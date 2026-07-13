# DaVinci Resolve MCP

Control DaVinci Resolve from Claude — timeline editing, media pool, markers,
render jobs, and Fusion node-graph building (including a reusable
title/lower-third banner generator) — via the Model Context Protocol (MCP).

Works on **both DaVinci Resolve Studio and Free**, through two different
paths, because Free quietly lost external-scripting support and needs a
workaround. Read the next section to figure out which path is yours.

---

## Why two paths?

DaVinci Resolve has always exposed a scripting API. Starting around Resolve
19.1 (~February 2025), Blackmagic removed **external scripting** access from
the **Free** edition — undocumented, no changelog entry, no setting to
re-enable it. `Preferences > System > General > External scripting using`
simply doesn't render on Free anymore. This is confirmed by Blackmagic forum
reports and reproduced first-hand in this project.

That matters because MCP servers are external processes — Claude Desktop
launches `server.py` as a subprocess, which then tries to open a scripting
connection to Resolve. On **Studio**, that connection works exactly as
Blackmagic's docs describe. On **Free**, it can't connect at all, full stop.

So this repo ships two independent ways to drive Resolve:

| | Path A — `server.py` | Path B — `ClaudeBridge.lua` |
|---|---|---|
| **Requires** | DaVinci Resolve **Studio** | DaVinci Resolve **Free** or Studio |
| **Connection** | Live MCP server, external scripting API | File-based command queue, run from inside Resolve |
| **Feel** | Real-time — ask Claude, it happens | One manual click per batch of edits (Workspace > Scripts) |
| **Runs from** | Claude Desktop only (local subprocess) | Any Claude client that can read/write the project folder |
| **Coverage** | Full tool set (39 tools) | Core editing + Fusion node-graph building (render/color not yet ported) |

If you have **Studio**, use Path A — it's strictly nicer. If you're on
**Free**, Path B is your only option, and it's a real, live-tested workaround,
not a toy.

Neither path works from a cloud/sandboxed Claude session (like Cowork) —
both need something running locally, next to your actual copy of Resolve,
since there's no network path from a cloud sandbox to your laptop.

---

## Path A — DaVinci Resolve Studio (`server.py`)

### 0. Requirements
- DaVinci Resolve **Studio**, installed and opened at least once.
- Python 3.9–3.11.
- Claude Desktop, installed and signed in.

### 1. Turn on external scripting
DaVinci Resolve → **Preferences → System → General** (menu path varies
slightly by version) → **External scripting using** → set to **Local**.
Restart Resolve.

### 2. Set environment variables
Add these as **System** environment variables (Start → "Edit the system
environment variables"), not just user variables:

| Variable | Value |
|---|---|
| `RESOLVE_SCRIPT_API` | `C:\ProgramData\Blackmagic Design\DaVinci Resolve\Support\Developer\Scripting` |
| `RESOLVE_SCRIPT_LIB` | `C:\Program Files\Blackmagic Design\DaVinci Resolve\fusionscript.dll` |
| `PYTHONPATH` | `%PYTHONPATH%;%RESOLVE_SCRIPT_API%\Modules` |

(macOS/Linux: same idea, different paths — see Blackmagic's own scripting
README under `.../Support/Developer/Scripting/README.txt` for your platform's
paths.)

Log out and back in (or reboot) so every app — including Claude Desktop —
picks up the new variables.

### 3. Install dependencies
```
cd path/to/davinci_resolve_mcp
pip install -r requirements.txt
pip install pydantic
```

### 4. Point Claude Desktop at the server
Open (or create) your Claude Desktop config:
- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Windows: `%APPDATA%\Claude\claude_desktop_config.json`

Merge in the block from `claude_desktop_config.json` in this repo, with the
path updated to where you cloned it:

```json
{
  "mcpServers": {
    "davinci_resolve_mcp": {
      "command": "python3",
      "args": ["/ABSOLUTE/PATH/TO/davinci_resolve_mcp/server.py"]
    }
  }
}
```

Fully quit and reopen Claude Desktop (from the system tray/menu bar icon, not
just closing the window).

### 5. Test it
Open Resolve with a project and timeline active, then in Claude Desktop:
*"Call resolve_get_info."* You should get back the product name, version,
and current page. If that works, you're live — full details in
[`WINDOWS_SETUP_GUIDE.md`](WINDOWS_SETUP_GUIDE.md) (Windows-specific, but the
troubleshooting section applies everywhere).

---

## Path B — DaVinci Resolve Free (`ClaudeBridge.lua`)

No live connection — instead, Claude writes a small JSON command queue, you
trigger one Lua script from inside Resolve's Scripts menu, and Claude reads
back the result. One manual click per batch, but each batch can hold as many
commands as you want.

### Install
1. Copy `bridge/ClaudeBridge.lua` into:
   ```
   %APPDATA%\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Utility\
   ```
   (macOS: `~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/`.
   Create the `Utility` folder if it's missing.)

   **Tip:** symlink instead of copy (`mklink` on Windows, `ln -s` on
   macOS/Linux) so edits to the file in this repo take effect immediately,
   with no re-copy step:
   ```
   mklink "%APPDATA%\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Utility\ClaudeBridge.lua" "C:\path\to\davinci_resolve_mcp\bridge\ClaudeBridge.lua"
   ```
2. Restart Resolve (or reopen the Workspace menu) so it re-scans Scripts
   folders.
3. Confirm **Workspace > Scripts > Utility > ClaudeBridge** now shows up —
   it's under Utility, so it appears on every page (Edit, Fusion, Color…).

### Test it
1. Open a project in Resolve (a timeline isn't required for `get_info`).
2. Create `bridge/command.json`:
   ```json
   { "commands": [ { "action": "get_info", "params": {} } ] }
   ```
3. Run **Workspace > Scripts > Utility > ClaudeBridge**. It gives no popup by
   design — just a Console print and a silent file write.
4. Check `bridge/result.json` — you should see your real Resolve version and
   current page. If that's there, the bridge is live.

### Everyday use
Ask Claude for the edit you want; it writes `bridge/command.json` for you.
Run ClaudeBridge from the Scripts menu, then tell Claude what
`bridge/result.json` shows (or let it read the file directly).

Full action reference, protocol details, and known limitations:
[`BRIDGE_SETUP_GUIDE.md`](BRIDGE_SETUP_GUIDE.md).

---

## What you can do with it

### Core editing (both paths)
Project/timeline management, media pool, markers, timecode, import/append,
render presets and jobs (Path A only for now), LUT application (Path A only
for now).

### Fusion node-graph building (both paths)
Both `server.py` and `ClaudeBridge.lua` expose the same primitives for
scripting Fusion's node graph directly — `AddTool`, `SetInput`, node
connections — instead of hand-placing everything in the UI:

| Action | What it does |
|---|---|
| `fusion_get_comp` | Attach to (or create) a clip's Fusion composition. Must be the first Fusion action in any batch — comp state doesn't persist between separate script runs. |
| `fusion_list_tools` | List every node currently in the comp. |
| `fusion_add_tool` | Add a node (`Background`, `TextPlus`, `Merge`, `RectangleMask`, `EllipseMask`, `Blur`, etc.) at a given graph position. |
| `fusion_set_inputs` | Set one or more Inspector fields on a node. Per-field error isolation — one wrong input name reports in the error list without blocking the rest. |
| `fusion_get_inputs` | Read a node's current Inspector values back — self-check instead of re-guessing. |
| `fusion_connect` | Wire one node's output into another node's input. |
| `fusion_delete_tool` | Remove a node. |
| `fusion_save_tool_settings` | Serialize a node + its upstream tree to a `.setting` file. |
| `fusion_render_preview` (Path B) | Render one frame to a PNG so Claude can read the actual composite instead of waiting on a screenshot. Treat as experimental — see Known Limitations. |

### Reusable title builder: narration banner + journey stepper
`resolve_fusion_build_narration_banner` builds a complete lower-third-style
overlay in one call: a 3-zone info banner (title / heading / body / tags /
stat callout) plus an 8-node progress stepper, for narrating a multi-step
process on screen. Every field is a parameter — title, step chip, heading,
body copy, up to 3 tags, a stat value + label, all 8 stepper labels, and
which step is "active" (earlier ones render as completed, later ones as
upcoming) — so it's reusable for any step-by-step walkthrough, not tied to
any one project. It's a structural first pass: treat exact pixel offsets as
a finishing pass once you can see it in the Inspector.

---

## Fusion scripting notes (learned the hard way)

Genuinely useful if you're extending this project's Fusion tooling — these
came from live trial and error against real Resolve, not the docs:

- **Fusion can silently no-op on an unrecognized `SetInput` key.** It reports
  success either way — "applied" is not the same as "worked." Always
  visually (or via `fusion_get_inputs`) confirm a new input name actually did
  something before relying on it.
- **`RectangleMask`'s `Border`/`BorderWidth` inputs don't work** — accepted
  with zero errors, zero visual effect, renders as an ordinary solid mask.
  For a ring/outline, use the **outset-rect trick** instead: a second,
  slightly larger solid rect of the outline color, merged in *behind* the
  existing fill.
- **The outset-rect trick only works if `Foreground` has real transparent
  gaps** — i.e., it must be its own small, isolated masked composite (alpha
  0 outside its own shape), not the entire accumulated node stack (which
  sits on an opaque backdrop with alpha 1 everywhere, so there's no gap to
  peek through). Build each new detail layer as its own isolated composite,
  then merge it **on top** — background color as `Merge.Background`, the
  isolated shape as `Merge.Foreground` — never sandwich new work behind an
  already-merged stack.
- **All position/size values are normalized 0–1 by image WIDTH**, for both X
  and Y, even height — Fusion uses width as the single unit for both axes so
  circles stay round at non-square resolutions. `Center` is `[X, Y]`,
  Y = 0 at the **bottom** of frame.
- **`TextPlus`'s `Font` must be an installed system font**, or Fusion throws
  `Could not find font: X: Bold` — but only at **render** time, not at
  `SetInput` time, so a batch can report full success and still render
  blank. This cascades: every downstream `Merge` reading that node's output
  fails too, all the way to `MediaOut1` going blank. Stick to a known-good
  bundled font (e.g. `"Open Sans"`) if you're not sure a custom font is
  installed.
- **Every trigger of `ClaudeBridge.lua` is a fresh Lua process** — the
  attached comp and tool cache from a previous run don't persist. Any Fusion
  job needs `fusion_get_comp` queued in the *same* batch as everything else.

---

## Repository layout

```
server.py                  MCP server for Path A (Studio) — 39 tools, stdio transport
requirements.txt           Python deps for server.py
claude_desktop_config.json Claude Desktop config snippet template
bridge/ClaudeBridge.lua    Path B script — install into Resolve's Scripts/Utility folder
WINDOWS_SETUP_GUIDE.md     Full Path A walkthrough + troubleshooting
BRIDGE_SETUP_GUIDE.md      Full Path B walkthrough + protocol + action reference
```

`bridge/command.json`, `bridge/result.json`, `bridge/command.processed.json`,
and any `bridge/preview*.png` are per-session working files (gitignored) —
they get created/overwritten every time you use the bridge, not shipped in
the repo.

---

## Known limitations

- **Path B is not live** — every batch needs one manual click in Resolve. A
  Lua script can't poll in the background without freezing Resolve's UI.
- **`fusion_render_preview` (Path B) is experimental** — it worked cleanly
  the first time in testing, then crashed Resolve on a later call, possibly
  from re-rendering while the graph was being edited in the same batch.
  Recommended: don't combine graph edits and a render-preview call in the
  same batch — render as a separate, read-only-safe follow-up once graph
  changes are already confirmed via `fusion_get_inputs`/`fusion_list_tools`.
- **Path B doesn't yet cover render/deliver jobs or color/LUT application**
  — those exist in `server.py` (Path A) but haven't been ported to
  `ClaudeBridge.lua` yet. Contributions welcome (see below).
- **Clip speed/retime is not scriptable at all** — confirmed against
  Blackmagic's documented `TimelineItem:SetProperty` key list; there's no
  "Speed" key, only `RetimeProcess` (interpolation mode, not the speed
  value). This is a gap in Resolve's own scripting API, not something either
  path here can work around.

---

## Contributing

Issues and PRs welcome — especially:
- Porting the remaining `server.py` render/color tools into
  `ClaudeBridge.lua` for feature parity between the two paths.
- Confirming/expanding the Fusion input-name cheat sheet above (gradient
  fills, hollow-ring masks, justification enums are all open questions).
- Testing on macOS/Linux (this project was built and tested on Windows).

## License

MIT — see [LICENSE](LICENSE).
