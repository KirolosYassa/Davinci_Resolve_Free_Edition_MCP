#!/usr/bin/env python3
"""
DaVinci Resolve MCP Server  (davinci_resolve_mcp)
===================================================
Controls DaVinci Resolve (Free & Studio) via its built-in Python scripting API.

Requirements
------------
- DaVinci Resolve must be RUNNING before this server starts.
- Python 3.8+
- mcp[cli]  (pip install "mcp[cli]")

Transport: stdio  (registered as a local subprocess in Claude Desktop)

Covered tools (35)
------------------
App & Navigation  : resolve_get_info, resolve_open_page
Project Mgmt      : resolve_list_projects, resolve_get_project_info,
                    resolve_create_project, resolve_load_project,
                    resolve_save_project, resolve_get_project_settings
Timeline Mgmt     : resolve_list_timelines, resolve_get_timeline_info,
                    resolve_create_timeline, resolve_set_current_timeline,
                    resolve_duplicate_timeline, resolve_export_timeline
Items & Playhead  : resolve_get_timeline_items, resolve_get_timecode,
                    resolve_set_timecode
Markers           : resolve_add_marker, resolve_get_markers,
                    resolve_delete_marker
Media Pool        : resolve_list_media_pool, resolve_import_media,
                    resolve_create_bin, resolve_append_to_timeline
Render / Deliver  : resolve_get_render_presets, resolve_load_render_preset,
                    resolve_set_render_settings, resolve_add_render_job,
                    resolve_start_rendering, resolve_stop_rendering,
                    resolve_get_render_status, resolve_delete_render_job
Color             : resolve_apply_lut
Fusion Compositing: resolve_fusion_get_comp, resolve_fusion_list_tools,
                    resolve_fusion_add_tool, resolve_fusion_set_inputs,
                    resolve_fusion_connect, resolve_fusion_delete_tool,
                    resolve_fusion_save_tool_settings,
                    resolve_fusion_build_narration_banner

Note on the Fusion Compositing tools: these script Resolve's Fusion node-graph
API directly (comp.AddTool / tool.SetInput / node connections), including a
reusable "narration banner + journey stepper" title builder
(resolve_fusion_build_narration_banner) — a lower-third-style overlay with a
3-zone info banner and an 8-node progress stepper, fully parameterized (title,
heading, body copy, tags, stamp value, stepper labels, active step) so it can
be reused for any project. It's a best-effort structural first pass, not a
pixel-verified one — treat exact offsets/corner radii as a manual finishing
pass once you can see it in the Inspector. Every node/field is wrapped
individually and reports its own error, so a wrong input name in one section
never blocks the rest; check the "errors" key in its response and adjust with
resolve_fusion_set_inputs. Backdrop blur, grid textures, and drop shadows are
intentionally left as a manual finishing pass in Fusion, then Publish +
Create Macro to package the result as a reusable Titles-page template.
"""

from __future__ import annotations

import json
import os
import sys
from typing import Any, List, Optional

from pydantic import BaseModel, ConfigDict, Field
from mcp.server.fastmcp import FastMCP

# ──────────────────────────────────────────────────────────────────────────────
# Resolve scripting-module path discovery
# ──────────────────────────────────────────────────────────────────────────────

_MODULE_PATHS: dict[str, list[str]] = {
    "darwin": [
        "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules",
        os.path.expanduser(
            "~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules"
        ),
    ],
    "win32": [
        r"C:\ProgramData\Blackmagic Design\DaVinci Resolve\Support\Developer\Scripting\Modules",
    ],
    "linux": [
        "/opt/resolve/Developer/Scripting/Modules",
        "/opt/resolve/libs/Fusion/Modules",
    ],
}


def _setup_paths() -> None:
    """Prepend Resolve scripting module dirs to sys.path."""
    platform = "linux" if sys.platform.startswith("linux") else sys.platform
    env_path = os.environ.get("RESOLVE_SCRIPT_API", "")
    candidates = ([env_path] if env_path else []) + _MODULE_PATHS.get(platform, [])
    for path in candidates:
        if path and os.path.isdir(path) and path not in sys.path:
            sys.path.insert(0, path)


_setup_paths()

# ──────────────────────────────────────────────────────────────────────────────
# Resolve connection helpers
# ──────────────────────────────────────────────────────────────────────────────

_resolve_cache: Any = None


def _connect() -> tuple[Any, Optional[str]]:
    """Return (resolve_object, error_string).  Caches and pings the connection."""
    global _resolve_cache

    if _resolve_cache is not None:
        try:
            _resolve_cache.GetCurrentPage()   # quick liveness ping
            return _resolve_cache, None
        except Exception:
            _resolve_cache = None

    try:
        import DaVinciResolveScript as dvr  # type: ignore[import]

        obj = dvr.scriptapp("Resolve")
        if obj is None:
            return None, (
                "DaVinci Resolve is not running. "
                "Please launch it and try again."
            )
        _resolve_cache = obj
        return obj, None

    except ImportError:
        return None, (
            "DaVinciResolveScript module not found. "
            "Set the RESOLVE_SCRIPT_API environment variable to the Modules directory, "
            "or install DaVinci Resolve (free version works fine)."
        )
    except Exception as exc:
        return None, f"Connection error: {exc}"


# ── Accessor shortcuts ────────────────────────────────────────────────────────

def _r() -> Any:
    obj, err = _connect()
    if err:
        raise RuntimeError(err)
    return obj


def _p() -> Any:
    pm = _r().GetProjectManager()
    project = pm.GetCurrentProject()
    if not project:
        raise RuntimeError(
            "No project is open in DaVinci Resolve. "
            "Open or create a project first."
        )
    return project


def _tl() -> Any:
    tl = _p().GetCurrentTimeline()
    if not tl:
        raise RuntimeError(
            "No timeline is active. "
            "Open or create a timeline first."
        )
    return tl


# ── Response helpers ──────────────────────────────────────────────────────────

def _ok(data: Any) -> str:
    return json.dumps(data, indent=2, default=str)


def _err(msg: str) -> str:
    return json.dumps({"error": msg})


def _run(fn) -> str:
    """Execute fn(); translate RuntimeError → error JSON, any other Exception → error JSON."""
    try:
        return fn()
    except RuntimeError as exc:
        return _err(str(exc))
    except Exception as exc:
        return _err(f"Unexpected error ({type(exc).__name__}): {exc}")


# ──────────────────────────────────────────────────────────────────────────────
# MCP server
# ──────────────────────────────────────────────────────────────────────────────

mcp = FastMCP("davinci_resolve_mcp")

# ── Shared models ─────────────────────────────────────────────────────────────


class _Empty(BaseModel):
    model_config = ConfigDict(extra="forbid")


# ══════════════════════════════════════════════════════════════════════════════
# 1. APP INFO & PAGE NAVIGATION
# ══════════════════════════════════════════════════════════════════════════════

_VALID_PAGES = frozenset(
    ["cut", "edit", "fusion", "color", "fairlight", "deliver", "media"]
)


