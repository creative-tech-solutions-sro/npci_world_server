# Installing NPCI

Two paths: **local development** (your PC, txAdmin default server) or **a live game server** (VPS/dedicated, headless). Both use the same resource — only the AI stack installation differs.

---

## 1. Prerequisites

| Component | Needed for | Check with |
|---|---|---|
| FXServer (FiveM server artifacts) | running the resource | `FXServer.exe --version` |
| ESX Legacy (`es_extended`) | player data, notifications, jobs | `ensure es_extended` in `server.cfg` |
| `oxmysql` | `npci_memory` persistence | `ensure oxmysql` |
| `pma-voice` | proximity/voice integration | `ensure pma-voice` |
| MySQL / MariaDB | database | `mysql --version` |
| **NVIDIA NIM key** (recommended) | primary LLM — free API-catalog credits | `set npci_nim_key` in `secrets.cfg` |
| **Ollama** (optional fallback) | local LLM, no API key | `ollama --version` |
| **Python 3.9+** | TTS/STT sidecar | `python --version` |
| Internet | Edge TTS synthesis (and NIM/Gemini/OpenAI if used) | ping 8.8.8.8 |

Python packages for the sidecar:

```bat
pip install flask waitress openai-whisper edge-tts
```

> `openai-whisper` pulls PyTorch (large download, CPU is fine — the sidecar forces `fp16=False`). Skip it only if you disable transcription and use browser speech recognition exclusively.

Optional — local fallback model (only if you run Ollama):

```bat
ollama pull qwen2.5:3b
```

---

## 2. Install the resource

1. Copy the `npci_world_server` folder into your server's resources (root or a category folder):

   ```
   resources/[scripts]/npci_world_server
   ```

2. Add to `server.cfg` **after** its dependencies:

   ```cfg
   ensure oxmysql
   ensure pma-voice
   ensure npci_world_server
   ```

3. Database: nothing to import. On first start `server/sv_setupdatabase.lua` runs:

   ```sql
   CREATE TABLE IF NOT EXISTS npci_memory (
       id INT AUTO_INCREMENT PRIMARY KEY,
       player_identifier VARCHAR(60) NOT NULL,
       npc_id VARCHAR(100) NOT NULL,
       conversation_history LONGTEXT,
       current_routine VARCHAR(50) DEFAULT 'WANDER',
       target_location VARCHAR(100),
       last_coords VARCHAR(255),
       long_term_summary TEXT,
       UNIQUE KEY unique_interaction (player_identifier, npc_id)
   )
   ```

   (Reference copy: `npci_memory.sql`.)

---

## 3. Configure the AI backend

`server/config.lua`:

```lua
Config.AI = {
    Provider = "nim",                         -- "nim" | "ollama" | "gemini" | "openai"
    NIM     = { Endpoint = "https://integrate.api.nvidia.com/v1/chat/completions",
                Model    = "google/diffusiongemma-26b-a4b-it",
                ApiKey   = GetConvar('npci_nim_key', '') },
    Ollama  = { Endpoint = "http://localhost:11434/api/chat",
                Model    = "qwen2.5:3b" },
    Gemini  = { Endpoint = "https://generativelanguage.googleapis.com/v1beta/models",
                Model    = "gemini-2.5-flash",
                ApiKey   = GetConvar('npci_gemini_key', '') },
    OpenAI  = { Endpoint = "https://api.openai.com/v1/chat/completions",
                Model    = "gpt-4o-mini",
                ApiKey   = GetConvar('npci_openai_key', '') },
}
```

