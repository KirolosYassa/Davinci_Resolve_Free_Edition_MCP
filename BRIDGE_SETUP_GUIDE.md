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

## Supported actions

Started as the read/write core of `server.py`'s tool set and has since grown
past it: Fusion node-graph building/inspection and a dedicated set of
banner/overlay-image placement actions (useful any time you need to drop a
sequence of still images onto a timeline at specific frames — lower-thirds,
title cards, chapter banners, etc.) are now included too. Render jobs and
color/LUT actions are still not ported. Each command in the queue looks like:

```json
{ "action": "<name>", "params": { ... } }
```

Multiple commands can be queued in one `command.json` and will all run in
order on a single trigger, with per-command error isolation — one bad action
won't block the rest.

### Project & page

| action | params | notes |
|---|---|---|
| `get_info` | — | product name, version, current page |
| `open_page` | `page` | cut / edit / fusion / color / fairlight / deliver / media |
| `list_projects` | — | |
| `get_project_info` | — | name, timeline count |
| `get_project_settings` | `setting_name` (optional) | omit for all settings |

### Timeline

| action | params | notes |
|---|---|---|
| `list_timelines` | — | |
| `get_timeline_info` | — | active timeline only; returns name, `start_frame`, `end_frame`, `current_timecode`, video/audio track counts, and `frame_rate` (the latter two needed to convert a real-world timestamp into an absolute Resolve frame number) |
| `create_timeline` | `name` | |
| `set_current_timeline` | `timeline_name` or `timeline_index` | |
| `add_track` | `track_type` (default `video`) | `video` / `audio` / `subtitle`. Always appends a new track at the end of that type's list — for video, higher track numbers render on top, so this is the safe way to add an overlay layer without touching what's already there. Returns `count_before`/`count_after`/`new_track_index`. |
| `get_timeline_items` | `track_type` (default `video`), `track_index` (default `1`) | returns each item's `name`, `start`, `end`, `duration`, `source_start`, `source_end` |
| `delete_timeline_items` | `track_type` (default `video`), `track_index` | removes every item on that track — there's currently no action to remove the (now-empty) track itself, only its contents |
| `remove_timeline_items` | `track_type` (default `video`), `track_index`, `names` (array, required) | deletes only the named clips from a track instead of wiping the whole thing — requires a non-empty `names` list so it can never wipe a track by omission; any name that doesn't match a current clip on that track comes back in the response instead of failing silently |
| `get_timecode` | — | |
| `set_timecode` | `timecode` (HH:MM:SS:FF) | |

### Markers

| action | params | notes |
|---|---|---|
| `add_marker` | `frame_id`, `color`, `name`, `note`, `duration`, `custom_data` | color/name/note/duration/custom_data optional |
| `get_markers` | — | |
| `get_markers_by_color` | `color` | returns matches sorted by frame, each annotated with `end_frame` = the frame of the very next marker on the timeline (any color) — handy for "place something from this marker until the next one" workflows. `end_frame` is `nil` if nothing follows. |
| `delete_marker` | `frame_num` | |

### Media Pool & bins

| action | params | notes |
|---|---|---|
| `list_media_pool` | `bin_name` (optional) | omit for the current folder; pass a bin name to inspect a specific root-level bin without switching to it |
| `import_media` | `file_paths` (array) | absolute paths |
| `create_bin` | `name` | in current Media Pool folder |
| `clear_bin` | `bin_name` (optional) | deletes every clip in a named root-level bin (or the current folder if omitted) — useful for resetting a bin before a clean re-import |
| `remove_clips` | `bin_name`, `names` (array) and/or `file_paths` (array), `force` (optional) | deletes specific clips from a bin by name and/or source path, instead of `clear_bin`'s all-or-nothing sweep — handy for cleaning up a handful of orphaned stills from a bin that also holds source footage you want to keep. By default refuses to delete any clip currently used on the active timeline (`MediaPool:DeleteClips()` silently removes every timeline instance too) — those come back in `in_use_skipped`; pass `force=true` to delete them anyway. Reports any selector that matched nothing in `not_found` rather than a silent no-op. |
| `append_to_timeline` | `clip_names` (array) | clips must already be in Media Pool |

