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
  return {
    name = t:GetName(),
    start_frame = t:GetStartFrame(),
    end_frame = t:GetEndFrame(),
    current_timecode = t:GetCurrentTimecode(),
    video_tracks = t:GetTrackCount("video"),
    audio_tracks = t:GetTrackCount("audio"),
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

ACTIONS.list_media_pool = function(_)
  local mp = proj():GetMediaPool()
  local folder = mp:GetCurrentFolder()
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
