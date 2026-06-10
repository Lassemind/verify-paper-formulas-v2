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
# Default temperature 0.2 (verification, not ideation). Override via OR_TEMP.
TEMP="${OR_TEMP:-0.2}"

# Per-call wall-clock cap (seconds). The empty-content retry uses a SHORTER cap
# (OR_RETRY_TIMEOUT, default = half) so a reasoning model that burned its budget
# and returned nothing doesn't cost a second full timeout before we give up.
TIMEOUT="${OR_TIMEOUT:-240}"
RETRY_TIMEOUT="${OR_RETRY_TIMEOUT:-$((TIMEOUT / 2))}"
CURL_TIMEOUT="$TIMEOUT"   # do_call reads this; lowered before the empty-retry

# Build the request body with jq so the prompt is correctly JSON-escaped.
BODY="$(jq -n --arg model "$MODEL" --rawfile prompt "$PROMPT_FILE" \
  --argjson maxtok "$MAX_TOKENS" --argjson temp "$TEMP" \
  '{model:$model, messages:[{role:"user", content:$prompt}], max_tokens:$maxtok, temperature:$temp}')"

# One call → parsed JSON line on stdout. Returns nonzero only on transport failure.
# The HTTP status code is captured separately (curl -w) and exposed via the global
# HTTP_CODE so the caller can back off on 429 (rate limit) / 5xx without parsing it
# out of the body.
HTTP_CODE=000
do_call() {
  local raw resp
  # append the status code on its own trailing line, then split it off
  raw="$(curl -sS --max-time "$CURL_TIMEOUT" -w '\n%{http_code}' \
    https://openrouter.ai/api/v1/chat/completions \
    -H "Authorization: Bearer $KEY" \
    -H "Content-Type: application/json" \
    -d "$BODY" 2>&1)" || { HTTP_CODE=000; echo ""; return 1; }
  HTTP_CODE="${raw##*$'\n'}"          # last line = status code
  resp="${raw%$'\n'*}"               # everything before it = body
  echo "$resp" | jq -c --arg model "$MODEL" '
    if .choices and (.choices | length) > 0 then
      {ok:true, requested:$model, model:(.model // $model),
       content:(.choices[0].message.content // "")}
    else
      {ok:false, requested:$model, model:(.model // $model),
       error:(.error.message // "unexpected response")}
    end' 2>/dev/null || echo "{\"ok\":false,\"requested\":\"$MODEL\",\"error\":\"could not parse response\"}"
}

# Call with backoff on rate-limit / transient server errors. OpenRouter (and the
# upstream providers) cap *concurrent* requests per model; when run_batch.sh fans
# many claims out at once, a few calls can bounce with 429/503. Two short backoffs
# recover them instead of losing the claim to "no result".
call_with_backoff() {
  local out delay
  for delay in 0 2 5; do
    [ "$delay" -gt 0 ] && sleep "$delay"
    out="$(do_call)"
    case "$HTTP_CODE" in
      429|500|502|503|504) continue ;;   # transient → back off and retry
      *) printf '%s' "$out"; return 0 ;;  # success or a real error → done
    esac
  done
  printf '%s' "$out"   # exhausted retries: return the last (rate-limited) result
}

OUT="$(call_with_backoff)"
# Auto-retry once if the model returned an empty body (some reasoning models burn
# their budget before emitting text). A single retry recovers most of these.
CONTENT_LEN="$(printf '%s' "$OUT" | jq -r '(.content // "") | length' 2>/dev/null || echo 0)"
OK_FLAG="$(printf '%s' "$OUT" | jq -r '.ok // false' 2>/dev/null || echo false)"
if [ "$OK_FLAG" = "true" ] && [ "${CONTENT_LEN:-0}" -eq 0 ]; then
  CURL_TIMEOUT="$RETRY_TIMEOUT"   # the model already stalled once — don't wait the full cap again
  OUT="$(call_with_backoff)"
fi

if [ -z "$OUT" ]; then
  echo "{\"ok\":false,\"requested\":\"$MODEL\",\"error\":\"curl failed\"}"
else
  echo "$OUT"
fi