### Banner / overlay image placement

A small extension beyond `server.py`'s original tool set, for dropping a
sequence of still images (banners, title cards, lower-thirds) onto a
timeline at specific frames.

| action | params | notes |
|---|---|---|
| `import_banner_images` | `file_paths` (array), `bin_name` (optional) | imports each file in its own `ImportMedia` call (importing several sequentially-numbered stills together in one call can trigger Resolve's image-sequence auto-detection and merge them into one clip — importing one at a time avoids that). If `bin_name` is given, finds-or-creates a root-level bin with that name and imports into it. Caches the resulting clips in order for `place_clip_on_track` to reference in the same batch. |
| `place_clip_on_track` | `clip_index` (1-based, from `import_banner_images`'s order this batch), `track_index`, `start_frame`, `end_frame` | places one imported clip at an exact frame range. Internally calls `MediaPoolItem:SetMarkInOut` before appending — a still image's native duration is 1 frame, so the mark in/out is what actually controls its on-timeline length. **Must run in the same `command.json` batch as the `import_banner_images` call it references** — the imported-clip cache doesn't persist between separate script triggers. |
| `refresh_bin_clips` | `bin_name`, `file_paths` (optional) | for each matching clip, calls `MediaPoolItem:ReplaceClip()` with its own current file path — reloads a regenerated PNG from disk into the *same* MediaPoolItem, so every place it's used on the timeline updates automatically without touching timeline position, track, or trim. Omit `file_paths` to refresh the whole bin. This is the way to push new pixels into an already-placed clip without disturbing anything about where it sits. |
| `relink_bin_clips` | `mappings` (array of `{old_path, new_path}`), `bin_name` (optional) | `refresh_bin_clips`'s sibling — calls `ReplaceClip()` with a *different* path instead of the clip's own, which is how a still gets renamed on disk without the timeline noticing: every `TimelineItem` referencing that `MediaPoolItem` keeps its position, duration, and trim, because `ReplaceClip` only swaps what the `MediaPoolItem` points at. Useful when migrating a batch of placed stills to a new, stable naming scheme without discarding manual trims. Matches by each clip's current File Path — a path matching more than one clip is reported as a failure rather than guessed. Read back `path_confirmed` on each result: `ReplaceClip` can report success while leaving the clip pointed at the old file. |
| `rename_bin_clips` | `renames` (array of `{file_path, name}`), `bin_name` (optional) | `relink_bin_clips` usually makes a clip's display name follow its new filename automatically, but not always — this sets the label directly. Matches by File Path, never by name (the name is the thing you're fixing). Useful as a follow-up pass after a bulk relink to confirm every clip's label actually matches its new file. |

**A note on inserting a new item between two already-placed ones:** clips
placed back-to-back on one track share frame boundaries with no gap, so
there's usually nowhere to insert without either trimming a neighbor or
overlaying on a separate track. `add_track` + `place_clip_on_track` on the
new (topmost) track is the safe way to do this — it renders on top of
whatever's on the original track for that window, with zero edits to
anything already placed. Overwriting a neighboring clip's own file via
`refresh_bin_clips` to "make room" is possible but destructive — it replaces
that clip's content outright, it doesn't visually layer alongside it.

### Banner fade cleanup

`set_clip_fade` — an earlier attempt at scripting a per-clip opacity fade by
building a keyframed Fusion node graph (`MediaIn -> BrightnessContrast ->
MediaOut` with a keyframed alpha ramp) — is **retired and fails closed**: it
now always returns an error instead of running. In practice, per-frame
keyframe read-back reported success while the visible fade still sat in the
wrong place whenever a clip's Fusion comp range didn't match its trimmed
duration (e.g. media handles left behind by a transition), so it couldn't be
trusted unattended. Apply fades by hand in Resolve's Edit page instead.

| action | params | notes |
|---|---|---|
| `remove_clip_fade` | `track_index` (default 3), `clip_name` or `clip_index` | removes only the fade node this project's tooling would have added to a clip's Fusion comp, leaving the clip, its timing, its comp, and every unrelated Fusion tool untouched — reconnects the fade's source directly to `MediaOut` before deleting the node, then reads back the final wiring to confirm. Cleanup-only; there is no corresponding "add" action. |

### Fusion compositing

Ported from `server.py`'s `resolve_fusion_*` tools. Best-effort against the
documented Fusion scripting API — exact input names and enum values can
vary by Resolve version, so treat a new action's first real use as a
debugging pass rather than a guaranteed result.

**Every trigger of `ClaudeBridge.lua` is a fresh Lua process**, so the
attached composition and tool cache from a previous run are gone by the next
click. `fusion_get_comp` must be the first Fusion action queued, in the same
`command.json` batch as the rest of that job's steps.

| action | params | notes |
|---|---|---|
| `fusion_get_comp` | `track_index` (default 1), `clip_index` (default 0), `create_if_missing` (default true) | attaches to (or creates) a clip's Fusion comp. **Must be the first Fusion action in the batch.** |
| `fusion_get_current_comp` | — | attaches to whatever comp is currently open in the Fusion page, instead of addressing a clip by track/index |
| `fusion_list_tools` | — | every node in the attached comp: `{name, id}` |
| `fusion_list_inputs` | `tool_name` | lists every Inspector input name available on a tool (handy for discovering valid keys before calling `fusion_set_inputs`) |
| `fusion_add_tool` | `tool_id`, `name`, `xpos`, `ypos` | e.g. `tool_id: "Background"`, `"TextPlus"`, `"Merge"`, `"RectangleMask"`; `name` is your reference name for later calls |
| `fusion_set_inputs` | `tool_name`, `inputs` (map) | sets one or more Inspector fields; per-field error isolation — a wrong name reports in `failed` without blocking the rest |
| `fusion_set_inputs_at_time` | `tool_name`, `inputs` (map), `time` | same as above but at a specific comp time, for keyframing |
| `fusion_get_inputs` | `tool_name`, `keys` (array) | reads current Inspector values back — self-check tool positions/colors instead of re-guessing them; per-key error isolation like `fusion_set_inputs` |
| `fusion_get_inputs_at_time` | `tool_name`, `keys` (array), `time` | same as above but at a specific comp time |
| `fusion_get_connections` | `tool_name`, `keys` (array) | reads what's wired into the given input keys, via each key's `GetConnectedOutput()`/`Output:GetTool()` pair |
| `fusion_connect` | `from_tool`, `to_tool`, `to_input` | wires one tool's output into another's input; `to_input` defaults to `"Input"` |
| `fusion_set_tool_position` | `tool_name`, `xpos`, `ypos` | repositions a node in the Fusion Nodes panel (`FlowView:SetPos`) — useful for keeping a growing node graph readable |
| `fusion_delete_tool` | `tool_name` | |
| `fusion_save_tool_settings` | `tool_name`, `file_path` | serializes a tool + its upstream tree to a `.setting` file |
| `fusion_create_macro` | `tool_names` (array, ordered) | selects the given tools (order determines the resulting macro's control layout) and attempts to group them into a macro, trying a few different Fusion API entry points since behavior varies by version; reports which attempt (if any) succeeded |
| `fusion_render_preview` | `source_tool` (default `MediaOut1`), `file_path`, `frame` (optional, defaults to comp's current time) | renders one frame to a PNG/file via a reusable hidden `_ClaudeBridge_PreviewSaver` node, so you can read back the actual composite instead of relying on a screenshot |

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
