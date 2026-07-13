# Running `davinci_resolve_mcp` on Windows (DaVinci Resolve Studio)

This connects **Claude Desktop** on your Windows laptop directly to your real, running copy
of DaVinci Resolve — including the new Fusion-building tools
(`resolve_fusion_*`) that can construct the narration banner + stepper from
the locked spec.

**Requires DaVinci Resolve Studio.** The Free edition does not support
external scripting (confirmed as of Resolve 19.1+, ~Feb 2025 onward — this
is an undocumented Free-edition restriction, not a relocated setting). On
Free, `server.py` cannot connect to Resolve at all; use the
`bridge\ClaudeBridge.lua` workaround instead (see `BRIDGE_SETUP_GUIDE.md`).

Important: this only works inside **Claude Desktop**, not inside Cowork —
the MCP server runs as a local process on your Windows machine and talks to
DaVinci Resolve over its local scripting API. Cowork's cloud sandbox has no
way to reach an app running on your laptop.

---

## 0. What you need on the Windows laptop

- **DaVinci Resolve Studio** — installed and opened at least once. (Free
  edition will not work with this server; see the note above.)
- **Python 3.9–3.11** for Windows, from python.org (check "Add python.exe to PATH" during install).
- **Claude Desktop** installed and signed in.
- The `davinci_resolve_mcp` folder copied over from this Mac — zip it, or push it to a git repo / OneDrive / USB stick, then unzip it somewhere simple like `C:\Tools\davinci_resolve_mcp\`.

## 1. Turn on external scripting in Resolve

Open DaVinci Resolve → **DaVinci Resolve → Preferences → General** (or **Preferences → System → General** depending on version) → find **External scripting using** → set it to **Local**. Restart Resolve.

## 2. Set the Windows environment variables

These tell Python where Resolve's scripting API lives. Open **Start → Edit the system environment variables → Environment Variables**, and add these three **System variables** (not just user variables, so they're available no matter how Claude Desktop launches Python):

| Variable | Value |
|---|---|
| `RESOLVE_SCRIPT_API` | `C:\ProgramData\Blackmagic Design\DaVinci Resolve\Support\Developer\Scripting` |
| `RESOLVE_SCRIPT_LIB` | `C:\Program Files\Blackmagic Design\DaVinci Resolve\fusionscript.dll` |
| `PYTHONPATH` | `%PYTHONPATH%;%RESOLVE_SCRIPT_API%\Modules` |

Log out and back in (or just reboot) so every app picks up the new variables — this is the step people most often skip.

## 3. Install Python dependencies

Open Command Prompt and run:

```
cd C:\Tools\davinci_resolve_mcp
pip install -r requirements.txt
pip install pydantic
```

## 4. Point Claude Desktop at the server

Open `%APPDATA%\Claude\claude_desktop_config.json` in a text editor (create it if it doesn't exist yet). Add this block — merge it with whatever's already there rather than replacing the whole file:

```json
{
  "mcpServers": {
    "davinci_resolve_mcp": {
      "command": "python",
      "args": [
        "C:\\Tools\\davinci_resolve_mcp\\server.py"
      ]
    }
  }
}
```

Use double backslashes in the path, exactly as above. Save, then fully quit and reopen Claude Desktop (quit from the system tray icon, not just closing the window).

## 5. Test the connection

1. Open DaVinci Resolve, open (or create) a project, open (or create) a timeline. Resolve **must be running with a project open** before you test.
2. In Claude Desktop, start a new chat and say: *"Call resolve_get_info."*
3. You should get back something like `{"product_name": "DaVinci Resolve", "version": "...", "current_page": "edit"}`.

If that works, the connector is live — you're no longer editing files, you're actually driving your real project.

## 6. Try the Fusion banner builder

1. On the Edit page, drag a **Solid Color** generator (Effects Library → Generators) onto a video track above your footage, or use any blank Titles clip. Select it.
2. In Claude Desktop: *"Call resolve_fusion_get_comp on the selected clip."*
3. Then: *"Build the narration banner — title 'ONBOARDING', step chip 'STEP 01 / 05', heading 'ACCOUNT SETUP', body 'Walks the user through creating their profile and preferences.', serves CREDIT/RISK/OPS, stamp value '< 30 SEC', stamp label 'AVERAGE COMPLETION TIME', stepper labels [...], active step 1."* — this calls `resolve_fusion_build_narration_banner`.
4. Switch to the Fusion page in Resolve and look at what got built. Check the response Claude shows you — the `errors` field lists anything that failed by name, which is normal on a first run and gets fixed by asking Claude to adjust specific `resolve_fusion_set_inputs` calls once you can see the actual parameter names in the Inspector.

## Troubleshooting

**"DaVinciResolveScript module not found"** — `RESOLVE_SCRIPT_API`/`PYTHONPATH` aren't set or Claude Desktop was opened before you set them. Recheck step 2, reboot, retry.

**"DaVinci Resolve is not running"** — launch Resolve first; the server only connects to an already-running instance, it can't start Resolve itself.

**"No project is open" / "No timeline is active"** — open or create a project and timeline in Resolve before calling any tool that needs one.

**Fusion tool calls fail with an unknown input name** — expected on the first run of `resolve_fusion_build_narration_banner` (see the guide's caveat: it was written without a live Resolve to test against). Open the Fusion Inspector on the tool in question, find the correct input name, then ask Claude to re-apply it with `resolve_fusion_set_inputs`.

**Nothing shows up in Claude Desktop's tool list** — the config JSON is probably malformed (a trailing comma is the usual culprit). Validate it in any JSON linter, then fully quit/reopen Claude Desktop.

**Free vs. Studio** — external scripting (and therefore this entire server) requires **Studio**. Free does not expose the scripting API at all — this is not limited to specific render codecs/effects, and there is no Preferences toggle to enable it on Free. If you're on Free, use `bridge\ClaudeBridge.lua` instead (see `BRIDGE_SETUP_GUIDE.md`).