@mcp.tool(
    name="resolve_get_info",
    annotations={
        "title": "Get DaVinci Resolve Info",
        "readOnlyHint": True,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_get_info(params: _Empty) -> str:
    """Get DaVinci Resolve product name, version, and currently visible page.

    Call this first to confirm Resolve is running and to see which page is active.

    Returns JSON:
    {
      "product_name": str,    # e.g. "DaVinci Resolve"
      "version":      str,    # e.g. "18.6.6"
      "current_page": str     # e.g. "edit" | "color" | "deliver" ...
    }
    """
    return _run(lambda: _ok({
        "product_name": _r().GetProductName(),
        "version":      _r().GetVersionString(),
        "current_page": _r().GetCurrentPage(),
    }))


class _OpenPageInput(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    page: str = Field(
        ...,
        description=(
            "Page to open. One of: 'cut', 'edit', 'fusion', "
            "'color', 'fairlight', 'deliver', 'media'"
        ),
    )


@mcp.tool(
    name="resolve_open_page",
    annotations={
        "title": "Open DaVinci Resolve Page",
        "readOnlyHint": False,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_open_page(params: _OpenPageInput) -> str:
    """Switch DaVinci Resolve to a specific page (Cut / Edit / Color / Deliver etc.).

    Args:
        params.page: Target page name (case-insensitive).

    Returns JSON:
    {
      "success":      bool,
      "current_page": str
    }
    """
    page = params.page.lower().strip()
    if page not in _VALID_PAGES:
        return _err(
            f"Invalid page '{page}'. "
            f"Valid options: {', '.join(sorted(_VALID_PAGES))}"
        )

    def _fn():
        r = _r()
        ok = r.OpenPage(page)
        return _ok({"success": bool(ok), "current_page": r.GetCurrentPage()})

    return _run(_fn)


# ══════════════════════════════════════════════════════════════════════════════
# 2. PROJECT MANAGEMENT
# ══════════════════════════════════════════════════════════════════════════════

@mcp.tool(
    name="resolve_list_projects",
    annotations={
        "title": "List Projects",
        "readOnlyHint": True,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_list_projects(params: _Empty) -> str:
    """List all projects in the current project folder.

    Returns JSON:
    {
      "projects":        [str],
      "current_project": str | null,
      "current_folder":  str
    }
    """
    def _fn():
        r = _r()
        pm = r.GetProjectManager()
        projects = pm.GetProjectListInCurrentFolder() or []
        current = pm.GetCurrentProject()
        return _ok({
            "projects":        projects,
            "current_project": current.GetName() if current else None,
            "current_folder":  pm.GetCurrentFolder(),
        })
    return _run(_fn)


@mcp.tool(
    name="resolve_get_project_info",
    annotations={
        "title": "Get Current Project Info",
        "readOnlyHint": True,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_get_project_info(params: _Empty) -> str:
    """Get info about the currently open DaVinci Resolve project.

    Returns JSON:
    {
      "name":            str,
      "timeline_count":  int
    }
    """
    return _run(lambda: _ok({
        "name":           _p().GetName(),
        "timeline_count": _p().GetTimelineCount(),
    }))


class _ProjectNameInput(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    project_name: str = Field(
        ..., description="Project name", min_length=1, max_length=255
    )


@mcp.tool(
    name="resolve_create_project",
    annotations={
        "title": "Create Project",
        "readOnlyHint": False,
        "destructiveHint": False,
        "idempotentHint": False,
        "openWorldHint": False,
    },
)
async def resolve_create_project(params: _ProjectNameInput) -> str:
    """Create a new DaVinci Resolve project.

    Args:
        params.project_name: Name for the new project.

    Returns JSON:
    {
      "success":      bool,
      "project_name": str
    }
    """
    def _fn():
        pm = _r().GetProjectManager()
        p = pm.CreateProject(params.project_name)
        if not p:
            raise RuntimeError(
                f"Could not create project '{params.project_name}'. "
                "It may already exist or contain invalid characters."
            )
        return _ok({"success": True, "project_name": p.GetName()})
    return _run(_fn)


@mcp.tool(
    name="resolve_load_project",
    annotations={
        "title": "Load Project",
        "readOnlyHint": False,
        "destructiveHint": False,
        "idempotentHint": False,
        "openWorldHint": False,
    },
)
async def resolve_load_project(params: _ProjectNameInput) -> str:
    """Open an existing DaVinci Resolve project by name.

    Args:
        params.project_name: Name of the project to open.

    Returns JSON:
    {
      "success":      bool,
      "project_name": str
    }
    """
    def _fn():
        pm = _r().GetProjectManager()
        p = pm.LoadProject(params.project_name)
        if not p:
            raise RuntimeError(
                f"Project '{params.project_name}' not found. "
                "Use resolve_list_projects to see available projects."
            )
        return _ok({"success": True, "project_name": p.GetName()})
    return _run(_fn)


@mcp.tool(
    name="resolve_save_project",
    annotations={
        "title": "Save Current Project",
        "readOnlyHint": False,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_save_project(params: _Empty) -> str:
    """Save the currently open DaVinci Resolve project.

    Returns JSON:
    {
      "success": bool
    }
    """
    return _run(lambda: _ok({"success": bool(_r().GetProjectManager().SaveProject())}))


class _GetSettingInput(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    setting_name: Optional[str] = Field(
        default=None,
        description=(
            "Specific setting key to retrieve, e.g.: "
            "'timelineFrameRate', 'timelineResolutionWidth', "
            "'timelineResolutionHeight', 'colorScienceMode'. "
            "Leave empty to return ALL settings as a dict."
        ),
    )


@mcp.tool(
    name="resolve_get_project_settings",
    annotations={
        "title": "Get Project Settings",
        "readOnlyHint": True,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_get_project_settings(params: _GetSettingInput) -> str:
    """Get DaVinci Resolve project settings (frame rate, resolution, colour science, etc.).

    Common keys:
    - 'timelineFrameRate'        → e.g. '24'
    - 'timelineResolutionWidth'  → e.g. '1920'
    - 'timelineResolutionHeight' → e.g. '1080'
    - 'colorScienceMode'         → e.g. 'davinciYRGBColorManagedV2'

    Args:
        params.setting_name: Specific key, or null/empty for all settings.

    Returns JSON:
    {
      "setting": str,  "value": str     ← when a specific key is requested
      OR
      "settings": { str: str }          ← when no key is specified
    }
    """
    def _fn():
        p = _p()
        if params.setting_name:
            return _ok({"setting": params.setting_name, "value": p.GetSetting(params.setting_name)})
        return _ok({"settings": p.GetSetting() or {}})
    return _run(_fn)


# ══════════════════════════════════════════════════════════════════════════════
# 3. TIMELINE MANAGEMENT
# ══════════════════════════════════════════════════════════════════════════════

@mcp.tool(
    name="resolve_list_timelines",
    annotations={
        "title": "List Timelines",
        "readOnlyHint": True,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_list_timelines(params: _Empty) -> str:
    """List all timelines in the current DaVinci Resolve project.

    Returns JSON:
    {
      "current_timeline": str | null,
      "timelines": [
        {
          "index":        int,
          "name":         str,
          "start_frame":  int,
          "end_frame":    int,
          "video_tracks": int,
          "audio_tracks": int
        }
      ]
    }
    """
    def _fn():
        p = _p()
        count = p.GetTimelineCount()
        current = p.GetCurrentTimeline()
        timelines = []
        for i in range(1, count + 1):
            tl = p.GetTimelineByIndex(i)
            if tl:
                timelines.append({
                    "index":        i,
                    "name":         tl.GetName(),
                    "start_frame":  tl.GetStartFrame(),
                    "end_frame":    tl.GetEndFrame(),
                    "video_tracks": tl.GetTrackCount("video"),
                    "audio_tracks": tl.GetTrackCount("audio"),
                })
        return _ok({
            "current_timeline": current.GetName() if current else None,
            "timelines": timelines,
        })
    return _run(_fn)


@mcp.tool(
    name="resolve_get_timeline_info",
    annotations={
        "title": "Get Active Timeline Info",
        "readOnlyHint": True,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_get_timeline_info(params: _Empty) -> str:
    """Get detailed info about the currently active timeline.

    Returns JSON:
    {
      "name":             str,
      "start_frame":      int,
      "end_frame":        int,
      "current_timecode": str,   # e.g. "01:00:00:00"
      "video_tracks":     int,
      "audio_tracks":     int
    }
    """
    def _fn():
        tl = _tl()
        return _ok({
            "name":             tl.GetName(),
            "start_frame":      tl.GetStartFrame(),
            "end_frame":        tl.GetEndFrame(),
            "current_timecode": tl.GetCurrentTimecode(),
            "video_tracks":     tl.GetTrackCount("video"),
            "audio_tracks":     tl.GetTrackCount("audio"),
        })
    return _run(_fn)


class _CreateTimelineInput(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    name: str = Field(
        ..., description="Name for the new empty timeline", min_length=1, max_length=255
    )


@mcp.tool(
    name="resolve_create_timeline",
    annotations={
        "title": "Create Empty Timeline",
        "readOnlyHint": False,
        "destructiveHint": False,
        "idempotentHint": False,
        "openWorldHint": False,
    },
)
async def resolve_create_timeline(params: _CreateTimelineInput) -> str:
    """Create a new empty timeline in the current DaVinci Resolve project.

    Args:
        params.name: Name for the new timeline.

    Returns JSON:
    {
      "success":       bool,
      "timeline_name": str
    }
    """
    def _fn():
        p = _p()
        tl = p.GetMediaPool().CreateEmptyTimeline(params.name)
        if not tl:
            raise RuntimeError(
                f"Could not create timeline '{params.name}'. "
                "It may already exist."
            )
        return _ok({"success": True, "timeline_name": tl.GetName()})
    return _run(_fn)


class _SetTimelineInput(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    timeline_name:  Optional[str] = Field(
        default=None, description="Name of the timeline to switch to (preferred)"
    )
    timeline_index: Optional[int] = Field(
        default=None,
        description="1-based index of the timeline (use if name is not unique)",
        ge=1,
    )


@mcp.tool(
    name="resolve_set_current_timeline",
    annotations={
        "title": "Set Active Timeline",
        "readOnlyHint": False,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_set_current_timeline(params: _SetTimelineInput) -> str:
    """Switch the active timeline by name or 1-based index.

    Provide either timeline_name (preferred) or timeline_index.

    Returns JSON:
    {
      "success":       bool,
      "timeline_name": str
    }
    """
    if not params.timeline_name and not params.timeline_index:
        return _err("Provide either 'timeline_name' or 'timeline_index'.")

    def _fn():
        p = _p()
        count = p.GetTimelineCount()
        target = None

        if params.timeline_name:
            for i in range(1, count + 1):
                tl = p.GetTimelineByIndex(i)
                if tl and tl.GetName() == params.timeline_name:
                    target = tl
                    break
            if not target:
                raise RuntimeError(
                    f"Timeline '{params.timeline_name}' not found. "
                    "Use resolve_list_timelines to see all timelines."
                )
        else:
            target = p.GetTimelineByIndex(params.timeline_index)
            if not target:
                raise RuntimeError(f"No timeline at index {params.timeline_index}.")

        return _ok({"success": bool(p.SetCurrentTimeline(target)), "timeline_name": target.GetName()})
    return _run(_fn)


class _DupTimelineInput(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    new_name: Optional[str] = Field(
        default=None,
        description="Name for the copy. Defaults to '<original> (Copy)'.",
    )


@mcp.tool(
    name="resolve_duplicate_timeline",
    annotations={
        "title": "Duplicate Current Timeline",
        "readOnlyHint": False,
        "destructiveHint": False,
        "idempotentHint": False,
        "openWorldHint": False,
    },
)
async def resolve_duplicate_timeline(params: _DupTimelineInput) -> str:
    """Duplicate the currently active timeline.

    Args:
        params.new_name: Name for the duplicate (optional).

    Returns JSON:
    {
      "success":           bool,
      "new_timeline_name": str
    }
    """
    def _fn():
        tl = _tl()
        name = params.new_name or f"{tl.GetName()} (Copy)"
        new_tl = tl.DuplicateTimeline(name)
        if not new_tl:
            raise RuntimeError("Failed to duplicate timeline.")
        return _ok({"success": True, "new_timeline_name": new_tl.GetName()})
    return _run(_fn)


_EXPORT_ATTR: dict[str, str] = {
    "edl":    "EXPORT_EDL",
    "xml":    "EXPORT_FCP_7_XML",
    "fcpxml": "EXPORT_FCP_11_XML",
    "aaf":    "EXPORT_AAF",
    "drt":    "EXPORT_DRT",
    "otio":   "EXPORT_OTIO",
    "csv":    "EXPORT_CSV",
}


class _ExportTimelineInput(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    file_path: str = Field(
        ...,
        description=(
            "Full output path including filename and extension "
            "(e.g. '/Users/me/export.edl')"
        ),
        min_length=1,
    )
    export_type: str = Field(
        default="edl",
        description=(
            "Format: 'edl' | 'xml' (FCP7) | 'fcpxml' (FCP11/X) | "
            "'aaf' | 'drt' | 'otio' | 'csv'"
        ),
    )


@mcp.tool(
    name="resolve_export_timeline",
    annotations={
        "title": "Export Timeline",
        "readOnlyHint": False,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_export_timeline(params: _ExportTimelineInput) -> str:
    """Export the current timeline as EDL, XML, FCPXML, AAF, DRT, OTIO, or CSV.

    Args:
        params.file_path:   Full output file path (e.g. '/Users/me/cut.edl')
        params.export_type: 'edl' | 'xml' | 'fcpxml' | 'aaf' | 'drt' | 'otio' | 'csv'

    Returns JSON:
    {
      "success":   bool,
      "file_path": str,
      "format":    str
    }
    """
    fmt = params.export_type.lower()
    if fmt not in _EXPORT_ATTR:
        return _err(
            f"Invalid export_type '{fmt}'. "
            f"Valid: {', '.join(_EXPORT_ATTR)}"
        )

    def _fn():
        r = _r()
        tl = _tl()
        type_const = getattr(r, _EXPORT_ATTR[fmt], None)
        if type_const is None:
            raise RuntimeError(
                f"Export type '{fmt}' is not available in this version of DaVinci Resolve."
            )
        subtype = getattr(r, "EXPORT_NONE", 0)
        return _ok({
            "success":   bool(tl.Export(params.file_path, type_const, subtype)),
            "file_path": params.file_path,
            "format":    fmt,
        })
    return _run(_fn)


# ══════════════════════════════════════════════════════════════════════════════
# 4. TIMELINE ITEMS & PLAYHEAD
# ══════════════════════════════════════════════════════════════════════════════

class _GetItemsInput(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    track_type:  str = Field(default="video", description="'video' or 'audio'")
    track_index: int = Field(default=1, description="1-based track number", ge=1)


@mcp.tool(
    name="resolve_get_timeline_items",
    annotations={
        "title": "Get Timeline Track Items",
        "readOnlyHint": True,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_get_timeline_items(params: _GetItemsInput) -> str:
    """Get all clips in a specific track of the current timeline.

    Args:
        params.track_type:  'video' (default) or 'audio'
        params.track_index: 1-based track number (default: 1)

    Returns JSON:
    {
      "track_type":  str,
      "track_index": int,
      "count":       int,
      "items": [
        {
          "name":         str,
          "start":        int,   # timeline start frame
          "end":          int,   # timeline end frame
          "duration":     int,   # frames
          "source_start": int,
          "source_end":   int
        }
      ]
    }
    """
    tt = params.track_type.lower()
    if tt not in ("video", "audio"):
        return _err("track_type must be 'video' or 'audio'.")

    def _fn():
        tl = _tl()
        items = tl.GetItemListInTrack(tt, params.track_index)
        if items is None:
            raise RuntimeError(
                f"{tt.capitalize()} track {params.track_index} does not exist. "
                "Use resolve_get_timeline_info to check track counts."
            )
        result = [
            {
                "name":         item.GetName(),
                "start":        item.GetStart(),
                "end":          item.GetEnd(),
                "duration":     item.GetDuration(),
                "source_start": item.GetSourceStartFrame(),
                "source_end":   item.GetSourceEndFrame(),
            }
            for item in items
        ]
        return _ok({
            "track_type":  tt,
            "track_index": params.track_index,
            "count":       len(result),
            "items":       result,
        })
    return _run(_fn)


@mcp.tool(
    name="resolve_get_timecode",
    annotations={
        "title": "Get Current Timecode",
        "readOnlyHint": True,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_get_timecode(params: _Empty) -> str:
    """Get the playhead's current timecode in the active timeline.

    Returns JSON:
    {
      "timecode": str   # e.g. "01:00:05:12"
    }
    """
    return _run(lambda: _ok({"timecode": _tl().GetCurrentTimecode()}))


class _SetTimecodeInput(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    timecode: str = Field(
        ...,
        description="Target timecode in HH:MM:SS:FF format (e.g. '01:00:10:00')",
        pattern=r"^\d{2}:\d{2}:\d{2}:\d{2}$",
    )


@mcp.tool(
    name="resolve_set_timecode",
    annotations={
        "title": "Seek to Timecode",
        "readOnlyHint": False,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_set_timecode(params: _SetTimecodeInput) -> str:
    """Move the playhead to a specific timecode in the current timeline.

    Args:
        params.timecode: Target timecode in HH:MM:SS:FF format.

    Returns JSON:
    {
      "success":  bool,
      "timecode": str
    }
    """
    return _run(lambda: _ok({
        "success":  bool(_tl().SetCurrentTimecode(params.timecode)),
        "timecode": params.timecode,
    }))


# ══════════════════════════════════════════════════════════════════════════════
# 5. MARKERS
# ══════════════════════════════════════════════════════════════════════════════

_MARKER_COLORS = [
    "Blue", "Cyan", "Green", "Yellow", "Red", "Pink", "Purple",
    "Fuchsia", "Rose", "Lavender", "Sky", "Mint", "Lemon",
    "Sand", "Cocoa", "Cream",
]


class _AddMarkerInput(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    frame_id:    int = Field(..., description="Frame number to place the marker", ge=0)
    color:       str = Field(
        default="Blue",
        description=f"Marker colour. Options: {', '.join(_MARKER_COLORS)}",
    )
    name:        str = Field(default="", description="Short label shown in the timeline")
    note:        str = Field(default="", description="Longer comment/description")
    duration:    int = Field(default=1, description="Span in frames", ge=1)
    custom_data: str = Field(default="", description="Arbitrary metadata string")


@mcp.tool(
    name="resolve_add_marker",
    annotations={
        "title": "Add Timeline Marker",
        "readOnlyHint": False,
        "destructiveHint": False,
        "idempotentHint": False,
        "openWorldHint": False,
    },
)
async def resolve_add_marker(params: _AddMarkerInput) -> str:
    """Add a marker to the current timeline at a specific frame.

    Args:
        params.frame_id:    Frame number (e.g. 86400 = 01:00:00:00 at 24 fps)
        params.color:       Marker colour (default: 'Blue')
        params.name:        Short label
        params.note:        Detailed note
        params.duration:    Duration in frames (default: 1)
        params.custom_data: Arbitrary metadata for programmatic use

    Returns JSON:
    {
      "success":  bool,
      "frame_id": int,
      "color":    str,
      "name":     str
    }
    """
    def _fn():
        tl = _tl()
        success = tl.AddMarker(
            params.frame_id,
            params.color,
            params.name,
            params.note,
            params.duration,
            params.custom_data,
        )
        return _ok({
            "success":  bool(success),
            "frame_id": params.frame_id,
            "color":    params.color,
            "name":     params.name,
        })
    return _run(_fn)


@mcp.tool(
    name="resolve_get_markers",
    annotations={
        "title": "Get Timeline Markers",
        "readOnlyHint": True,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_get_markers(params: _Empty) -> str:
    """Get all markers on the current timeline.

    Returns JSON:
    {
      "count": int,
      "markers": {
        "<frame_number>": {
          "color":      str,
          "name":       str,
          "note":       str,
          "duration":   int,
          "customData": str
        }
      }
    }
    """
    def _fn():
        markers = _tl().GetMarkers() or {}
        return _ok({"count": len(markers), "markers": markers})
    return _run(_fn)


class _DeleteMarkerInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    frame_num: int = Field(
        ..., description="Frame number of the marker to delete", ge=0
    )


@mcp.tool(
    name="resolve_delete_marker",
    annotations={
        "title": "Delete Timeline Marker",
        "readOnlyHint": False,
        "destructiveHint": True,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_delete_marker(params: _DeleteMarkerInput) -> str:
    """Delete the marker at a specific frame number on the current timeline.

    Args:
        params.frame_num: Frame number of the marker to remove.

    Returns JSON:
    {
      "success":   bool,
      "frame_num": int
    }
    """
    return _run(lambda: _ok({
        "success":   bool(_tl().DeleteMarkerAtFrame(params.frame_num)),
        "frame_num": params.frame_num,
    }))


# ══════════════════════════════════════════════════════════════════════════════
# 6. MEDIA POOL
# ══════════════════════════════════════════════════════════════════════════════

@mcp.tool(
    name="resolve_list_media_pool",
    annotations={
        "title": "List Media Pool Contents",
        "readOnlyHint": True,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_list_media_pool(params: _Empty) -> str:
    """List clips in the currently selected Media Pool folder.

    Returns JSON:
    {
      "folder": str,
      "count":  int,
      "clips": [
        {
          "name":      str,
          "type":      str | null,
          "duration":  str | null,
          "fps":       str | null,
          "file_path": str | null
        }
      ]
    }
    """
    def _prop(clip, key: str):
        try:
            return clip.GetClipProperty(key)
        except Exception:
            return None

    def _fn():
        mp = _p().GetMediaPool()
        folder = mp.GetCurrentFolder()
        clips = folder.GetClipList() or []
        result = [
            {
                "name":      c.GetName(),
                "type":      _prop(c, "Type"),
                "duration":  _prop(c, "Duration"),
                "fps":       _prop(c, "FPS"),
                "file_path": _prop(c, "File Path"),
            }
            for c in clips
        ]
        return _ok({"folder": folder.GetName(), "count": len(result), "clips": result})
    return _run(_fn)


class _ImportMediaInput(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    file_paths: List[str] = Field(
        ...,
        description=(
            "Absolute file paths to import "
            "(e.g. ['/Users/me/clip.mp4', '/Users/me/audio.wav'])"
        ),
        min_length=1,
        max_length=200,
    )


@mcp.tool(
    name="resolve_import_media",
    annotations={
        "title": "Import Media to Media Pool",
        "readOnlyHint": False,
        "destructiveHint": False,
        "idempotentHint": False,
        "openWorldHint": False,
    },
)
async def resolve_import_media(params: _ImportMediaInput) -> str:
    """Import media files into the DaVinci Resolve Media Pool.

    Args:
        params.file_paths: List of absolute paths to video, audio, or image files.

    Returns JSON:
    {
      "success":        bool,
      "imported_count": int,
      "imported_clips": [str]
    }
    """
    def _fn():
        mp = _p().GetMediaPool()
        imported = mp.ImportMedia(params.file_paths)
        if not imported:
            raise RuntimeError(
                "No files were imported. "
                "Verify that all paths exist and are in a supported format."
            )
        names = [c.GetName() for c in imported if c]
        return _ok({"success": True, "imported_count": len(names), "imported_clips": names})
    return _run(_fn)


class _CreateBinInput(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    name: str = Field(
        ..., description="Name for the new bin / sub-folder", min_length=1, max_length=255
    )


@mcp.tool(
    name="resolve_create_bin",
    annotations={
        "title": "Create Media Pool Bin",
        "readOnlyHint": False,
        "destructiveHint": False,
        "idempotentHint": False,
        "openWorldHint": False,
    },
)
async def resolve_create_bin(params: _CreateBinInput) -> str:
    """Create a new bin (sub-folder) inside the currently selected Media Pool folder.

    Args:
        params.name: Name for the new bin.

    Returns JSON:
    {
      "success":  bool,
      "bin_name": str
    }
    """
    def _fn():
        mp = _p().GetMediaPool()
        new_folder = mp.AddSubFolder(mp.GetCurrentFolder(), params.name)
        if not new_folder:
            raise RuntimeError(f"Failed to create bin '{params.name}'.")
        return _ok({"success": True, "bin_name": new_folder.GetName()})
    return _run(_fn)


class _AppendClipsInput(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    clip_names: List[str] = Field(
        ...,
        description=(
            "Names of Media Pool clips to append to the current timeline. "
            "Use resolve_list_media_pool to see available clip names."
        ),
        min_length=1,
    )


@mcp.tool(
    name="resolve_append_to_timeline",
    annotations={
        "title": "Append Clips to Timeline",
        "readOnlyHint": False,
        "destructiveHint": False,
        "idempotentHint": False,
        "openWorldHint": False,
    },
)
async def resolve_append_to_timeline(params: _AppendClipsInput) -> str:
    """Append clips from the Media Pool to the end of the current timeline.

    Args:
        params.clip_names: List of clip names already in the Media Pool.

    Returns JSON:
    {
      "success":        bool,
      "appended_count": int
    }
    """
    def _fn():
        mp = _p().GetMediaPool()
        folder = mp.GetCurrentFolder()
        clip_map = {c.GetName(): c for c in (folder.GetClipList() or [])}

        to_add, missing = [], []
        for name in params.clip_names:
            (to_add if name in clip_map else missing).append(name)

        if missing:
            raise RuntimeError(
                f"Clips not found in Media Pool: {', '.join(missing)}. "
                "Use resolve_list_media_pool to see available clips."
            )

        result = mp.AppendToTimeline(to_add)
        return _ok({"success": bool(result), "appended_count": len(result) if result else 0})
    return _run(_fn)


# ══════════════════════════════════════════════════════════════════════════════
# 7. RENDER / DELIVER
# ══════════════════════════════════════════════════════════════════════════════

@mcp.tool(
    name="resolve_get_render_presets",
    annotations={
        "title": "Get Render Presets",
        "readOnlyHint": True,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_get_render_presets(params: _Empty) -> str:
    """List all available render presets (e.g. 'YouTube 1080p', 'H.264 Master').

    Returns JSON:
    {
      "presets": [str]
    }
    """
    def _fn():
        presets = _p().GetRenderPresets() or {}
        names = list(presets.keys()) if isinstance(presets, dict) else list(presets)
        return _ok({"presets": names})
    return _run(_fn)


class _LoadPresetInput(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    preset_name: str = Field(
        ...,
        description="Preset name from resolve_get_render_presets (e.g. 'YouTube 1080p')",
        min_length=1,
    )


@mcp.tool(
    name="resolve_load_render_preset",
    annotations={
        "title": "Load Render Preset",
        "readOnlyHint": False,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_load_render_preset(params: _LoadPresetInput) -> str:
    """Apply a saved render preset by name.

    Use resolve_get_render_presets to list available presets first.

    Args:
        params.preset_name: Name of the preset to load.

    Returns JSON:
    {
      "success":     bool,
      "preset_name": str
    }
    """
    def _fn():
        return _ok({
            "success":     bool(_p().LoadRenderPreset(params.preset_name)),
            "preset_name": params.preset_name,
        })
    return _run(_fn)


class _SetRenderSettingsInput(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    target_dir:        Optional[str]  = Field(default=None, description="Output folder path")
    custom_name:       Optional[str]  = Field(default=None, description="Output filename (no extension)")
    export_video:      Optional[bool] = Field(default=None, description="Include video track")
    export_audio:      Optional[bool] = Field(default=None, description="Include audio track")
    select_all_frames: Optional[bool] = Field(
        default=None, description="True = whole timeline, False = in/out range only"
    )


@mcp.tool(
    name="resolve_set_render_settings",
    annotations={
        "title": "Set Render Settings",
        "readOnlyHint": False,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_set_render_settings(params: _SetRenderSettingsInput) -> str:
    """Override render output settings for the current project.

    Typical workflow: load a preset with resolve_load_render_preset,
    then call this to change the output folder / filename.

    Args:
        params.target_dir:        Output folder (e.g. '/Users/me/renders')
        params.custom_name:       Output filename without extension
        params.export_video:      Whether to include video
        params.export_audio:      Whether to include audio
        params.select_all_frames: True = full timeline, False = in/out range

    Returns JSON:
    {
      "success":          bool,
      "applied_settings": { str: any }
    }
    """
    settings: dict = {}
    if params.target_dir        is not None: settings["TargetDir"]       = params.target_dir
    if params.custom_name       is not None: settings["CustomName"]      = params.custom_name
    if params.export_video      is not None: settings["ExportVideo"]     = params.export_video
    if params.export_audio      is not None: settings["ExportAudio"]     = params.export_audio
    if params.select_all_frames is not None: settings["SelectAllFrames"] = params.select_all_frames

    if not settings:
        return _err("Provide at least one render setting to change.")

    def _fn():
        return _ok({
            "success":          bool(_p().SetRenderSettings(settings)),
            "applied_settings": settings,
        })
    return _run(_fn)


@mcp.tool(
    name="resolve_add_render_job",
    annotations={
        "title": "Add Render Job to Queue",
        "readOnlyHint": False,
        "destructiveHint": False,
        "idempotentHint": False,
        "openWorldHint": False,
    },
)
async def resolve_add_render_job(params: _Empty) -> str:
    """Add the current timeline to the DaVinci Resolve render queue.

    Configure output settings with resolve_load_render_preset and/or
    resolve_set_render_settings before calling this.

    Returns JSON:
    {
      "success": bool,
      "job_id":  str
    }
    """
    def _fn():
        job_id = _p().AddRenderJob()
        if not job_id:
            raise RuntimeError(
                "Failed to add render job. "
                "Check that render settings are configured and a timeline is active."
            )
        return _ok({"success": True, "job_id": job_id})
    return _run(_fn)


class _StartRenderInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    job_ids: Optional[List[str]] = Field(
        default=None,
        description=(
            "Specific job IDs to render. "
            "Leave null / empty to render ALL queued jobs."
        ),
    )


@mcp.tool(
    name="resolve_start_rendering",
    annotations={
        "title": "Start Rendering",
        "readOnlyHint": False,
        "destructiveHint": False,
        "idempotentHint": False,
        "openWorldHint": False,
    },
)
async def resolve_start_rendering(params: _StartRenderInput) -> str:
    """Start rendering job(s) in the DaVinci Resolve render queue.

    Args:
        params.job_ids: Specific IDs to render, or null for all queued jobs.

    Returns JSON:
    {
      "success": bool
    }
    """
    def _fn():
        p = _p()
        success = p.StartRendering(*params.job_ids) if params.job_ids else p.StartRendering()
        return _ok({"success": bool(success)})
    return _run(_fn)


@mcp.tool(
    name="resolve_stop_rendering",
    annotations={
        "title": "Stop Rendering",
        "readOnlyHint": False,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_stop_rendering(params: _Empty) -> str:
    """Stop the active rendering process in DaVinci Resolve.

    Returns JSON:
    {
      "success": bool
    }
    """
    def _fn():
        _p().StopRendering()
        return _ok({"success": True})
    return _run(_fn)


@mcp.tool(
    name="resolve_get_render_status",
    annotations={
        "title": "Get Render Status",
        "readOnlyHint": True,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_get_render_status(params: _Empty) -> str:
    """Get the render queue status and details of all render jobs.

    Returns JSON:
    {
      "is_rendering": bool,
      "job_count":    int,
      "jobs": [
        {
          "JobId":  str,
          ...job fields...,
          "status": { ... }
        }
      ]
    }
    """
    def _fn():
        p = _p()
        is_rendering = p.IsRenderingInProgress()
        jobs = []
        for job in (p.GetRenderJobList() or []):
            jid = job.get("JobId", "")
            jobs.append({**job, "status": p.GetRenderJobStatus(jid) if jid else {}})
        return _ok({"is_rendering": bool(is_rendering), "job_count": len(jobs), "jobs": jobs})
    return _run(_fn)


class _DeleteJobInput(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    job_id: str = Field(
        ..., description="Job ID to remove (from resolve_get_render_status)", min_length=1
    )


@mcp.tool(
    name="resolve_delete_render_job",
    annotations={
        "title": "Delete Render Job",
        "readOnlyHint": False,
        "destructiveHint": True,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_delete_render_job(params: _DeleteJobInput) -> str:
    """Remove a render job from the DaVinci Resolve render queue.

    Args:
        params.job_id: Job ID to delete (from resolve_get_render_status).

    Returns JSON:
    {
      "success": bool,
      "job_id":  str
    }
    """
    return _run(lambda: _ok({
        "success": bool(_p().DeleteRenderJob(params.job_id)),
        "job_id":  params.job_id,
    }))


# ══════════════════════════════════════════════════════════════════════════════
# 8. COLOR
# ══════════════════════════════════════════════════════════════════════════════

class _ApplyLUTInput(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    lut_path:    str = Field(
        ...,
        description="Absolute path to a .cube or .3dl LUT file (e.g. '/Users/me/film.cube')",
        min_length=1,
    )
    track_index: int = Field(default=1, description="Video track index (1-based)", ge=1)
    clip_index:  int = Field(
        default=0,
        description="0-based position of the clip within the track (0 = first clip)",
        ge=0,
    )
    node_index:  int = Field(default=1, description="Colour node to receive the LUT (1-based)", ge=1)


@mcp.tool(
    name="resolve_apply_lut",
    annotations={
        "title": "Apply LUT to Clip",
        "readOnlyHint": False,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_apply_lut(params: _ApplyLUTInput) -> str:
    """Apply a LUT file to a clip's colour node.

    Switch to the Color page first (resolve_open_page with page='color').

    Args:
        params.lut_path:    Full path to .cube or .3dl LUT
        params.track_index: Video track (default: 1)
        params.clip_index:  0-based clip position in that track (default: 0)
        params.node_index:  Node to apply the LUT to (default: 1)

    Returns JSON:
    {
      "success":    bool,
      "clip_name":  str,
      "lut_path":   str,
      "node_index": int
    }
    """
    def _fn():
        tl = _tl()
        items = tl.GetItemListInTrack("video", params.track_index)
        if not items or params.clip_index >= len(items):
            raise RuntimeError(
                f"Clip at video track {params.track_index}, "
                f"index {params.clip_index} not found. "
                f"Track has {len(items) if items else 0} clip(s). "
                "Use resolve_get_timeline_items to inspect the track."
            )
        clip = items[params.clip_index]
        return _ok({
            "success":    bool(clip.SetLUT(params.node_index, params.lut_path)),
            "clip_name":  clip.GetName(),
            "lut_path":   params.lut_path,
            "node_index": params.node_index,
        })
    return _run(_fn)


# ══════════════════════════════════════════════════════════════════════════════
# 9. FUSION COMPOSITING  (build node graphs on a clip's Fusion composition)
# ══════════════════════════════════════════════════════════════════════════════
#
# Prerequisite for every tool below: on the Edit page, place a blank-canvas
# clip on a video track above your footage — Effects Library > Generators >
# Solid Color, or any Titles placeholder — select it, then call
# resolve_fusion_get_comp. New nodes render as a transparent overlay because
# MediaIn (the solid color) is left unconnected.
#
# These are best-effort against the documented Fusion scripting API
# (comp.AddTool / tool.SetInput / connecting tools by assigning them as an
# input value). They have not been tested against a live Resolve instance —
# exact input names can vary slightly across Resolve 18/19/20. Every failure
# is caught and reported by name/field so it's fixable interactively rather
# than crashing the whole build.

_fusion_state: dict[str, Any] = {"comp": None, "tools": {}}


def _fcomp() -> Any:
    comp = _fusion_state.get("comp")
    if comp is None:
        raise RuntimeError(
            "No Fusion composition attached. Call resolve_fusion_get_comp first."
        )
    return comp


def _ftool(name: str) -> Any:
    tools = _fusion_state.setdefault("tools", {})
    if name in tools:
        return tools[name]
    comp = _fcomp()
    for t in (comp.GetToolList(False) or {}).values():
        if t.GetAttrs().get("TOOLS_Name") == name:
            tools[name] = t
            return t
    raise RuntimeError(
        f"No Fusion tool named '{name}'. Use resolve_fusion_list_tools to see what exists."
    )


def _hex_rgba(hex_code: str, alpha: float = 1.0) -> dict:
    h = hex_code.lstrip("#")
    return {
        "R": int(h[0:2], 16) / 255,
        "G": int(h[2:4], 16) / 255,
        "B": int(h[4:6], 16) / 255,
        "A": alpha,
    }


_SERVES_COLORS = {
    "CREDIT":     "#5EFFCD",
    "RISK":       "#FFC861",
    "OPERATIONS": "#B18CFF",
    "FINANCE":    "#7ADCFF",
    "EXECUTIVE":  "#F1F5F9",
}


class _FusionGetCompInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    track_index: int = Field(default=1, ge=1, description="Video track number (1-based)")
    clip_index: int = Field(default=0, ge=0, description="0-based clip position within that track")
    create_if_missing: bool = Field(
        default=True, description="Create a new Fusion composition on the clip if one doesn't exist yet"
    )


@mcp.tool(
    name="resolve_fusion_get_comp",
    annotations={
        "title": "Attach to a Clip's Fusion Composition",
        "readOnlyHint": False,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_fusion_get_comp(params: _FusionGetCompInput) -> str:
    """Attach to (or create) the Fusion composition on a timeline clip.

    Call this before any other resolve_fusion_* tool. Point it at a blank
    generator/title clip so the graph you build renders as a transparent
    overlay rather than modifying real footage.

    Returns JSON:
    {
      "success":        bool,
      "clip_name":      str,
      "existing_tools": [str]
    }
    """
    def _fn():
        tl = _tl()
        items = tl.GetItemListInTrack("video", params.track_index)
        if not items or params.clip_index >= len(items):
            raise RuntimeError(
                f"Clip at video track {params.track_index}, index {params.clip_index} not found."
            )
        clip = items[params.clip_index]
        comp = clip.GetFusionCompByIndex(1)
        if not comp:
            if not params.create_if_missing:
                raise RuntimeError(
                    "Clip has no Fusion composition yet. Call again with create_if_missing=true."
                )
            comp = clip.AddFusionComp()
            if not comp:
                raise RuntimeError("Failed to create a Fusion composition on this clip.")

        _fusion_state["comp"] = comp
        _fusion_state["tools"] = {}
        names = []
        for t in (comp.GetToolList(False) or {}).values():
            n = t.GetAttrs().get("TOOLS_Name")
            if n:
                _fusion_state["tools"][n] = t
                names.append(n)

        return _ok({"success": True, "clip_name": clip.GetName(), "existing_tools": names})
    return _run(_fn)


@mcp.tool(
    name="resolve_fusion_list_tools",
    annotations={
        "title": "List Fusion Tools",
        "readOnlyHint": True,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_fusion_list_tools(params: _Empty) -> str:
    """List every tool (node) currently in the attached Fusion composition.

    Returns JSON: { "count": int, "tools": [{"name": str, "id": str}] }
    """
    def _fn():
        comp = _fcomp()
        result = []
        for t in (comp.GetToolList(False) or {}).values():
            attrs = t.GetAttrs()
            result.append({"name": attrs.get("TOOLS_Name"), "id": attrs.get("TOOLS_RegID")})
        return _ok({"count": len(result), "tools": result})
    return _run(_fn)


class _FusionAddToolInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    tool_id: str = Field(
        ...,
        description=(
            "Fusion tool registry ID, e.g. 'Background' (solid/gradient fill), "
            "'TextPlus' (styled text), 'Merge' (composite A over B), 'Blur' "
            "(Gaussian blur), 'RectangleMask' / 'EllipseMask' (shapes — connect "
            "to another tool's EffectMask input), 'Transform', 'MediaOut'"
        ),
    )
    name: str = Field(..., description="Custom name to reference this tool by in later calls")
    xpos: int = Field(default=0, description="Node graph X position (grid cells, cosmetic only)")
    ypos: int = Field(default=0, description="Node graph Y position (grid cells, cosmetic only)")


@mcp.tool(
    name="resolve_fusion_add_tool",
    annotations={
        "title": "Add Fusion Tool",
        "readOnlyHint": False,
        "destructiveHint": False,
        "idempotentHint": False,
        "openWorldHint": False,
    },
)
async def resolve_fusion_add_tool(params: _FusionAddToolInput) -> str:
    """Add a new tool (node) to the attached Fusion composition.

    Returns JSON: { "success": bool, "name": str, "tool_id": str }
    """
    def _fn():
        comp = _fcomp()
        tool = comp.AddTool(params.tool_id, params.xpos, params.ypos)
        if not tool:
            raise RuntimeError(
                f"Fusion rejected tool_id '{params.tool_id}'. IDs are case-sensitive — "
                "check it against the Fusion Effects list."
            )
        tool.SetAttrs({"TOOLS_Name": params.name})
        _fusion_state["tools"][params.name] = tool
        return _ok({"success": True, "name": params.name, "tool_id": params.tool_id})
    return _run(_fn)


class _FusionSetInputsInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    tool_name: str = Field(..., description="Name given to the tool via resolve_fusion_add_tool")
    inputs: dict = Field(
        ...,
        description=(
            "Map of input name -> value, using the names shown in Fusion's "
            "Inspector (e.g. 'StyledText', 'Font', 'Size', 'Center', 'Width', "
            "'Height'). Points are {'X':..,'Y':..} dicts, 0-1 normalized."
        ),
    )


@mcp.tool(
    name="resolve_fusion_set_inputs",
    annotations={
        "title": "Set Fusion Tool Inputs",
        "readOnlyHint": False,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_fusion_set_inputs(params: _FusionSetInputsInput) -> str:
    """Set one or more input parameters on an existing Fusion tool.

    If a name is wrong, the error tells you which key failed so you can look
    it up in the Inspector and retry — it never fails the whole call.

    Returns JSON:
    {
      "success":    bool,
      "tool_name":  str,
      "applied":    [str],
      "failed":     { str: str }
    }
    """
    def _fn():
        tool = _ftool(params.tool_name)
        applied, failed = [], {}
        for key, value in params.inputs.items():
            try:
                tool.SetInput(key, value)
                applied.append(key)
            except Exception as exc:
                failed[key] = str(exc)
        return _ok({
            "success":   len(failed) == 0,
            "tool_name": params.tool_name,
            "applied":   applied,
            "failed":    failed,
        })
    return _run(_fn)


class _FusionConnectInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    from_tool: str = Field(..., description="Name of the tool whose output feeds forward")
    to_tool:   str = Field(..., description="Name of the tool receiving the connection")
    to_input:  str = Field(
        default="Input",
        description="Input name on the destination tool, e.g. 'Input', 'Foreground', 'Background', 'EffectMask'",
    )


@mcp.tool(
    name="resolve_fusion_connect",
    annotations={
        "title": "Connect Fusion Tools",
        "readOnlyHint": False,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_fusion_connect(params: _FusionConnectInput) -> str:
    """Connect one tool's output into another tool's input — the scripted
    equivalent of dragging a wire between two nodes on the Fusion page.

    Returns JSON: { "success": bool }
    """
    def _fn():
        src = _ftool(params.from_tool)
        dst = _ftool(params.to_tool)
        dst.SetInput(params.to_input, src)
        return _ok({"success": True})
    return _run(_fn)


class _FusionDeleteToolInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    tool_name: str


@mcp.tool(
    name="resolve_fusion_delete_tool",
    annotations={
        "title": "Delete Fusion Tool",
        "readOnlyHint": False,
        "destructiveHint": True,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_fusion_delete_tool(params: _FusionDeleteToolInput) -> str:
    """Delete a tool (node) from the attached Fusion composition.

    Returns JSON: { "success": bool }
    """
    def _fn():
        tool = _ftool(params.tool_name)
        tool.Delete()
        _fusion_state["tools"].pop(params.tool_name, None)
        return _ok({"success": True})
    return _run(_fn)


class _FusionSaveSettingsInput(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    tool_name: str = Field(..., description="Tool whose upstream node tree should be saved")
    file_path: str = Field(..., description="Full output path, e.g. '/Users/me/banner.setting'")


@mcp.tool(
    name="resolve_fusion_save_tool_settings",
    annotations={
        "title": "Save Fusion Tool Settings",
        "readOnlyHint": False,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
)
async def resolve_fusion_save_tool_settings(params: _FusionSaveSettingsInput) -> str:
    """Serialize a tool and everything feeding into it to a .setting file on disk.

    Useful for snapshotting a built graph (e.g. one finished title/overlay)
    so it can be reloaded or drag-dropped onto other comps later. This does
    NOT publish controls or register a Titles-panel template — for the
    type-and-go Inspector experience, use Fusion's own Publish + Create Macro
    steps once you're happy with a build produced here.

    Returns JSON: { "success": bool, "file_path": str }
    """
    def _fn():
        tool = _ftool(params.tool_name)
        ok = tool.SaveSettings(params.file_path)
        return _ok({"success": bool(ok), "file_path": params.file_path})
    return _run(_fn)


class _BuildBannerInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    prefix: str = Field(
        default="Banner",
        description="Name prefix for every node this creates, so multiple instances can coexist without name clashes",
    )
    title: str = Field(..., max_length=24, description="System name — matches its stepper node label")
    step_chip: str = Field(..., description="e.g. 'STEP 03 / 07'")
    heading: str = Field(..., max_length=34)
    body: str = Field(..., max_length=150)
    serves: List[str] = Field(
        ..., min_length=1, max_length=3,
        description="1-3 of: CREDIT, RISK, OPERATIONS, FINANCE, EXECUTIVE — primary first",
    )
    stamp_value: str = Field(..., max_length=8, description="e.g. '< 2 SEC', '94% STP'")
    stamp_label: str = Field(..., max_length=32)
    stepper_labels: List[str] = Field(
        ..., min_length=8, max_length=8,
        description="Labels for the 8 stepper nodes, row 1 (1-4) then row 2 (5-8)",
    )
    active_step: int = Field(
        ..., ge=1, le=8,
        description="1-8 — this node shows CURRENT, earlier nodes COMPLETED, later nodes UPCOMING",
    )


@mcp.tool(
    name="resolve_fusion_build_narration_banner",
    annotations={
        "title": "Build Narration Banner + Stepper",
        "readOnlyHint": False,
        "destructiveHint": False,
        "idempotentHint": False,
        "openWorldHint": False,
    },
)
async def resolve_fusion_build_narration_banner(params: _BuildBannerInput) -> str:
    """Build a 3-zone narration banner + 2-row/8-node journey stepper on the
    attached Fusion composition — a reusable lower-third-style title overlay
    for step-by-step walkthroughs, fully parameterized below.

    Call resolve_fusion_get_comp first. This is a structural first pass —
    matches a typical banner/stepper field list, zone layout, and color
    legend, but treat exact pixel offsets and corner radii as a manual
    finishing pass afterward against your own reference frame. Backdrop
    blur, grid textures, and drop shadows are intentionally not built
    here — see the note at the top of this file's Fusion Compositing section.

    Every field/section is wrapped individually, so one bad input name is
    reported in "errors" without blocking the rest of the build.

    Returns JSON:
    {
      "success": bool,
      "built":  [str],          # node names created successfully
      "errors": { str: str }    # section label -> error message
    }
    """
    def _fn():
        comp = _fcomp()
        built: list[str] = []
        errors: dict[str, str] = {}
        px = params.prefix
        merges: list[Any] = []

        def add(tool_id: str, name: str, x: int, y: int):
            t = comp.AddTool(tool_id, x, y)
            if not t:
                raise RuntimeError(f"AddTool('{tool_id}') failed")
            t.SetAttrs({"TOOLS_Name": name})
            _fusion_state["tools"][name] = t
            built.append(name)
            return t

        def section(label: str, fn):
            try:
                fn()
            except Exception as exc:
                errors[label] = str(exc)

        def text_field(name, content, size, color_hex, cx, cy, xg, yg):
            t = add("TextPlus", name, xg, yg)
            t.SetInput("StyledText", content)
            t.SetInput("Font", "Rajdhani")
            t.SetInput("Size", size / 1080)
            rgba = _hex_rgba(color_hex)
            t.SetInput("Red1", rgba["R"])
            t.SetInput("Green1", rgba["G"])
            t.SetInput("Blue1", rgba["B"])
            t.SetInput("Center", {"X": cx, "Y": cy})
            merges.append(t)
            return t

        # ---- Panel: banner background (rounded gradient rect) -----------------
        def build_panel():
            bg = add("Background", f"{px}_PanelFill", -30, 0)
            bg.SetInput("Type", 1)  # gradient — verify enum value in Inspector, varies by build
            tl_ = _hex_rgba("#070C1A")
            tr_ = _hex_rgba("#0B142A")
            bg.SetInput("TopLeftRed", tl_["R"]);   bg.SetInput("TopLeftGreen", tl_["G"]);   bg.SetInput("TopLeftBlue", tl_["B"])
            bg.SetInput("TopRightRed", tr_["R"]);  bg.SetInput("TopRightGreen", tr_["G"]);  bg.SetInput("TopRightBlue", tr_["B"])

            mask = add("RectangleMask", f"{px}_PanelShape", -30, 1)
            mask.SetInput("Width", 1130 / 1920)
            mask.SetInput("Height", 196 / 1080)
            mask.SetInput("Center", {"X": (48 + 1130 / 2) / 1920, "Y": (48 + 196 / 2) / 1080})
            bg.SetInput("EffectMask", mask)
            merges.append(bg)
        section("panel_fill", build_panel)

        # ---- Zone 1 — content -----------------------------------------------
        section("title",     lambda: text_field(f"{px}_Title",     params.title,     18, "#2FD9E5", 96/1920,  1 - 72/1080,  -25, 2))
        section("step_chip", lambda: text_field(f"{px}_StepChip",  params.step_chip, 12, "#F1F5F9", 260/1920, 1 - 72/1080,  -25, 3))
        section("heading",   lambda: text_field(f"{px}_Heading",   params.heading,   40, "#F1F5F9", 96/1920,  1 - 110/1080, -25, 4))
        section("body",      lambda: text_field(f"{px}_Body",      params.body,      20, "#E2E8F0", 96/1920,  1 - 150/1080, -25, 5))

        # ---- Zone 2 — serves --------------------------------------------------
        def build_serves():
            base_x = (1920 - 48 - 198 - 140) / 1920
            text_field(f"{px}_ServesCaption", "SERVES", 10, "#9FB0C8", base_x, 1 - 70/1080, -25, 6)
            for i, discipline in enumerate(params.serves):
                color = _SERVES_COLORS.get(discipline.upper(), "#F1F5F9")
                text_field(f"{px}_ServesTag{i+1}", discipline.upper(), 11, color, base_x, 1 - (90 + i*22)/1080, -25, 7 + i)
        section("serves", build_serves)

        # ---- Zone 3 — value stamp ----------------------------------------------
        def build_stamp():
            stamp_x = (1920 - 48 - 198 + 28) / 1920
            text_field(f"{px}_StampValue", params.stamp_value, 44, "#2FD9E5", stamp_x, 1 - 90/1080, -25, 10)
            text_field(f"{px}_StampLabel", params.stamp_label, 10.5, "#5EFFCD", stamp_x, 1 - 115/1080, -25, 11)
        section("stamp", build_stamp)

        # ---- Journey stepper (2 rows x 4 nodes) --------------------------------
        def build_stepper():
            col_w, row_h = 258, 22
            base_left = 48
            base_bottom_row2 = 48 + 196 + 14
            for i in range(8):
                row, col = divmod(i, 4)
                state = "completed" if (i + 1) < params.active_step else ("current" if (i + 1) == params.active_step else "upcoming")
                color = {"completed": "#5EFFCD", "current": "#2FD9E5", "upcoming": "#9FB0C8"}[state]
                label = params.stepper_labels[i] if state != "upcoming" else f"{i+1:02d}"

                cx = (base_left + col * col_w + 5) / 1920
                cy_px = base_bottom_row2 + (row_h + 12 if row == 0 else 0) + row_h / 2
                cy = 1 - cy_px / 1080

                dot = add("Background", f"{px}_Node{i+1}Dot", -20, 12 + i)
                rgba = _hex_rgba(color)
                dot.SetInput("TopLeftRed", rgba["R"]); dot.SetInput("TopLeftGreen", rgba["G"]); dot.SetInput("TopLeftBlue", rgba["B"])
                dot_mask = add("EllipseMask", f"{px}_Node{i+1}DotMask", -19, 12 + i)
                dot_mask.SetInput("Width", 10/1920); dot_mask.SetInput("Height", 10/1080)
                dot_mask.SetInput("Center", {"X": cx, "Y": cy})
                dot.SetInput("EffectMask", dot_mask)
                merges.append(dot)

                text_field(f"{px}_Node{i+1}Label", label, 11, color, cx + 18/1920, cy, -18, 12 + i)
        section("stepper", build_stepper)

        # ---- Flatten everything onto MediaOut via a Merge chain ---------------
        def build_output():
            media_out = None
            for t in (comp.GetToolList(False) or {}).values():
                if t.GetAttrs().get("TOOLS_RegID") == "MediaOut":
                    media_out = t
                    break
            if not media_out:
                media_out = add("MediaOut", f"{px}_MediaOut", 0, 20)

            current = None
            for i, layer in enumerate(merges):
                m = add("Merge", f"{px}_Merge{i+1}", -10, 20 + i)
                if current is not None:
                    m.SetInput("Background", current)
                m.SetInput("Foreground", layer)
                current = m
            if current is not None:
                media_out.SetInput("Input", current)
        section("output_merge", build_output)

        return _ok({"success": len(errors) == 0, "built": built, "errors": errors})
    return _run(_fn)


# ──────────────────────────────────────────────────────────────────────────────
# Entry point
# ──────────────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    mcp.run()
