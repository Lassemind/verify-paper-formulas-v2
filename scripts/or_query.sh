#!/usr/bin/env bash
# Single OpenRouter chat completion.
# Usage: or_query.sh <model> <prompt-file>
# Reads the prompt body from <prompt-file> (so prompts with quotes/newlines are safe).
# Prints JSON: {"model": "<served model>", "ok": true|false, "content": "...", "error": "..."}
# The API key is read from ~/.config/openrouter.env and NEVER printed.

set -euo pipefail

MODEL="${1:?usage: or_query.sh <model> <prompt-file>}"
PROMPT_FILE="${2:?usage: or_query.sh <model> <prompt-file>}"

ENV_FILE="${OPENROUTER_ENV:-$HOME/.config/openrouter.env}"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi
KEY="${OPENROUTER_API_KEY:-}"
if [ -z "$KEY" ]; then
  echo '{"ok":false,"error":"no OPENROUTER_API_KEY in env (~/.config/openrouter.env)"}'
  exit 3
fi

if [ ! -f "$PROMPT_FILE" ]; then
  echo "{\"ok\":false,\"error\":\"prompt file not found: $PROMPT_FILE\"}"
  exit 2
fi

# Build the request body with jq so the prompt is correctly JSON-escaped.
BODY="$(jq -n --arg model "$MODEL" --rawfile prompt "$PROMPT_FILE" \
  '{model:$model, messages:[{role:"user", content:$prompt}], max_tokens:4096, temperature:0.2}')"

RESP="$(curl -sS --max-time 180 \
  https://openrouter.ai/api/v1/chat/completions \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d "$BODY" 2>&1)" || {
    echo "{\"ok\":false,\"model\":\"$MODEL\",\"error\":\"curl failed\"}"
    exit 0
  }

# Parse: success path has .choices[0].message.content; error path has .error.message.
echo "$RESP" | jq -c --arg model "$MODEL" '
  if .choices and (.choices | length) > 0 then
    {ok:true, requested:$model, model:(.model // $model),
     content:(.choices[0].message.content // "")}
  else
    {ok:false, requested:$model, model:(.model // $model),
     error:(.error.message // "unexpected response")}
  end' 2>/dev/null || echo "{\"ok\":false,\"requested\":\"$MODEL\",\"error\":\"could not parse response\"}"
