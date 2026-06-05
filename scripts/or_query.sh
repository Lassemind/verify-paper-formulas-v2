#!/usr/bin/env bash
# Single OpenRouter chat completion.
# Usage: or_query.sh <model> <prompt-file>
# Reads the prompt body from <prompt-file> (so prompts with quotes/newlines are safe).
# Prints JSON: {"ok": true|false, "requested": "...", "model": "<served model>", "content": "...", "error": "..."}
# max_tokens defaults to 8192 (override with OR_MAX_TOKENS). Retries once if a model
# returns empty content. The API key is resolved from the first available source
# (see below) and NEVER printed.

set -euo pipefail

MODEL="${1:?usage: or_query.sh <model> <prompt-file>}"
PROMPT_FILE="${2:?usage: or_query.sh <model> <prompt-file>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

# Resolve OPENROUTER_API_KEY from the first source that has it:
#   1. $OPENROUTER_ENV          — explicit env-file path, if set
#   2. already-exported env var — e.g. set in the current shell
#   3. <repo>/.env             — local file next to the skill (for cloners)
#   4. ~/.config/openrouter.env — user-wide config
# The repo .env is git-ignored, so it never gets committed.
for f in "${OPENROUTER_ENV:-}" "$REPO_ROOT/.env" "$HOME/.config/openrouter.env"; do
  [ -n "$f" ] && [ -f "$f" ] || continue
  # shellcheck disable=SC1090
  source "$f"
  [ -n "${OPENROUTER_API_KEY:-}" ] && break
done
KEY="${OPENROUTER_API_KEY:-}"
if [ -z "$KEY" ]; then
  echo '{"ok":false,"error":"no OPENROUTER_API_KEY found — set it in the environment, a local .env in the skill folder, or ~/.config/openrouter.env"}'
  exit 3
fi

if [ ! -f "$PROMPT_FILE" ]; then
  echo "{\"ok\":false,\"error\":\"prompt file not found: $PROMPT_FILE\"}"
  exit 2
fi

# max_tokens defaults to 8192 (long physics derivations were truncated at 4096,
# cutting off the final VERDICT line). Override via OR_MAX_TOKENS.
MAX_TOKENS="${OR_MAX_TOKENS:-8192}"

# Build the request body with jq so the prompt is correctly JSON-escaped.
BODY="$(jq -n --arg model "$MODEL" --rawfile prompt "$PROMPT_FILE" --argjson maxtok "$MAX_TOKENS" \
  '{model:$model, messages:[{role:"user", content:$prompt}], max_tokens:$maxtok, temperature:0.2}')"

# One call → parsed JSON line on stdout. Returns nonzero only on transport failure.
do_call() {
  local resp
  resp="$(curl -sS --max-time 240 \
    https://openrouter.ai/api/v1/chat/completions \
    -H "Authorization: Bearer $KEY" \
    -H "Content-Type: application/json" \
    -d "$BODY" 2>&1)" || { echo ""; return 1; }
  echo "$resp" | jq -c --arg model "$MODEL" '
    if .choices and (.choices | length) > 0 then
      {ok:true, requested:$model, model:(.model // $model),
       content:(.choices[0].message.content // "")}
    else
      {ok:false, requested:$model, model:(.model // $model),
       error:(.error.message // "unexpected response")}
    end' 2>/dev/null || echo "{\"ok\":false,\"requested\":\"$MODEL\",\"error\":\"could not parse response\"}"
}

OUT="$(do_call)"
# Auto-retry once if the model returned an empty body (some reasoning models burn
# their budget before emitting text). A single retry recovers most of these.
CONTENT_LEN="$(printf '%s' "$OUT" | jq -r '(.content // "") | length' 2>/dev/null || echo 0)"
OK_FLAG="$(printf '%s' "$OUT" | jq -r '.ok // false' 2>/dev/null || echo false)"
if [ "$OK_FLAG" = "true" ] && [ "${CONTENT_LEN:-0}" -eq 0 ]; then
  OUT="$(do_call)"
fi

if [ -z "$OUT" ]; then
  echo "{\"ok\":false,\"requested\":\"$MODEL\",\"error\":\"curl failed\"}"
else
  echo "$OUT"
fi
