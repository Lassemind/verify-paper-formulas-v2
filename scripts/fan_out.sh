#!/usr/bin/env bash
# Fan a single prompt out to all configured models in parallel via or_query.sh.
# Usage: fan_out.sh <prompt-file> [model1 model2 ...]
# Model set is chosen in this order of precedence:
#   1. explicit CLI args            (fan_out.sh prompt m1 m2 ...)
#   2. $VPF_MODELS                  (comma- or space-separated list)
#   3. DEFAULT_MODELS set below
# $VPF_MODELS is the no-edit escape hatch: e.g. to drop a slow/empty model for a
# whole run, export VPF_MODELS without it — no need to touch this file.
#   VPF_MODELS="anthropic/claude-opus-4.8,openai/gpt-5.5,google/gemini-3.1-pro-preview,x-ai/grok-4.3"
# Prints one JSON object per line (JSONL), one per model. A model that fails
# still emits a line with "ok":false — it never aborts the others.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_FILE="${1:?usage: fan_out.sh <prompt-file> [models...]}"
shift || true

DEFAULT_MODELS=(
  "anthropic/claude-opus-4.8"
  "openai/gpt-5.5"
  "google/gemini-3.1-pro-preview"
  "x-ai/grok-4.3"
  "deepseek/deepseek-v4-pro"
)

if [ "$#" -gt 0 ]; then
  # 1. explicit CLI args win
  MODELS=("$@")
elif [ -n "${VPF_MODELS:-}" ]; then
  # 2. env override: split on commas and/or whitespace, trim, drop blanks
  MODELS=()
  _list="$(printf '%s' "$VPF_MODELS" | tr ',' ' ')"
  for m in $_list; do
    [ -n "$m" ] && MODELS+=("$m")
  done
  if [ "${#MODELS[@]}" -eq 0 ]; then MODELS=("${DEFAULT_MODELS[@]}"); fi
else
  # 3. built-in default set
  MODELS=("${DEFAULT_MODELS[@]}")
fi

pids=()
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

i=0
for m in "${MODELS[@]}"; do
  out="$tmpdir/$i.json"
  ( bash "$HERE/or_query.sh" "$m" "$PROMPT_FILE" > "$out" 2>/dev/null \
      || echo "{\"ok\":false,\"requested\":\"$m\",\"error\":\"query crashed\"}" > "$out" ) &
  pids+=("$!")
  i=$((i + 1))
done

for p in "${pids[@]}"; do
  wait "$p" || true
done

for j in $(seq 0 $((i - 1))); do
  cat "$tmpdir/$j.json"
  echo
done
