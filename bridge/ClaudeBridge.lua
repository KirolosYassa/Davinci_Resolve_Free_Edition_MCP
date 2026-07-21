--[[
ClaudeBridge.lua
=================
Free-edition-compatible bridge between Claude and DaVinci Resolve.

WHY THIS EXISTS
---------------
DaVinci Resolve Free no longer allows an external process to open a
scripting connection (the "External Scripting Using" preference has been
pulled from Free as of Resolve 19.1+). What Free still fully supports is a
script *launched from inside Resolve itself* via Workspace > Scripts — that
script gets the same full API access as an external one.

This script is that internal launch point. It does not talk to Claude over
a network socket; it reads a small command file from disk, does the work,
and writes a result file back. Claude (running in a separate session/process
that cannot reach Resolve directly) writes the command file; you trigger this
script from the Scripts menu to apply it.

INSTALL
-------
Copy this file to:
  %APPDATA%\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Utility\

Then in Resolve: Workspace > Scripts > Utility > ClaudeBridge
(appears on every page since it's under "Utility").

PROTOCOL
--------
Reads   <BRIDGE_DIR>\command.json
  { "commands": [ { "action": "<name>", "params": { ... } }, ... ] }

Writes  <BRIDGE_DIR>\result.json
  { "results": [ { "action": str, "success": bool, "data": {...} | "error": str }, ... ],
    "completed_at": "<UTC ISO8601>" }

Also archives the just-run command batch to command.processed.json so it's
obvious (to you and to Claude re-reading the folder) that it's already been
applied.

See BRIDGE_SETUP_GUIDE.md in the project root for the full action reference.
]]

-- ══════════════════════════════════════════════════════════════════════════
-- CONFIG — adjust BRIDGE_DIR if this project ever moves
-- ══════════════════════════════════════════════════════════════════════════

local BRIDGE_DIR       = "C:\\Tools\\davinci_resolve_mcp\\bridge"
local COMMAND_FILE     = BRIDGE_DIR .. "\\command.json"
local RESULT_FILE      = BRIDGE_DIR .. "\\result.json"
local PROCESSED_FILE   = BRIDGE_DIR .. "\\command.processed.json"

-- ══════════════════════════════════════════════════════════════════════════
-- Minimal self-contained JSON encode/decode (no external deps available
-- inside Resolve's Lua sandbox)
-- ══════════════════════════════════════════════════════════════════════════

local json_decode
local json_encode

do
  local function skip_ws(str, pos)
    while pos <= #str do
      local c = str:sub(pos, pos)
      if c == " " or c == "\t" or c == "\n" or c == "\r" then
        pos = pos + 1
      else
        break
      end
    end
    return pos
  end

  local function parse_string(str, pos)
    pos = pos + 1 -- skip opening quote
    local buf = {}
    while true do
      local c = str:sub(pos, pos)
      if c == "" then error("Unterminated string in JSON") end
      if c == '"' then
        pos = pos + 1
        break
      elseif c == "\\" then
        local nc = str:sub(pos + 1, pos + 1)
        if nc == "n" then buf[#buf+1] = "\n"; pos = pos + 2
        elseif nc == "t" then buf[#buf+1] = "\t"; pos = pos + 2
        elseif nc == "r" then buf[#buf+1] = "\r"; pos = pos + 2
        elseif nc == '"' then buf[#buf+1] = '"'; pos = pos + 2
        elseif nc == "\\" then buf[#buf+1] = "\\"; pos = pos + 2
        elseif nc == "/" then buf[#buf+1] = "/"; pos = pos + 2
        elseif nc == "u" then
          local hex = str:sub(pos + 2, pos + 5)
          local code = tonumber(hex, 16) or 63
          buf[#buf+1] = (code < 128) and string.char(code) or "?"
          pos = pos + 6
        else
          buf[#buf+1] = nc; pos = pos + 2
        end
      else
        buf[#buf+1] = c
        pos = pos + 1
      end
    end
    return table.concat(buf), pos
  end

  local function parse_number(str, pos)
    local start = pos
    while pos <= #str and str:sub(pos, pos):match("[%d%.%-%+eE]") do
      pos = pos + 1
    end
    return tonumber(str:sub(start, pos - 1)), pos
  end

  local parse_value

  local function parse_object(str, pos)
    pos = pos + 1 -- skip {
    local obj = {}
    pos = skip_ws(str, pos)
    if str:sub(pos, pos) == "}" then return obj, pos + 1 end
    while true do
      pos = skip_ws(str, pos)
      if str:sub(pos, pos) ~= '"' then error("Expected string key in JSON object at pos " .. pos) end
      local key, np = parse_string(str, pos)
      pos = skip_ws(str, np)
      if str:sub(pos, pos) ~= ":" then error("Expected ':' in JSON object at pos " .. pos) end
      pos = skip_ws(str, pos + 1)
      local val
      val, pos = parse_value(str, pos)
      obj[key] = val
      pos = skip_ws(str, pos)
      local c = str:sub(pos, pos)
      if c == "," then pos = pos + 1
      elseif c == "}" then pos = pos + 1; break
      else error("Expected ',' or '}' in JSON object at pos " .. pos) end
    end
    return obj, pos
  end

  local function parse_array(str, pos)
    pos = pos + 1 -- skip [
    local arr = {}
    pos = skip_ws(str, pos)
    if str:sub(pos, pos) == "]" then return arr, pos + 1 end
    while true do
      pos = skip_ws(str, pos)
      local val
      val, pos = parse_value(str, pos)
      arr[#arr+1] = val
      pos = skip_ws(str, pos)
      local c = str:sub(pos, pos)
      if c == "," then pos = pos + 1
      elseif c == "]" then pos = pos + 1; break
      else error("Expected ',' or ']' in JSON array at pos " .. pos) end
    end
    return arr, pos
  end

  parse_value = function(str, pos)
    pos = skip_ws(str, pos)
    local c = str:sub(pos, pos)
    if c == '"' then return parse_string(str, pos)
    elseif c == "{" then return parse_object(str, pos)
    elseif c == "[" then return parse_array(str, pos)
    elseif str:sub(pos, pos + 3) == "true" then return true, pos + 4
    elseif str:sub(pos, pos + 4) == "false" then return false, pos + 5
    elseif str:sub(pos, pos + 3) == "null" then return nil, pos + 4
    elseif c:match("[%d%-]") then return parse_number(str, pos)
    else error("Unexpected character '" .. c .. "' in JSON at pos " .. pos) end
  end

  json_decode = function(str)
    local pos = skip_ws(str, 1)
    local result = parse_value(str, pos)
    return result
  end
end

do
  local function json_escape(s)
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    s = s:gsub("\n", "\\n")
    s = s:gsub("\r", "\\r")
    s = s:gsub("\t", "\\t")
    return s
  end

  local function is_array(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    for i = 1, n do
      if t[i] == nil then return false, n end
    end
    return true, n
  end

  json_encode = function(v)
    local vt = type(v)
    if v == nil then
      return "null"
    elseif vt == "boolean" then
      return v and "true" or "false"
    elseif vt == "number" then
      if v ~= v then return "null" end
      return tostring(v)
    elseif vt == "string" then
      return '"' .. json_escape(v) .. '"'
    elseif vt == "table" then
      local arr, n = is_array(v)
      if arr then
        if n == 0 then return "[]" end
        local parts = {}
        for i = 1, n do parts[i] = json_encode(v[i]) end
        return "[" .. table.concat(parts, ",") .. "]"
      else
        local parts = {}
        for k, val in pairs(v) do
          parts[#parts+1] = '"' .. json_escape(tostring(k)) .. '":' .. json_encode(val)
        end
        if #parts == 0 then return "{}" end
        return "{" .. table.concat(parts, ",") .. "}"
      end
    else
      return "null"
    end
  end
end

-- ══════════════════════════════════════════════════════════════════════════
-- File helpers
-- ══════════════════════════════════════════════════════════════════════════

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

local function write_file(path, content)
  local f = io.open(path, "w")
  if not f then error("Could not open '" .. path .. "' for writing.") end
  f:write(content)
  f:close()
end

local function table_count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

-- ══════════════════════════════════════════════════════════════════════════
-- Resolve accessor helpers (mirrors server.py's _p() / _tl())
-- ══════════════════════════════════════════════════════════════════════════

local function proj()
  local p = resolve:GetProjectManager():GetCurrentProject()
  if not p then
    error("No project is open in DaVinci Resolve. Open or create a project first.")
  end
  return p
end

local function timeline()
  local t = proj():GetCurrentTimeline()
  if not t then
    error("No timeline is active. Open or create a timeline first.")
  end
  return t
end

local function need(params, key)
  local v = params[key]
  if v == nil then error("Missing required field: '" .. key .. "'") end
  return v
end

-- Shared by import_banner_images / clear_bin / list_media_pool / refresh_bin_clips
-- (added 2026-07-21, factored out to avoid duplicating this lookup four times).
-- Finds an existing root-level Media Pool subfolder with the given name.
-- Returns the folder, or nil if not found (caller decides whether that's an
-- error or a "create it" signal).
local function find_bin_by_name(mp, bin_name)
  local root = mp:GetRootFolder()
  if not root then error("Could not get the Media Pool's root folder.") end
  local subfolders = root:GetSubFolderList() or {}
  for _, f in ipairs(subfolders) do
    local ok, fname = pcall(function() return f:GetName() end)
    if ok and fname == bin_name then return f end
  end
  return nil
end

-- ══════════════════════════════════════════════════════════════════════════
-- Actions — one entry per supported command, matching server.py's
-- resolve_* tool names minus the "resolve_" prefix
-- ══════════════════════════════════════════════════════════════════════════

local VALID_PAGES = {
  cut = true, edit = true, fusion = true, color = true,
  fairlight = true, deliver = true, media = true,
}

local ACTIONS = {}

ACTIONS.get_info = function(_)
  return {
    product_name = resolve:GetProductName(),
    version      = resolve:GetVersionString(),
    current_page = resolve:GetCurrentPage(),
  }
end

ACTIONS.open_page = function(params)
  local page = tostring(need(params, "page")):lower()
  if not VALID_PAGES[page] then
    error("Invalid page '" .. page .. "'. Valid: cut, edit, fusion, color, fairlight, deliver, media")
  end
  local ok = resolve:OpenPage(page)
  return { success = ok and true or false, current_page = resolve:GetCurrentPage() }
end

ACTIONS.list_projects = function(_)
  local pm = resolve:GetProjectManager()
  local projects = pm:GetProjectListInCurrentFolder() or {}
  local current = pm:GetCurrentProject()
  return {
    projects = projects,
    current_project = current and current:GetName() or nil,
    current_folder = pm:GetCurrentFolder(),
  }
end

ACTIONS.get_project_info = function(_)
  local p = proj()
  return { name = p:GetName(), timeline_count = p:GetTimelineCount() }
end

ACTIONS.get_project_settings = function(params)
  local p = proj()
  local key = params.setting_name
  if key and key ~= "" then
    return { setting = key, value = p:GetSetting(key) }
  end
  return { settings = p:GetSetting() or {} }
end

-- NOTE (2026-07-21): `resolve:GetPreferences()`/`SetPreferences()` do NOT
-- exist on this Resolve version's `resolve` object (confirmed live: "attempt
-- to call method 'GetPreferences' (a nil value)") — don't re-guess this path
-- for app-level settings. The still-duration fix that actually worked is
-- MediaPoolItem:SetMarkInOut(), documented on place_clip_on_track below.

ACTIONS.list_timelines = function(_)
  local p = proj()
  local count = p:GetTimelineCount()
  local current = p:GetCurrentTimeline()
  local timelines = {}
  for i = 1, count do
    local t = p:GetTimelineByIndex(i)
    if t then
      timelines[#timelines+1] = {
        index = i,
        name = t:GetName(),
        start_frame = t:GetStartFrame(),
        end_frame = t:GetEndFrame(),
        video_tracks = t:GetTrackCount("video"),
        audio_tracks = t:GetTrackCount("audio"),
      }
    end
  end
  return {
    current_timeline = current and current:GetName() or nil,
    timelines = timelines,
  }
end

ACTIONS.get_timeline_info = function(_)
  local t = timeline()
  -- frame_rate added 2026-07-21 for the HTML-timestamp-driven banner
  -- placement workflow: converting a chapter's mm:ss into an absolute
  -- Resolve frame number needs both this AND start_frame (already returned
  -- above) — Resolve's frame numbering starts at whatever timecode the
  -- timeline itself starts at (commonly 01:00:00:00, NOT 00:00:00:00 like
  -- most other NLEs), so start_frame already encodes that offset; frame_rate
  -- is the missing piece to turn seconds into a frame count. Wrapped in
  -- pcall so a lookup failure doesn't break the rest of this action's
  -- existing, already-working fields.
  local frame_rate = nil
  local ok, val = pcall(function() return t:GetSetting("timelineFrameRate") end)
  if ok then frame_rate = tonumber(val) end
  return {
    name = t:GetName(),
    start_frame = t:GetStartFrame(),
    end_frame = t:GetEndFrame(),
    current_timecode = t:GetCurrentTimecode(),
    video_tracks = t:GetTrackCount("video"),
    audio_tracks = t:GetTrackCount("audio"),
    frame_rate = frame_rate,
  }
end

ACTIONS.create_timeline = function(params)
  local name = need(params, "name")
  local t = proj():GetMediaPool():CreateEmptyTimeline(name)
  if not t then
    error("Could not create timeline '" .. name .. "'. It may already exist.")
  end
  return { success = true, timeline_name = t:GetName() }
end

ACTIONS.set_current_timeline = function(params)
  local name = params.timeline_name
  local index = params.timeline_index
  if not name and not index then
    error("Provide either 'timeline_name' or 'timeline_index'.")
  end
  local p = proj()
  local count = p:GetTimelineCount()
  local target = nil
  if name then
    for i = 1, count do
      local t = p:GetTimelineByIndex(i)
      if t and t:GetName() == name then target = t; break end
    end
    if not target then
      error("Timeline '" .. name .. "' not found. Use list_timelines to see all timelines.")
    end
  else
    target = p:GetTimelineByIndex(index)
    if not target then error("No timeline at index " .. tostring(index) .. ".") end
  end
  local ok = p:SetCurrentTimeline(target)
  return { success = ok and true or false, timeline_name = target:GetName() }
end

-- Added 2026-07-21 for the banner-placement workflow: the locked rule here is
-- "always add a new video track above the current topmost one" rather than
-- hunting for/reusing an existing track that might already have clips on it
-- further down the timeline (confirmed live: a track looked empty in the
-- visible window but had clips further along) — a fresh top track
-- can never conflict with anything already there. Resolve's AddTrack always
-- appends a new track at the END of that type's list, and for video tracks
-- higher numbers render ON TOP of lower ones, so the new track is both the
-- newest and the topmost automatically — no explicit "insert above" call
-- needed. Returns the before/after count so the caller can confirm the new
-- track's index (= count_after) without a second round-trip.
ACTIONS.add_track = function(params)
  local track_type = params.track_type or "video"
  if track_type ~= "video" and track_type ~= "audio" and track_type ~= "subtitle" then
    error("track_type must be 'video', 'audio', or 'subtitle'.")
  end
  local t = timeline()
  local before = t:GetTrackCount(track_type)
  local ok = t:AddTrack(track_type)
  local after = t:GetTrackCount(track_type)
  return {
    success = ok and true or false,
    track_type = track_type,
    count_before = before,
    count_after = after,
    new_track_index = after,
  }
end

ACTIONS.get_timeline_items = function(params)
  local track_type = (params.track_type or "video")
  local track_index = params.track_index or 1
  if track_type ~= "video" and track_type ~= "audio" then
    error("track_type must be 'video' or 'audio'.")
  end
  local t = timeline()
  local items = t:GetItemListInTrack(track_type, track_index)
  if items == nil then
    error(track_type .. " track " .. tostring(track_index) .. " does not exist. Use get_timeline_info to check track counts.")
  end
  local result = {}
  for _, item in ipairs(items) do
    result[#result+1] = {
      name = item:GetName(),
      start = item:GetStart(),
      ["end"] = item:GetEnd(),
      duration = item:GetDuration(),
      source_start = item:GetSourceStartFrame(),
      source_end = item:GetSourceEndFrame(),
    }
  end
  return { track_type = track_type, track_index = track_index, count = #result, items = result }
end

-- Added 2026-07-21 to clean up after the still-duration placement bug (see
-- place_clip_on_track) — lets a bad batch of placed clips be wiped and
-- redone cleanly instead of leaving duplicates behind.
ACTIONS.delete_timeline_items = function(params)
  local track_type = params.track_type or "video"
  local track_index = need(params, "track_index")
  local t = timeline()
  local items = t:GetItemListInTrack(track_type, track_index)
  if items == nil or #items == 0 then
    return { success = true, deleted_count = 0 }
  end
  local ok = t:DeleteClips(items)
  return { success = ok and true or false, deleted_count = #items }
end

ACTIONS.get_timecode = function(_)
  return { timecode = timeline():GetCurrentTimecode() }
end

ACTIONS.set_timecode = function(params)
  local tc = need(params, "timecode")
  local ok = timeline():SetCurrentTimecode(tc)
  return { success = ok and true or false, timecode = tc }
end

ACTIONS.add_marker = function(params)
  local frame_id = need(params, "frame_id")
  local color = params.color or "Blue"
  local name = params.name or ""
  local note = params.note or ""
  local duration = params.duration or 1
  local custom_data = params.custom_data or ""
  local ok = timeline():AddMarker(frame_id, color, name, note, duration, custom_data)
  return { success = ok and true or false, frame_id = frame_id, color = color, name = name }
end

ACTIONS.get_markers = function(_)
  local markers = timeline():GetMarkers() or {}
  return { count = table_count(markers), markers = markers }
end

ACTIONS.delete_marker = function(params)
  local frame_num = need(params, "frame_num")
  local ok = timeline():DeleteMarkerAtFrame(frame_num)
  return { success = ok and true or false, frame_num = frame_num }
end

-- bin_name is optional (added 2026-07-21): if given, lists that root-level
-- bin's contents without needing it to be the currently active folder.
ACTIONS.list_media_pool = function(params)
  local mp = proj():GetMediaPool()
  local bin_name = params.bin_name
  local folder

  if bin_name then
    folder = find_bin_by_name(mp, bin_name)
    if not folder then
      error("No Media Pool bin named '" .. bin_name .. "' found at the root level.")
    end
  else
    folder = mp:GetCurrentFolder()
  end

  local clips = folder:GetClipList() or {}
  local result = {}
  for _, c in ipairs(clips) do
    local function prop(key)
      local ok, v = pcall(function() return c:GetClipProperty(key) end)
      if ok then return v end
      return nil
    end
    result[#result+1] = {
      name = c:GetName(),
      type = prop("Type"),
      duration = prop("Duration"),
      fps = prop("FPS"),
      file_path = prop("File Path"),
    }
  end
  return { folder = folder:GetName(), count = #result, clips = result }
end

-- Deletes every clip currently in a named root-level Media Pool bin (or the
-- current folder if bin_name is omitted). Added 2026-07-21 to clean up a
-- stray auto-stitched image-sequence clip during the banner-naming rework --
-- generally useful any time a bin needs to be reset before a clean re-import.
ACTIONS.clear_bin = function(params)
  local bin_name = params.bin_name
  local mp = proj():GetMediaPool()
  local folder

  if bin_name then
    folder = find_bin_by_name(mp, bin_name)
    if not folder then
      error("No Media Pool bin named '" .. bin_name .. "' found at the root level.")
    end
  else
    folder = mp:GetCurrentFolder()
  end

  local clips = folder:GetClipList() or {}
  if #clips == 0 then
    return { success = true, bin_name = folder:GetName(), deleted_count = 0 }
  end

  local ok = mp:DeleteClips(clips)
  return { success = ok and true or false, bin_name = folder:GetName(), deleted_count = #clips }
end

-- ══════════════════════════════════════════════════════════════════════════
-- Refresh already-placed banners in place (added 2026-07-21)
--
-- Why this exists: the whole point of a stable "<PREFIX>_<seq>.png" filename
-- convention (see import_banner_images) is that a user can regenerate a
-- banner's PNG at the exact same path and have it show up correctly on the
-- timeline WITHOUT re-importing or re-placing -- because by the time a
-- banner has already been placed once, the editor will likely have manually
-- repositioned/retrimmed/reordered it on the timeline, and re-running
-- delete_timeline_items + place_clip_on_track would silently blow away that
-- manual work. Discarding a user's manual edits just to swap in new pixels
-- is exactly the failure mode this action exists to avoid.
--
-- The fix is NOT to touch the timeline at all. MediaPoolItem:ReplaceClip(path)
-- replaces a MediaPoolItem's underlying source asset in place -- every
-- TimelineItem that already references this MediaPoolItem picks up the new
-- pixels automatically, with its position/duration/trim on the timeline
-- completely untouched, because ReplaceClip only swaps what the existing
-- MediaPoolItem points to on disk; it does not create a new MediaPoolItem or
-- touch the timeline at all.
--
-- Since the path is not actually changing (same filename, just overwritten
-- content), ReplaceClip is called with the clip's own current "File Path" --
-- its purpose here is purely to invalidate Resolve's cached thumbnail/frame
-- for that still so it re-reads the file from disk.
ACTIONS.refresh_bin_clips = function(params)
  local bin_name = need(params, "bin_name")
  local file_paths = params.file_paths  -- optional: only refresh these (by path); omit to refresh the whole bin
  local mp = proj():GetMediaPool()

  local folder = find_bin_by_name(mp, bin_name)
  if not folder then
    error("No Media Pool bin named '" .. bin_name .. "' found at the root level.")
  end

  local wanted = nil
  if file_paths then
    wanted = {}
    for _, p in ipairs(file_paths) do wanted[p] = true end
  end

  local clips = folder:GetClipList() or {}
  local refreshed = {}
  local failed = {}
  local skipped = 0

  for _, c in ipairs(clips) do
    local ok_path, path = pcall(function() return c:GetClipProperty("File Path") end)
    if not ok_path or not path or path == "" then
      failed[#failed+1] = { name = c:GetName(), error = "Could not read this clip's File Path property." }
    elseif wanted and not wanted[path] then
      skipped = skipped + 1
    else
      local ok_replace, replace_result = pcall(function() return c:ReplaceClip(path) end)
      if ok_replace and replace_result then
        refreshed[#refreshed+1] = { name = c:GetName(), file_path = path }
      else
        failed[#failed+1] = { name = c:GetName(), file_path = path, error = tostring(replace_result) }
      end
    end
  end

  return {
    success = #failed == 0,
    bin_name = folder:GetName(),
    refreshed_count = #refreshed,
    refreshed = refreshed,
    skipped_count = skipped,
    failed_count = #failed,
    failed = failed,
  }
end

ACTIONS.import_media = function(params)
  local paths = need(params, "file_paths")
  local mp = proj():GetMediaPool()
  local imported = mp:ImportMedia(paths)
  if not imported or #imported == 0 then
    error("No files were imported. Verify that all paths exist and are in a supported format.")
  end
  local names = {}
  for _, c in ipairs(imported) do
    if c then names[#names+1] = c:GetName() end
  end
  return { success = true, imported_count = #names, imported_clips = names }
end

ACTIONS.create_bin = function(params)
  local name = need(params, "name")
  local mp = proj():GetMediaPool()
  local new_folder = mp:AddSubFolder(mp:GetCurrentFolder(), name)
  if not new_folder then error("Failed to create bin '" .. name .. "'.") end
  return { success = true, bin_name = new_folder:GetName() }
end

ACTIONS.append_to_timeline = function(params)
  local clip_names = need(params, "clip_names")
  local mp = proj():GetMediaPool()
  local folder = mp:GetCurrentFolder()
  local clip_list = folder:GetClipList() or {}
  local clip_map = {}
  for _, c in ipairs(clip_list) do clip_map[c:GetName()] = c end

  local to_add, missing = {}, {}
  for _, name in ipairs(clip_names) do
    if clip_map[name] then to_add[#to_add+1] = name else missing[#missing+1] = name end
  end
  if #missing > 0 then
    error("Clips not found in Media Pool: " .. table.concat(missing, ", ") .. ". Use list_media_pool to see available clips.")
  end

  local result = mp:AppendToTimeline(to_add)
  return { success = result ~= nil, appended_count = result and #result or 0 }
end

-- ══════════════════════════════════════════════════════════════════════════
-- Banner / Overlay Image Placement (marker-driven or timestamp-driven,
-- added 2026-07-21)
--
-- General workflow: for marker-driven placement, the user places a single
-- marker color on the timeline as "drop a banner here" cut points, plus one
-- extra closing marker (any color) after the last drop point, so the final
-- banner has an end boundary ("until the next marker"). Call order in ONE
-- command.json batch:
--   get_markers_by_color -> import_banner_images -> place_clip_on_track (once
--   per marker). import_banner_images and place_clip_on_track MUST be in the
--   same batch — like the Fusion tool cache above, _imported_clips only
--   lives for a single script execution, not across separate triggers.
-- UNVERIFIED as of first write: AppendToTimeline's extended clipInfo table
-- form (mediaPoolItem/startFrame/endFrame/recordFrame/trackIndex) has never
-- been called from this bridge before — only the plain clip_names form
-- (see append_to_timeline above) has been confirmed live. Watch result.json
-- closely and cross-check against the actual Resolve timeline before
-- trusting a "success" here, per the project's standing "applied != worked"
-- rule.
-- ══════════════════════════════════════════════════════════════════════════

local _imported_clips = {}

-- Returns every marker of the requested color, sorted left-to-right by
-- frame, each annotated with `end_frame` = the frame of the very next
-- marker on the timeline (ANY color, including the user's closing marker) —
-- so callers get "until the next marker" placement math for free instead of
-- re-deriving it from the raw get_markers table. `end_frame` is nil for a
-- drop marker with nothing after it at all; treat that as missing the
-- required closing marker, not as "runs to end of timeline" — stop and ask
-- rather than guessing a duration.
ACTIONS.get_markers_by_color = function(params)
  local color = need(params, "color")
  local all_markers = timeline():GetMarkers() or {}

  -- Flatten to a sorted-by-frame array first (GetMarkers returns a table
  -- keyed by frame number; pairs() iteration order is not guaranteed).
  local all_frames = {}
  for frame_id, _ in pairs(all_markers) do
    all_frames[#all_frames+1] = frame_id
  end
  table.sort(all_frames)

  local matches = {}
  for _, frame_id in ipairs(all_frames) do
    local m = all_markers[frame_id]
    if m.color == color then
      matches[#matches+1] = { frame = frame_id, name = m.name, note = m.note, duration = m.duration }
    end
  end

  for _, entry in ipairs(matches) do
    local end_frame = nil
    for _, frame_id in ipairs(all_frames) do
      if frame_id > entry.frame then
        end_frame = frame_id
        break
      end
    end
    entry.end_frame = end_frame
  end

  return { color = color, count = #matches, markers = matches }
end

-- Imports an ordered list of banner PNGs and caches the resulting
-- MediaPoolItem objects by INPUT order (not whatever order ImportMedia's
-- return happens to use, which isn't documented as stable) so
-- place_clip_on_track can address them by index later in the same batch.
-- Re-derives order by matching each returned clip's "File Path" property
-- back against the input list.
-- Optional bin_name (added 2026-07-21): banner PNGs can be routed directly
-- into a Media Pool bin named after a logical group (e.g. a project or
-- system name), mirroring the folder structure they were generated into --
-- rather than always landing in whatever bin happens to be currently active
-- in Resolve. Finds an existing
-- root-level subfolder with that exact name, or creates one, then switches
-- the Media Pool's current folder to it before importing. If bin_name is
-- omitted, behavior is unchanged (imports into whatever folder is current).
ACTIONS.import_banner_images = function(params)
  local file_paths = need(params, "file_paths")
  local bin_name = params.bin_name
  local mp = proj():GetMediaPool()

  if bin_name then
    local target = find_bin_by_name(mp, bin_name)
    if not target then
      target = mp:AddSubFolder(mp:GetRootFolder(), bin_name)
      if not target then
        error("Failed to find or create a Media Pool bin named '" .. bin_name .. "' at the root level.")
      end
    end

    local switched = mp:SetCurrentFolder(target)
    if not switched then
      error("Found/created bin '" .. bin_name .. "' but could not switch the Media Pool's current folder to it.")
    end
  end

  -- IMPORTANT (discovered 2026-07-21, after switching to plain sequential
  -- filenames like SCF_01.png, SCF_02.png, ...): passing a plain array of
  -- file path strings to ImportMedia lets Resolve's own "detect image
  -- sequence" heuristic kick in -- it silently merged all 13 banner PNGs
  -- into ONE stitched clip named "SCF_[01-13].png" instead of 13 separate
  -- MediaPoolItems, which then made every by-path re-match below fail
  -- (confirmed via result.json, not guessed). Fix: pass each file as its
  -- own clipInfo table ({FilePath=...}, no StartIndex/EndIndex) instead of
  -- a bare string -- this tells Resolve each entry is one explicit still,
  -- not a browsable sequence, and produces one MediaPoolItem per PNG.
  -- Two earlier attempts on 2026-07-21 both failed and were confirmed
  -- failed via result.json (not guessed): {FilePath=p} alone, and
  -- {FilePath=p, StartIndex=0, EndIndex=0} both made ImportMedia return an
  -- empty list -- this Resolve version's Lua binding doesn't accept the
  -- clipInfo-dict overload the way the docs describe.
  -- Working fix: import file paths ONE AT A TIME (a single-element array
  -- per ImportMedia call) instead of the whole list in one call. Resolve's
  -- image-sequence auto-detection groups consecutively-numbered stills that
  -- are imported TOGETHER in the same call; importing each PNG in its own
  -- call gives it nothing to group with, so SCF_01.png, SCF_02.png, ...
  -- land as separate MediaPoolItems instead of one stitched
  -- "SCF_[01-13].png" sequence clip.
  local imported = {}
  for _, p in ipairs(file_paths) do
    local single = mp:ImportMedia({ p })
    if single and #single > 0 then
      imported[#imported+1] = single[1]
    end
  end
  if #imported == 0 then
    error("No banner images were imported. Verify every path in file_paths exists.")
  end

  local by_path = {}
  for _, c in ipairs(imported) do
    local ok, path = pcall(function() return c:GetClipProperty("File Path") end)
    if ok and path then by_path[path] = c end
  end

  _imported_clips = {}
  local result = {}
  local missing = {}
  for i, path in ipairs(file_paths) do
    local clip = by_path[path]
    if clip then
      _imported_clips[i] = clip
      result[#result+1] = { index = i, file_path = path, clip_name = clip:GetName() }
    else
      missing[#missing+1] = path
    end
  end

  if #missing > 0 then
    error("Imported but could not re-match by file path (order would be unreliable): " .. table.concat(missing, ", "))
  end

  return { success = true, count = #result, imported = result, bin_name = bin_name }
end

-- Places one already-imported banner (by its 1-based index from
-- import_banner_images, same batch) onto a specific video track at an
-- exact timeline frame, trimmed to run through end_frame - 1 (i.e. up to
-- but not including the next marker — "until the next marker"). Uses
-- MediaPool:AppendToTimeline's extended clipInfo table form (NOT the plain
-- clip_names form the existing append_to_timeline action uses) since only
-- that form accepts an explicit recordFrame/trackIndex — the plain form
-- just appends sequentially after whatever's already on the track.
ACTIONS.place_clip_on_track = function(params)
  local clip_index = need(params, "clip_index")
  local track_index = need(params, "track_index")
  local start_frame = need(params, "start_frame")
  local end_frame = need(params, "end_frame")

  local clip = _imported_clips[clip_index]
  if not clip then
    error("No imported clip cached at index " .. tostring(clip_index) .. ". Run import_banner_images first, in this same batch.")
  end

  local duration = end_frame - start_frame
  if duration <= 0 then
    error("end_frame (" .. tostring(end_frame) .. ") must be after start_frame (" .. tostring(start_frame) .. ").")
  end

  -- CONFIRMED BUG + REAL FIX (2026-07-21, live-tested end to end). A still
  -- image's native source is exactly 1 frame (GetClipProperty("Duration")
  -- reads "00:00:00:01") — AppendToTimeline's clipInfo startFrame/endFrame
  -- get silently clamped against that native 1-frame range for a still, so
  -- every placed clip landed at a fixed default (observed: 150 frames / 5s
  -- @ 30fps) regardless of the endFrame requested here. TWO failed attempts
  -- before this one, kept as history: (1) `timelineItem:SetEnd()` errored
  -- loudly — no such method on a TimelineItem in this API. (2)
  -- `mediaPoolItem:SetClipProperty("Duration", ...)` — tried both a plain
  -- frame-count string and a timecode string — reported success but was a
  -- pure no-op (GetClipProperty("Duration") read back unchanged both
  -- times); "Duration" is a read-only/computed display property for
  -- stills, not a real lever. THE ACTUAL FIX: `MediaPoolItem:SetMarkInOut
  -- (inFrame, outFrame)` sets the clip's genuine usable in/out range —
  -- confirmed live: after `SetMarkInOut(0, 209)`, the placed TimelineItem's
  -- GetDuration() read back as exactly 210, matching the request. Must run
  -- BEFORE AppendToTimeline so the clipInfo endFrame below has real range
  -- to trim within instead of being clamped.
  -- NOTE: clip_info deliberately does NOT also set startFrame/endFrame —
  -- confirmed live that doing so ON TOP OF SetMarkInOut produces a
  -- consistent 1-frame-short result (e.g. asked for 210, got 209) across
  -- all 13 clips in a batch, even though SetMarkInOut alone (no clipInfo
  -- startFrame/endFrame at all) landed the exact right duration in an
  -- isolated single-clip test. Redundantly re-specifying the same range in
  -- clipInfo conflicts with the mark in/out rather than reinforcing it —
  -- let AppendToTimeline use the full marked range on its own.
  local mark_ok, mark_err = pcall(function() clip:SetMarkInOut(0, duration - 1) end)
  if not mark_ok then
    error("SetMarkInOut failed for clip_index " .. tostring(clip_index) .. ": " .. tostring(mark_err))
  end

  local clip_info = {
    {
      mediaPoolItem = clip,
      recordFrame = start_frame,
      trackIndex = track_index,
      mediaType = 1, -- video
    }
  }

  local mp = proj():GetMediaPool()
  local result = mp:AppendToTimeline(clip_info)
  local appended = result ~= nil and #result > 0

  local final_duration = nil
  if appended then
    local ok, val = pcall(function() return result[1]:GetDuration() end)
    if ok then final_duration = val end
  end

  return {
    success = appended,
    clip_index = clip_index,
    track_index = track_index,
    start_frame = start_frame,
    end_frame = end_frame,
    duration = duration,
    final_duration = final_duration,
  }
end

-- ══════════════════════════════════════════════════════════════════════════
-- Fusion Compositing (ported from server.py's resolve_fusion_* tools)
--
-- Prerequisite for every action below: fusion_get_comp must run first in the
-- SAME command.json batch (state doesn't persist between separate triggers —
-- each run of this script is a fresh Lua process). So a Fusion job is always
-- [fusion_get_comp, ...build steps...] queued together in one command.json.
--
-- Like server.py's equivalents, these are best-effort against the documented
-- Fusion scripting API — exact input names/enum values can vary by Resolve
-- version and are NOT yet confirmed live. Test incrementally.
-- ══════════════════════════════════════════════════════════════════════════

local _fusion_comp = nil
local _fusion_tools = {}

local function fcomp()
  if _fusion_comp == nil then
    error("No Fusion composition attached. Run fusion_get_comp first, in the same command batch.")
  end
  return _fusion_comp
end

local function ftool(name)
  if _fusion_tools[name] ~= nil then return _fusion_tools[name] end
  local comp = fcomp()
  for _, t in pairs(comp:GetToolList(false) or {}) do
    if t:GetAttrs()["TOOLS_Name"] == name then
      _fusion_tools[name] = t
      return t
    end
  end
  error("No Fusion tool named '" .. tostring(name) .. "'. Use fusion_list_tools to see what exists.")
end

ACTIONS.fusion_get_comp = function(params)
  local track_index = params.track_index or 1
  local clip_index = params.clip_index or 0
  local create_if_missing = params.create_if_missing
  if create_if_missing == nil then create_if_missing = true end

  local t = timeline()
  local items = t:GetItemListInTrack("video", track_index)
  if not items or not items[clip_index + 1] then
    error("Clip at video track " .. tostring(track_index) .. ", index " .. tostring(clip_index) .. " not found.")
  end
  local clip = items[clip_index + 1]
  local comp = clip:GetFusionCompByIndex(1)
  if not comp then
    if not create_if_missing then
      error("Clip has no Fusion composition yet. Call again with create_if_missing=true.")
    end
    comp = clip:AddFusionComp()
    if not comp then error("Failed to create a Fusion composition on this clip.") end
  end

  _fusion_comp = comp
  _fusion_tools = {}
  local names = {}
  for _, tl_tool in pairs(comp:GetToolList(false) or {}) do
    local n = tl_tool:GetAttrs()["TOOLS_Name"]
    if n then
      _fusion_tools[n] = tl_tool
      names[#names+1] = n
    end
  end
  return { success = true, clip_name = clip:GetName(), existing_tools = names }
end

-- Added for the Planar Tracker / Corner Pin investigation (2026-07-20).
-- fusion_get_comp requires guessing a timeline track/clip index, which
-- doesn't work when the open clip's name doesn't match anything in the
-- "current timeline" the API reports (e.g. multiple timelines open).
-- This grabs whatever comp is actually loaded in the Fusion page right
-- now, regardless of which timeline/clip it came from.
ACTIONS.fusion_get_current_comp = function(_)
  local fu = resolve:Fusion()
  if not fu then
    error("Could not access the Fusion object (resolve:Fusion() returned nil).")
  end
  local comp = fu:GetCurrentComp()
  if not comp then
    error("No composition is currently open in the Fusion page.")
  end
  _fusion_comp = comp
  _fusion_tools = {}
  local names = {}
  for _, tl_tool in pairs(comp:GetToolList(false) or {}) do
    local n = tl_tool:GetAttrs()["TOOLS_Name"]
    if n then
      _fusion_tools[n] = tl_tool
      names[#names+1] = n
    end
  end
  return { success = true, existing_tools = names }
end

-- Added for the Planar Tracker investigation (2026-07-20). Plain
-- fusion_set_inputs calls tool:SetInput(key, value) with no time argument
-- — for a parameter that ISN'T YET keyframed, Fusion treats that as
-- setting one constant value for ALL time, not a per-frame correction.
-- Confirmed live: a CornerPin1 offset fixed one frame's chroma fringe but
-- not another's, because it was overwriting the single static value
-- rather than adding a keyframe. This variant passes an explicit time to
-- tool:SetInput(key, value, time), which creates/updates a real keyframe
-- at that frame and auto-converts the input to animated if it wasn't
-- already — the correct mechanism for a frame-specific manual correction.
-- Reads a tool's input value AT A SPECIFIC TIME (tool:GetInput(key, time))
-- without moving the comp's actual playhead — needed to snapshot the
-- PlanarTracker's live per-frame tracked corner values across many frames
-- in one round-trip, before overwriting them with manual keyframes.
ACTIONS.fusion_get_inputs_at_time = function(params)
  local tool_name = need(params, "tool_name")
  local keys = need(params, "keys")
  local time = need(params, "time")
  local tool = ftool(tool_name)
  local values, failed = {}, {}
  for _, key in ipairs(keys) do
    local ok, result = pcall(function() return tool:GetInput(key, time) end)
    if ok then
      values[key] = result
    else
      failed[key] = tostring(result)
    end
  end
  return {
    success = table_count(failed) == 0,
    tool_name = tool_name,
    time = time,
    values = values,
    failed = failed,
  }
end

ACTIONS.fusion_set_inputs_at_time = function(params)
  local tool_name = need(params, "tool_name")
  local inputs = need(params, "inputs")
  local time = need(params, "time")
  local tool = ftool(tool_name)
  local applied, failed = {}, {}
  for key, value in pairs(inputs) do
    local ok, err = pcall(function() tool:SetInput(key, value, time) end)
    if ok then
      applied[#applied+1] = key
    else
      failed[key] = tostring(err)
    end
  end
  return {
    success = table_count(failed) == 0,
    tool_name = tool_name,
    time = time,
    applied = applied,
    failed = failed,
  }
end

-- Added for the Planar Tracker investigation (2026-07-20). Guessing input
-- IDs via fusion_get_connections' field-access idiom (tool[key]) is
-- unreliable for tools whose input names aren't "Foreground"/"Background"/
-- "Input" (PlanarTracker in Corner Pin mode is one such case) — this
-- enumerates every real input ID on a tool via GetInputList(), plus
-- whatever's wired into each one.
ACTIONS.fusion_list_inputs = function(params)
  local tool_name = need(params, "tool_name")
  local tool = ftool(tool_name)
  local result = {}
  local ok, err = pcall(function()
    for _, inp in pairs(tool:GetInputList() or {}) do
      local attrs = inp:GetAttrs() or {}
      local out = inp:GetConnectedOutput()
      local connected_from = nil
      if out then
        local src_tool = out.GetTool and out:GetTool() or nil
        connected_from = src_tool and src_tool:GetAttrs()["TOOLS_Name"] or nil
      end
      result[#result+1] = {
        id = attrs["INPS_ID"],
        name = attrs["INPS_Name"],
        connected = out ~= nil,
        connected_from = connected_from,
      }
    end
  end)
  if not ok then
    error("Failed to enumerate inputs for '" .. tool_name .. "': " .. tostring(err))
  end
  return { success = true, tool_name = tool_name, inputs = result }
end

ACTIONS.fusion_list_tools = function(_)
  local comp = fcomp()
  local result = {}
  for _, t in pairs(comp:GetToolList(false) or {}) do
    local attrs = t:GetAttrs()
    result[#result+1] = { name = attrs["TOOLS_Name"], id = attrs["TOOLS_RegID"] }
  end
  return { count = #result, tools = result }
end

ACTIONS.fusion_add_tool = function(params)
  local tool_id = need(params, "tool_id")
  local name = need(params, "name")
  local xpos = params.xpos or 0
  local ypos = params.ypos or 0
  local comp = fcomp()
  local tool = comp:AddTool(tool_id, xpos, ypos)
  if not tool then
    error("Fusion rejected tool_id '" .. tool_id .. "'. IDs are case-sensitive — check it against the Fusion Effects list.")
  end
  tool:SetAttrs({ TOOLS_Name = name })
  _fusion_tools[name] = tool
  return { success = true, name = name, tool_id = tool_id }
end

ACTIONS.fusion_set_inputs = function(params)
  local tool_name = need(params, "tool_name")
  local inputs = need(params, "inputs")
  local tool = ftool(tool_name)
  local applied, failed = {}, {}
  for key, value in pairs(inputs) do
    local ok, err = pcall(function() tool:SetInput(key, value) end)
    if ok then
      applied[#applied+1] = key
    else
      failed[key] = tostring(err)
    end
  end
  return {
    success = table_count(failed) == 0,
    tool_name = tool_name,
    applied = applied,
    failed = failed,
  }
end

ACTIONS.fusion_connect = function(params)
  local from_tool = need(params, "from_tool")
  local to_tool = need(params, "to_tool")
  local to_input = params.to_input or "Input"
  local src = ftool(from_tool)
  local dst = ftool(to_tool)
  dst:SetInput(to_input, src)
  return { success = true }
end

ACTIONS.fusion_delete_tool = function(params)
  local tool_name = need(params, "tool_name")
  local tool = ftool(tool_name)
  tool:Delete()
  _fusion_tools[tool_name] = nil
  return { success = true }
end

ACTIONS.fusion_save_tool_settings = function(params)
  local tool_name = need(params, "tool_name")
  local file_path = need(params, "file_path")
  local tool = ftool(tool_name)
  local ok = tool:SaveSettings(file_path)
  return { success = ok and true or false, file_path = file_path }
end

-- Added 2026-07-13 (session 4, node-graph readability pass). Moves a tool's
-- icon in the Fusion Flow view — cosmetic only, has zero effect on render
-- output or wiring. Distinct from fusion_add_tool's xpos/ypos, which only
-- apply once at creation time (and were never actually used — every tool
-- built so far defaulted to (0,0), which is why the flow view is currently
-- an unreadable stack).
-- FIRST ATTEMPT (failed loudly, not silently): `tool:SetPos({x,y})` errored
-- "attempt to call method 'SetPos' (a nil value)" on all 132 calls — SetPos
-- is not a method on the Tool object in this Fusion build. CORRECTED: the
-- real API puts flow positioning on the comp's FlowView object instead —
-- `comp.CurrentFrame.FlowView:SetPos(tool, {x,y})`. Still unverified as of
-- this second write; watch result.json closely on the next run.
ACTIONS.fusion_set_tool_position = function(params)
  local tool_name = need(params, "tool_name")
  local xpos = need(params, "xpos")
  local ypos = need(params, "ypos")
  local tool = ftool(tool_name)
  local comp = fcomp()
  local ok, err = pcall(function()
    local flow = comp.CurrentFrame.FlowView
    flow:SetPos(tool, { xpos, ypos })
  end)
  if not ok then
    error("SetPos failed for '" .. tool_name .. "': " .. tostring(err))
  end
  return { success = true, tool_name = tool_name, xpos = xpos, ypos = ypos }
end

-- ── Self-verification additions (2026-07-13) ────────────────────────────
-- Added so Claude can confirm its own work (exact param values already on
-- a tool, and a rendered preview frame) instead of relying on a user
-- screenshot every round. Mirrors fusion_set_inputs' per-key error
-- isolation and reuses the same tool cache/lookup.

ACTIONS.fusion_get_inputs = function(params)
  local tool_name = need(params, "tool_name")
  local keys = need(params, "keys")
  local tool = ftool(tool_name)
  local values, failed = {}, {}
  for _, key in ipairs(keys) do
    local ok, result = pcall(function() return tool:GetInput(key) end)
    if ok then
      values[key] = result
    else
      failed[key] = tostring(result)
    end
  end
  return {
    success = table_count(failed) == 0,
    tool_name = tool_name,
    values = values,
    failed = failed,
  }
end

-- Added 2026-07-13 (session 4) specifically to unblock the L7 banner-text
-- mystery: fusion_get_inputs only confirms static parameter VALUES stuck
-- (StyledText, Center, color, etc.) — it says nothing about whether an
-- image input like a Merge's Background/Foreground is actually WIRED to
-- the tool it's supposed to be. Uses the field-access idiom for Fusion's
-- Input objects (`tool[id]`, not the `tool:GetInput(id)` method used
-- above) since that's the documented path to an Input object's
-- GetConnectedOutput()/Output:GetTool() pair. UNVERIFIED as of first
-- write — never called live before, watch result.json closely.
ACTIONS.fusion_get_connections = function(params)
  local tool_name = need(params, "tool_name")
  local keys = need(params, "keys")
  local tool = ftool(tool_name)
  local connections, failed = {}, {}
  for _, key in ipairs(keys) do
    local ok, err = pcall(function()
      local input = tool[key]
      if input == nil then
        connections[key] = { exists = false }
        return
      end
      local out = input:GetConnectedOutput()
      if out == nil then
        connections[key] = { connected = false }
      else
        local src_tool = out.GetTool and out:GetTool() or nil
        local src_name = src_tool and src_tool:GetAttrs()["TOOLS_Name"] or nil
        connections[key] = { connected = true, source_tool = src_name }
      end
    end)
    if not ok then
      failed[key] = tostring(err)
    end
  end
  return {
    success = table_count(failed) == 0,
    tool_name = tool_name,
    connections = connections,
    failed = failed,
  }
end

-- UNVERIFIED as of first write — comp:Render() has never been called from
-- inside a Resolve-hosted Fusion page by this bridge before. If this fails
-- or produces no file, treat it as a known gap (see PROJECT_LOG.md Open
-- Items) rather than retrying blindly.
ACTIONS.fusion_render_preview = function(params)
  local source_tool = params.source_tool or "MediaOut1"
  local file_path = need(params, "file_path")
  local comp = fcomp()
  local src = ftool(source_tool)

  local saver = _fusion_tools["_ClaudeBridge_PreviewSaver"]
  if not saver then
    saver = comp:AddTool("Saver", 0, 0)
    if not saver then
      error("Could not create a Saver tool for preview rendering.")
    end
    saver:SetAttrs({ TOOLS_Name = "_ClaudeBridge_PreviewSaver" })
    _fusion_tools["_ClaudeBridge_PreviewSaver"] = saver
  end

  saver:SetInput("Input", src)
  saver:SetInput("Clip", file_path)

  local frame = params.frame
  if frame == nil then
    local attrs = comp:GetAttrs()
    frame = (attrs and attrs["COMPN_CurrentTime"]) or 0
  end

  local ok = comp:Render({ Start = frame, End = frame, Wait = true, SetBusy = true })

  return {
    success = ok and true or false,
    file_path = file_path,
    frame = frame,
    source_tool = source_tool,
  }
end

-- Added 2026-07-14, experimental. Fusion's "Create Macro" (select tools,
-- right-click > Macro > Create Macro) has never been called from this bridge
-- before — there is no confirmed Lua API call for it anywhere in this
-- project's history. This action TRIES several plausible Composition-level
-- calls, each isolated in its own pcall, and reports exactly which (if any)
-- didn't error, plus the raw error text for the ones that did. Do not trust
-- a "success" here on faith — cross-check with fusion_list_tools afterward
-- (does a new GroupOperator-type tool now exist?) before relying on this for
-- real work, per the project's standing "applied != worked" rule.
ACTIONS.fusion_create_macro = function(params)
  local tool_names = need(params, "tool_names")
  local comp = fcomp()

  -- Clear selection, then select exactly the requested tools, in the given
  -- order (order is what determines the resulting macro's control layout,
  -- per Fusion's normal "Create Macro" UI behavior).
  for _, t in pairs(comp:GetToolList(false) or {}) do
    local ok = pcall(function() t:SetAttrs({ TOOLS_Selected = false }) end)
  end
  local selected_tools, selected_names = {}, {}
  for _, name in ipairs(tool_names) do
    local t = ftool(name)
    t:SetAttrs({ TOOLS_Selected = true })
    selected_tools[#selected_tools+1] = t
    selected_names[#selected_names+1] = name
  end

  local attempts = {}

  local ok1, res1 = pcall(function() return comp:Group(selected_tools) end)
  attempts[#attempts+1] = { method = "comp:Group(tool_objects)", ok = ok1, result = tostring(res1) }

  if not ok1 then
    local ok2, res2 = pcall(function() return comp:Group(selected_names) end)
    attempts[#attempts+1] = { method = "comp:Group(tool_name_strings)", ok = ok2, result = tostring(res2) }
  end

  local ok3, res3 = pcall(function() return comp.CurrentFrame.FlowView:Group(selected_tools) end)
  attempts[#attempts+1] = { method = "FlowView:Group(tool_objects)", ok = ok3, result = tostring(res3) }

  local any_ok = false
  for _, a in ipairs(attempts) do
    if a.ok then any_ok = true end
  end

  -- Refresh tool cache/list so the caller can check what actually exists now.
  local after_names = {}
  for _, t in pairs(comp:GetToolList(false) or {}) do
    local n = t:GetAttrs()["TOOLS_Name"]
    if n then after_names[#after_names+1] = n end
  end

  return {
    success = any_ok,
    selected = selected_names,
    attempts = attempts,
    tools_after = after_names,
  }
end

-- ══════════════════════════════════════════════════════════════════════════
-- Main — read command.json, run each command, write result.json
-- ══════════════════════════════════════════════════════════════════════════

local raw = read_file(COMMAND_FILE)

if not raw or raw:match("^%s*$") then
  print("[ClaudeBridge] No command.json found (or it's empty) at " .. COMMAND_FILE)
else
  local decode_ok, payload = pcall(json_decode, raw)
  if not decode_ok then
    write_file(RESULT_FILE, json_encode({ error = "Failed to parse command.json: " .. tostring(payload) }))
    print("[ClaudeBridge] command.json failed to parse — see result.json")
  else
    local commands = (payload and payload.commands) or {}
    local results = {}
    for _, cmd in ipairs(commands) do
      local action_name = cmd.action
      local params = cmd.params or {}
      local handler = action_name and ACTIONS[action_name]
      local entry
      if not handler then
        entry = { action = action_name, success = false, error = "Unknown action '" .. tostring(action_name) .. "'" }
      else
        local ok, data_or_err = pcall(handler, params)
        if ok then
          entry = { action = action_name, success = true, data = data_or_err }
        else
          entry = { action = action_name, success = false, error = tostring(data_or_err) }
        end
      end
      results[#results+1] = entry
    end

    write_file(RESULT_FILE, json_encode({
      results = results,
      completed_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }))
    write_file(PROCESSED_FILE, raw)

    print(string.format("[ClaudeBridge] Executed %d command(s). See result.json.", #commands))
  end
end
