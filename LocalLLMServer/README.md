# LocalLLM Server (iPad)

On-device LLM (MLX Swift) + token-protected OpenAI-style HTTP API on your Wi-Fi.
Endpoints: GET /health (no auth), GET /v1/models, POST /v1/chat/completions (JSON or SSE with "stream": true).

## Build without a Mac (free)
1. Create a **public** GitHub repo, upload everything in this folder (keep `.github/`).
2. Actions tab → "Build IPA" → Run workflow. When it's green, download the `LocalLLMServer-ipa` artifact and unzip it.
3. On your HP laptop install SideStore, AltStore, or Sideloadly and sign in with a free Apple ID; install `LocalLLMServer.ipa` on the iPad (enable Developer Mode on the iPad first: Settings > Privacy & Security).
4. Free-account installs expire after 7 days: re-sign them.

## Use
Model tab → pick a preset → Download & load (needs internet once). API Server tab → Start server → allow Local Network → copy the curl command and run it from another device on the same Wi-Fi.

## Limits
- Untested first draft: expect to fix compile errors against the exact mlx-swift-lm release.
- Server runs only while the app is open; iPadOS suspends it in the background.
- Plain HTTP, one generation at a time, 256 KB request cap, max 1024 output tokens.
- Not full OpenAI compatibility: no usage counts, tools, or image content.
- No increased-memory entitlement (not available on free accounts), so keep models small.