- **NVIDIA NIM (default):** grab a free API key at [build.nvidia.com](https://build.nvidia.com)
  (API-catalog credits cover prototyping) and set it in `secrets.cfg` (executed by `server.cfg`):

  ```cfg
  set npci_nim_key "nvapi-..."
  ```

  Fast model picked for NPC chat latency; change `Config.AI.NIM.Model` to any chat model from
  [build.nvidia.com/models](https://build.nvidia.com/models).

- **Local Ollama (offline fallback):** install Ollama, `ollama serve`, `ollama pull qwen2.5:3b`.
- **Gemini/OpenAI fallback:** in `secrets.cfg`:

  ```cfg
  set npci_gemini_key "AIza..."
  set npci_openai_key "sk-..."
  ```

  Keys live in convars, never in the resource. The provider chain tries the primary first, then
  every other configured backend automatically.

---

## 4. Voice sidecar (TTS + STT)

The sidecar serves `127.0.0.1:5001` (localhost only):

```bat
cd /d path\to\server
python stt_sidecar.py
```

Expected banner:

```
======================================================
      NPCI PRODUCTION ASYNCHRONOUS ENGINE ONLINE
      Running on Port 5001 with 8 Dedicated Workers
======================================================
```

Endpoints: `POST /transcribe` (Whisper), `POST /synthesize` (Edge TTS), `POST /purge` (voice registry).

Wire it into your startup (example `start_server.bat` fragment):

```bat
netstat -an | find ":5001 " >NUL
if errorlevel 1 (
    start "WhisperSTT" cmd /c "python stt_sidecar.py"
    timeout /t 5
)
```

Auto-start with the server (Linux systemd / Windows task scheduler / Docker sidecar — anything that keeps it alive).

---

## 5. In-game keys

Players set bindings under **Esc → Settings → Key Bindings → FiveM**:

| Default | Command | Meaning |
|---|---|---|
| **E** | `npci_interact` | talk / stop talking |
| **N** | `+npc_ptt` / `-npc_ptt` | hold to speak (voice STT) |
| **O** | `toggleNpcVoice` | toggle voice replies |
| **Y** | `npci_multi_add` | add targeted NPC to conversation (ACE) |

Voice chat requires group **admin / associate / elite**. Multi-NPC requires:

```cfg
add_ace group.admin npci.multi allow
```

---

## 6. First-run checklist

1. `ensure npci_world_server` — console shows table migration (first run) with no red errors.
2. Walk to any pedestrian → **E** → thinking dots appear → type `/t hi` → LLM reply within a second (NVIDIA NIM).
3. `/toggleNpcVoice` on → reply is spoken with a neural voice (requires sidecar on :5001 + internet).
4. Hold **N** near an NPC (elevated group only) → speak → your words are transcribed and sent.
5. Text an NPC's number from the in-game phone → AI SMS reply.
6. Re-meet the same NPC later → it references your previous conversation (`npci_memory`).

---

## 7. Troubleshooting

| Symptom | Fix |
|---|---|
| No reply, console `[NVIDIA NIM Error]` 401/403 | `set npci_nim_key "nvapi-..."` set in `secrets.cfg`? Restart FXServer after editing it |
| No reply, console `Ollama` errors | NIM key missing/down → fallback: `ollama serve` running? `curl http://localhost:11434/api/tags` shows `qwen2.5:3b`? |
| Reply but no voice | Sidecar on :5001 (`netstat -an \| find ":5001"`), `pip show edge-tts`, internet up |
| STT returns empty | `openai-whisper` installed, `fp16=False` path OK; check sidecar logs for torch errors |
| `Failed to load dependency` | `ensure oxmysql` / `es_extended` / `pma-voice` before `npci_world_server` |
| API key ignored | Convar set in `secrets.cfg` **and** `exec secrets.cfg` runs before resources; restart FXServer |
| NPCs answer but ignore memory | Table missing → check `sv_setupdatabase.lua` ran; `SHOW TABLES LIKE 'npci_memory'` |
| Voice command says "reserved" | Feature-flagged extras are disabled in this build (`Config.EnableCompanionExtras = false`) |
| Phrases like "follow me" do nothing | Intentional — follow/driving commands were removed from this package |

---

## 8. Upgrading

1. Stop the server (or `stop npci_world_server`).
2. Replace the resource folder.
3. Start again — `sv_setupdatabase.lua` only creates missing tables/columns, existing memory is preserved.
4. Re-apply any local edits you made to `config.lua` / `server/config.lua`.

## 9. Uninstalling

```cfg
# comment out in server.cfg
# ensure npci_world_server
```

Optionally drop the table:

```sql
DROP TABLE IF EXISTS npci_memory;
```

Stop the sidecar (`python` process on port 5001). No other files are written outside the resource and the database.
