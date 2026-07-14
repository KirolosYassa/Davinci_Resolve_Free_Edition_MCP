# Alternative: Local Ollama Orchestrator (NOT TESTED — theory only)

**Status: theoretical, unaddressed.** Nothing below has been built or run.
This file exists to park the idea so it isn't lost, not as a spec to
follow blindly. Treat every claim here as unverified until someone
actually tries it against real Resolve.

## The idea

Replace Claude as the thing driving `bridge/ClaudeBridge.lua` with a
locally-hosted model served via [Ollama](https://ollama.com), running on
the user's own GPU. The bridge protocol (`command.json` in, `result.json`
out, manual trigger inside Resolve) already has a human-in-the-loop pause
built in, so a local model wouldn't add latency that isn't already there
— it would just remove the dependency on Claude/cloud for this loop.

## Sketch of the architecture

1. Ollama serves a tool-calling-capable model locally (candidates:
   `qwen2.5-coder`, `llama3.1`/`3.3`, `mistral-nemo` — chosen for
   function-calling support via Ollama's OpenAI-compatible API).
2. A small Python orchestrator script:
   - loads `PROJECT_LOG.md` and the "Fusion Parameter Cheat Sheet"
     section as system context
   - exposes two tools to the model: `write_command(batch)` (writes
     `bridge/command.json`) and `read_result()` (reads
     `bridge/result.json`)
   - loops: model proposes a command batch → user manually triggers the
     bridge inside Resolve → orchestrator feeds the result back → model
     decides the next step or reports the task done
3. No changes needed to `ClaudeBridge.lua` itself — it's agnostic to
   what wrote `command.json`.

## Why this was set aside (for now)

This project leans on precision that smaller local models tend to get
wrong more often than Claude does in practice so far:

- exact Fusion input names, including documented dead ends (e.g.
  `RectangleMask.Border`/`BorderWidth` are accepted with no error but
  silently have zero visual effect — a model without that specific
  knowledge baked in will confidently reach for them)
- normalized 0–1 coordinate math, bottom-up Y, width-based normalization
  for both axes
- staying internally consistent with a project log that grows every
  session

7B–14B models (what a single consumer GPU runs comfortably) are the
likeliest to drift here. 30B+ class models narrow the gap but need
meaningfully more VRAM (roughly 24GB+ to run comfortably).

## A middle path, if this gets revisited

Keep Claude for planning / spatial-reasoning decisions (what a layer
should look like, cheat-sheet lookups, catching dead-end parameters),
and hand the local model only the **mechanical, repetitive** batches —
e.g. generating N node dots or connectors that are the same pattern
repeated with different coordinates. That's the part small local models
are most likely to get right consistently, and it's also the part that's
tedious to hand-write batches for by hand.

## Open questions if anyone picks this up later

- Does Ollama's tool-calling reliably produce valid JSON for a
  `command.json` batch on the first try, or does it need retry/repair
  logic?
- Which model is the actual floor for "gets Fusion input names right
  without inventing them" — untested, would need a small eval against
  the cheat sheet in `PROJECT_LOG.md`.
- Worth trying the "mechanical batches only" middle path before writing
  off local models for the harder parts entirely.
