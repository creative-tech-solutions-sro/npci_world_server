-- server/config.lua - AI Provider Configuration (server-only)

Config = Config or {}
Config.AI = {
    -- Choose the AI provider: "nim" (default), "ollama", "gemini", or "openai"
    Provider = "nim",

    -- NVIDIA NIM Configuration (primary - free API-catalog credits, OpenAI-compatible)
    -- API key is read from a convar so it stays out of resource files.
    -- Enable by setting in secrets.cfg: set npci_nim_key "nvapi-..."
    NIM = {
        Endpoint = "https://integrate.api.nvidia.com/v1/chat/completions",
        Model = "nvidia/nemotron-3-ultra-550b-a55b",
        ApiKey = GetConvar('npci_nim_key', ''),
    },

    -- Ollama Configuration (local fallback, no API key needed)
    Ollama = {
        Endpoint = "http://localhost:11434/api/chat",
        Model = "qwen2.5:3b",
    },

    -- Google Gemini Configuration (fallback if NIM/Ollama/OpenAI fails)
    -- API keys are read from convars so they stay out of resource files.
    -- Enable by setting in secrets.cfg: set npci_gemini_key "your-key"
    Gemini = {
        Endpoint = "https://generativelanguage.googleapis.com/v1beta/models",
        Model = "gemini-2.5-flash",
        ApiKey = GetConvar('npci_gemini_key', ''),
    },

    -- OpenAI Configuration
    -- Enable by setting in secrets.cfg: set npci_openai_key "sk-..."
    OpenAI = {
        Endpoint = "https://api.openai.com/v1/chat/completions",
        Model = "gpt-4o-mini",
        ApiKey = GetConvar('npci_openai_key', ''),
    },
}
