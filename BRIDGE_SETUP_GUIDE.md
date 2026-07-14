# ClaudeBridge — real-time-ish editing on DaVinci Resolve Free

## Why this exists

`server.py` (the original MCP server in this project) needs Resolve's
**external scripting** permission, which Blackmagic quietly removed from
the Free edition starting around Resolve 19.1. Without Studio, that
preference doesn't even appear in Preferences > System > General, and
no external process — including `server.py` — can open a scripting
connection to Resolve anymore.

What Free *does* still allow, fully, is a Lua script launched from
**inside** Resolve via Workspace > Scripts. That script gets the same
full API access external scripting used to give. `ClaudeBridge.lua`
is that internal launch point.

## How it works

There's no live socket connection. Instead:

1. Claude writes `bridge\command.json` — a small queue of actions.
2. You trigger `ClaudeBridge.lua` from Resolve's Scripts menu.
3. It reads the queue, executes each action against your real project,
   and writes `bridge\result.json` with what happened.
4. Claude reads `result.json` back to confirm success/failure.

So it's not push-button live, but it collapses each round of edits to
one manual trigger in Resolve — closer to real-time than copy-pasting
script text by hand.

## Install (one-time)

1. Copy `bridge\ClaudeBridge.lua` to:
   ```
   %APPDATA%\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Utility\
   ```
   (Create the `Utility` folder if it doesn't exist. If that path doesn't
   work on your install, try `%PROGRAMDATA%\Blackmagic Design\DaVinci
   Resolve\Fusion\Scripts\Utility\` instead — Windows path behavior has
   varied across Resolve versions.)
2. Restart Resolve (or just reopen the Workspace menu) so it re-scans
   the Scripts folders.
3. Confirm you now see **Workspace > Scripts > Utility > ClaudeBridge**.
   It's under Utility, so it shows up on every page (Edit, Fusion,
   Color, etc.), not just one.

## Test it

1. Open DaVinci Resolve, open a project (a timeline isn't required yet —
   `get_info` doesn't need one).
2. Create `bridge\command.json` with a harmless test command:
   ```json
   { "commands": [ { "action": "get_info", "params": {} } ] }
   ```
   (`command.json`/`result.json`/`command.processed.json` are gitignored —
   they're per-session working files, regenerated every time you use the
   bridge, not part of the repo.)
3. Run **Workspace > Scripts > Utility > ClaudeBridge**.
4. Check `bridge\result.json` — you should see your Resolve version and
   current page reported back. If that works, the bridge is live.

## Everyday use

Just ask Claude for the edit you want. Claude will write the right
commands into `bridge\command.json` for you — you shouldn't normally
need to hand-edit this file. When Claude says the command file is
ready, run ClaudeBridge from the Scripts menu and tell Claude what
`result.json` shows (or let it read the file directly if it has
access to this folder).

If you want to speed up the trigger step, try opening **Keyboard
Customization**, searching for "ClaudeBridge" or "Scripts," and seeing
if your Resolve version lets you bind it to a hotkey — this varies by
version and wasn't confirmed working at the time this was written, so
treat it as worth trying rather than guaranteed.

## Supported actions (v1)

Matches the read/write core of `server.py`'s tool set, minus render
jobs, color/LUTs, and Fusion node-graph building — those weren't
ported yet. Each command in the queue looks like:

```json
{ "action": "<name>", "params": { ... } }
```

| action | params | notes |
|---|---|---|
| `get_info` | — | product name, version, current page |
| `open_page` | `page` | cut / edit / fusion / color / fairlight / deliver / media |
| `list_projects` | — | |
| `get_project_info` | — | name, timeline count |
| `get_project_settings` | `setting_name` (optional) | omit for all settings |
| `list_timelines` | — | |
| `get_timeline_info` | — | active timeline only |
| `create_timeline` | `name` | |
| `set_current_timeline` | `timeline_name` or `timeline_index` | |
| `get_timeline_items` | `track_type`, `track_index` | defaults: video, 1 |
| `get_timecode` | — | |
| `set_timecode` | `timecode` (HH:MM:SS:FF) | |
| `add_marker` | `frame_id`, `color`, `name`, `note`, `duration`, `custom_data` | color/name/note/duration/custom_data optional |
| `get_markers` | — | |
| `delete_marker` | `frame_num` | |
| `list_media_pool` | — | current folder only |
| `import_media` | `file_paths` (array) | absolute paths |
| `create_bin` | `name` | in current Media Pool folder |
| `append_to_timeline` | `clip_names` (array) | clips must already be in Media Pool |
| `fusion_get_comp` | `track_index`, `clip_index`, `create_if_missing` | attach to (or create) a clip's Fusion comp. **Must be the first Fusion action in the batch** — comp state doesn't persist between separate script triggers. Defaults: track 1, clip 0, create_if_missing true |
| `fusion_list_tools` | — | every node in the attached comp: `{name, id}` |
| `fusion_add_tool` | `tool_id`, `name`, `xpos`, `ypos` | e.g. `tool_id: "Background"`, `"TextPlus"`, `"Merge"`, `"RectangleMask"`; `name` is your reference name for later calls |
| `fusion_set_inputs` | `tool_name`, `inputs` (map) | sets one or more Inspector fields; per-field error isolation — a wrong name reports in `failed` without blocking the rest |
| `fusion_connect` | `from_tool`, `to_tool`, `to_input` | wires one tool's output into another's input; `to_input` defaults to `"Input"` |
| `fusion_delete_tool` | `tool_name` | |
| `fusion_save_tool_settings` | `tool_name`, `file_path` | serializes a tool + its upstream tree to a `.setting` file |
| `fusion_get_inputs` | `tool_name`, `keys` (array) | reads current Inspector values back — self-check tool positions/colors instead of re-guessing them; per-key error isolation like `fusion_set_inputs` |
| `fusion_render_preview` | `source_tool` (default `MediaOut1`), `file_path`, `frame` (optional, defaults to comp's current time) | renders one frame to a PNG/file via a reusable hidden `_ClaudeBridge_PreviewSaver` node, so Claude can read the actual composite instead of waiting on a screenshot. **Unverified as of 2026-07-13** — first live use of `comp:Render()` from inside Resolve's Fusion page. |

Multiple commands can be queued in one `command.json` and will all run
in order on a single trigger, with per-command error isolation — one
bad action won't block the rest.

**Fusion-specific note:** every trigger of `ClaudeBridge.lua` is a fresh Lua
process, so the attached composition and tool cache from a previous run are
gone by the next click. Any Fusion job — even just adding two nodes — must
queue `fusion_get_comp` together with the rest of the steps in the *same*
`command.json` batch.

## Known limitations

- **Not live** — every batch needs one manual click/trigger in Resolve.
  A Lua script can't sit in a background polling loop without freezing
  Resolve's UI, so this is intentionally single-shot per trigger.
- **Fusion actions are ported but not yet live-tested.** They mirror
  `server.py`'s Python logic (which was also never run against a real
  Resolve), so exact input names and enum values — e.g. the `Background`
  tool's gradient `Type` value — are unconfirmed. Treat the first real run
  of any new Fusion action as a debugging pass, same as the core actions
  were before the `GetVideoTrackCount` → `GetTrackCount("video")` fix.
- **No render/color actions yet** (`apply_lut`, render/deliver jobs). Can
  be added to `ClaudeBridge.lua`'s `ACTIONS` table the same way the
  existing ones are written, following `server.py`'s equivalent tool as
  a reference.
- **The only way to get true always-on real-time control is DaVinci
  Resolve Studio**, which restores the External Scripting preference
  and lets `server.py` connect directly. Worth it if this workflow
  becomes central to your editing.
