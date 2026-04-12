# File Inventory

## Source Code

| File | Lines | Purpose |
|------|-------|---------|
| `Sources/Savanna/Shaders/savanna.metal` | ~730 | **THE kernel.** All animal behaviour: sense→compute→emit, scent diffusion, grass growth, census. Every parameter lives here. |
| `Sources/Savanna/HexGrid.swift` | ~120 | Hex grid builder. 7-colouring formula, neighbour adjacency, Morton Z-curve. |
| `Sources/Savanna/MetalEngine.swift` | ~230 | GPU orchestration. Buffers, pipeline setup, kernel dispatch order. 7 colour groups + 4 scent + grass + census = 13 dispatches/tick. |
| `Sources/Savanna/MetalEngine+Export.swift` | ~30 | Read entity buffer back to CPU. Write snapshot binary. |
| `Sources/Savanna/SavannaState.swift` | ~170 | World init. Water lakes (flood-fill), grass placement, zebra herds (Gaussian), lion dispersal. Age pyramid. |
| `Sources/Savanna/SimRecorder.swift` | ~120 | Ring buffer (50K frames in unified memory). GPU blit recording. Playback. |
| `Sources/Savanna/SimRecorder+Archive.swift` | ~110 | Save/load .savanna scenario files. Binary format. |
| `Sources/SavannaCLI/main.swift` | ~180 | CLI runner. Tick loop, telemetry, spacetime zoom, speed control, archive commands. |

## HTML

| File | Purpose |
|------|---------|
| `index.html` | **GitHub landing page.** Interactive 8-slide presentation with Web Speech narration. Self-contained, works offline. |
| `savanna_live.html` | Live renderer. Polls snapshot binary, draws to canvas. HUD, stats panel, mixer, spacetime zoom. |
| `about.html` | Three-tier explanation (everyone / curious / engineers). |
| `presentation.html` | Local presentation with pre-generated audio (Kokoro George / Jamie Premium). |
| `voice_mixer.html` | TTS voice blending tool (local only, not on GitHub). |

## Configuration

| File | Purpose |
|------|---------|
| `Package.swift` | Swift Package Manager config. Targets: Savanna (lib), SavannaCLI (exe). |
| `LICENSE` | GPL v3. |
| `.gitignore` | Build artifacts, scenarios (too large for git). |

## Documentation

| File | Purpose |
|------|---------|
| `README.md` | Project overview, performance, architecture, quick start. |
| `INVENTORY.md` | This file. |
| `scenarios/README.md` | Scenario file format specification. |
| `tour.sh` | Voice-narrated tour script (3 levels × 1 min). |

## Scenario Files (.savanna)

| Section | Size | Content |
|---------|------|---------|
| Header | 256 bytes | Magic "SAVANNA\0", version, dimensions, seed, timestamp, tick range |
| Frame Meta | N × 24 bytes | Tick number, day/night, grass/zebra/lion census per frame |
| Raw Frames | N × 1,048,576 bytes | Entity buffer per frame (1 byte per cell) |

Scenarios are deterministic. Same seed + same parameters = identical frames.
SHA-256 of the raw frames section can be used for verification.

## Runtime Files (not in repo)

| File | Purpose |
|------|---------|
| `/tmp/savanna_state.bin` | Current tick snapshot (16-byte header + 1MB entities) |
| `/tmp/savanna_telemetry.json` | Live census + compute stats (updated every 10 ticks) |
| `/tmp/savanna_speed.txt` | Spacetime zoom speed multiplier |
| `/tmp/savanna_sleep.txt` | Spacetime zoom sleep duration |
| `/tmp/savanna_cmd.txt` | Commands (archive, etc.) |
| `/tmp/savanna_server.py` | HTTP server (port 8765) |
