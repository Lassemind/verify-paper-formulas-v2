#!/usr/bin/env bash
# Turn the raw, machine-style verification report into the FINAL human-readable
# review (🔴/🟡/🟢 buckets, plain-language "what's wrong / why / fix", and exact
# `main.tex:<line>` references) by a single LLM synthesis pass.
#
# Usage:
#   synthesize_report.sh <raw-report.md> <paper.tex> [out-review.md]
#
# Defaults: out-review.md = <raw-report basename>-review.md next to the raw report.
# Model:    $SYNTH_MODEL (default anthropic/claude-opus-4.8).
#
# The paper is read-only. On any failure the raw report is left untouched and a
# clear message is printed — never a silent empty file.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$HERE/.." && pwd)"

RAW="${1:?usage: synthesize_report.sh <raw-report.md> <paper.tex> [out-review.md]}"
TEX="${2:?usage: synthesize_report.sh <raw-report.md> <paper.tex> [out-review.md]}"
OUT="${3:-}"

[ -f "$RAW" ] || { echo "raw report not found: $RAW" >&2; exit 2; }
[ -f "$TEX" ] || { echo "paper .tex not found: $TEX (skipping synthesis; raw report kept)" >&2; exit 2; }

if [ -z "$OUT" ]; then
  dir="$(cd "$(dirname "$RAW")" && pwd)"; base="$(basename "$RAW")"; stem="${base%.*}"
  OUT="$dir/$stem-review.md"
fi

SYNTH_MODEL="${SYNTH_MODEL:-anthropic/claude-opus-4.8}"
TEXNAME="$(basename "$TEX")"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PROMPT="$WORK/prompt.txt"

# Build the synthesis prompt: instructions + raw report + line-numbered .tex.
{
  cat "$SKILL_ROOT/prompts/synthesize.md"
  printf '\n\n========== RAW REPORT ==========\n\n'
  cat "$RAW"
  printf '\n\n========== PAPER SOURCE (%s, with line numbers) ==========\n\n' "$TEXNAME"
  # number every line so the model can cite main.tex:<line> exactly
  awk '{ printf "%6d\t%s\n", NR, $0 }' "$TEX"
} > "$PROMPT"

echo ">> synthesizing human-readable review with $SYNTH_MODEL ..." >&2
echo ">>   raw:    $RAW" >&2
echo ">>   paper:  $TEX ($(wc -l < "$TEX" | tr -d ' ') lines)" >&2

# Give the synthesis room — it writes a full report. Allow override.
OR_MAX_TOKENS="${SYNTH_MAX_TOKENS:-16384}" \
  bash "$HERE/or_query.sh" "$SYNTH_MODEL" "$PROMPT" > "$WORK/resp.json" 2>/dev/null

OKF="$(jq -r '.ok // false' "$WORK/resp.json" 2>/dev/null || echo false)"
CONTENT="$(jq -r '.content // ""' "$WORK/resp.json" 2>/dev/null || echo "")"

if [ "$OKF" != "true" ] || [ -z "$CONTENT" ]; then
  err="$(jq -r '.error // "empty response"' "$WORK/resp.json" 2>/dev/null || echo 'parse error')"
  echo "!! synthesis failed: $err" >&2
  echo "!! raw report kept at: $RAW (no review written)" >&2
  exit 1
fi

printf '%s\n' "$CONTENT" > "$OUT"
echo ">> done. human-readable review: $OUT" >&2
