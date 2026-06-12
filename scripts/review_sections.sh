#!/usr/bin/env bash
# Section-by-section paper review (no claim extraction).
#
# Splits the paper at \section boundaries, has each review model check every
# section independently (prompts/section_review.md), runs one whole-paper
# cross-consistency pass (prompts/section_crosscheck.md), then synthesizes a
# German improvement report (prompts/section_synthesize.md).
#
# Usage: review_sections.sh <paper.tex> <out-dir>
# Env:   REVIEW_MODELS  comma-separated review panel
#                       (default: anthropic/claude-fable-5,openai/gpt-5.5)
#        SYNTH_MODEL    synthesis model (default: anthropic/claude-fable-5)
#        MAX_PARALLEL   concurrent API calls (default: 4)
#
# Output: <out-dir>/findings/*.json   raw per-section per-model responses
#         <out-dir>/findings.md       all findings, labeled
#         <out-dir>/improvement-report.md   the deliverable (German)
set -euo pipefail

PAPER="${1:?usage: review_sections.sh <paper.tex> <out-dir>}"
OUT="${2:?usage: review_sections.sh <paper.tex> <out-dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPTS="$HERE/../prompts"

REVIEW_MODELS="${REVIEW_MODELS:-anthropic/claude-fable-5,openai/gpt-5.5}"
SYNTH_MODEL="${SYNTH_MODEL:-anthropic/claude-fable-5}"
MAX_PARALLEL="${MAX_PARALLEL:-4}"
export OR_TIMEOUT="${OR_TIMEOUT:-420}"
# Reasoning models (Fable) spend output budget on thinking before emitting text;
# 8192 starves long sections into empty replies that still bill. Give headroom.
export OR_MAX_TOKENS="${OR_MAX_TOKENS:-24000}"

mkdir -p "$OUT/findings" "$OUT/prompts"
NUM="$OUT/numbered.tex"
cat -n "$PAPER" > "$NUM"
TOTAL="$(wc -l < "$PAPER" | tr -d ' ')"

# Abstract as shared context for the per-section prompts.
ABSTRACT="$OUT/abstract.txt"
sed -n '/\\begin{abstract}/,/\\end{abstract}/p' "$PAPER" > "$ABSTRACT"
[ -s "$ABSTRACT" ] || echo "(no abstract found)" > "$ABSTRACT"

# Section ranges: every \section line starts a section; it runs to the line
# before the next \section (the last one to EOF).
RANGES="$OUT/sections.tsv"
grep -n '^[[:space:]]*\\section' "$PAPER" | cut -d: -f1 \
  | awk -v total="$TOTAL" 'NR>1 {print prev "\t" $1-1} {prev=$1} END {print prev "\t" total}' \
  > "$RANGES"
N_SECTIONS="$(wc -l < "$RANGES" | tr -d ' ')"
[ "$N_SECTIONS" -ge 1 ] || { echo "no \\section found in $PAPER" >&2; exit 1; }
echo "[review] $N_SECTIONS sections, models: $REVIEW_MODELS" >&2

# Build one prompt file per (section, model) and a task list for the fan-out.
TASKS="$OUT/tasks.tsv"
: > "$TASKS"
i=0
while IFS="$(printf '\t')" read -r START END; do
  i=$((i + 1))
  ID="$(printf 'sec%02d_L%s-%s' "$i" "$START" "$END")"
  PFILE="$OUT/prompts/$ID.prompt"
  {
    cat "$PROMPTS/section_review.md"
    printf '\n=== ABSTRACT (context) ===\n'
    cat "$ABSTRACT"
    printf '\n=== SECTION (line-numbered LaTeX, lines %s-%s of main.tex) ===\n' "$START" "$END"
    sed -n "${START},${END}p" "$NUM"
  } > "$PFILE"
  OLD_IFS="$IFS"; IFS=','
  for MODEL in $REVIEW_MODELS; do
    SLUG="$(printf '%s' "$MODEL" | tr '/.' '__')"
    printf '%s\t%s\t%s\n' "$MODEL" "$PFILE" "$OUT/findings/${ID}__${SLUG}.json" >> "$TASKS"
  done
  IFS="$OLD_IFS"
done < "$RANGES"

# Whole-paper cross-consistency pass (first review model only — one call).
XMODEL="${REVIEW_MODELS%%,*}"
XPROMPT="$OUT/prompts/crosscheck.prompt"
{
  cat "$PROMPTS/section_crosscheck.md"
  printf '\n=== PAPER (line-numbered LaTeX) ===\n'
  cat "$NUM"
} > "$XPROMPT"
XSLUG="$(printf '%s' "$XMODEL" | tr '/.' '__')"
printf '%s\t%s\t%s\n' "$XMODEL" "$XPROMPT" "$OUT/findings/crosscheck__${XSLUG}.json" >> "$TASKS"

# Fan out in waves of MAX_PARALLEL (portable: no wait -n on macOS bash 3.2).
running=0
while IFS="$(printf '\t')" read -r MODEL PFILE OFILE; do
  # Resume support: skip a call only if it produced a usable result
  # (ok:true with non-empty content) — empty/failed/truncated results re-run.
  if [ -s "$OFILE" ] && [ "$(jq -r 'if .ok == true then (.content // "") | length else 0 end' "$OFILE" 2>/dev/null || echo 0)" -gt 0 ]; then
    continue
  fi
  "$HERE/or_query.sh" "$MODEL" "$PFILE" > "$OFILE" &
  running=$((running + 1))
  if [ "$running" -ge "$MAX_PARALLEL" ]; then
    wait
    running=0
    echo "[review] wave done ($(ls "$OUT/findings" | wc -l | tr -d ' ')/$(wc -l < "$TASKS" | tr -d ' ') calls)" >&2
  fi
done < "$TASKS"
wait
echo "[review] all calls done" >&2

# Assemble labeled findings.
FINDINGS="$OUT/findings.md"
: > "$FINDINGS"
for F in "$OUT"/findings/*.json; do
  BASE="$(basename "$F" .json)"
  OK="$(jq -r '.ok // false' "$F" 2>/dev/null || echo false)"
  printf '\n## %s\n\n' "$BASE" >> "$FINDINGS"
  if [ "$OK" = "true" ]; then
    jq -r '.content' "$F" >> "$FINDINGS"
  else
    printf '(no result: %s)\n' "$(jq -r '.error // "unknown"' "$F" 2>/dev/null)" >> "$FINDINGS"
  fi
done
echo "[review] findings assembled: $FINDINGS" >&2

# Synthesis: verify + dedupe + German improvement report.
SPROMPT="$OUT/prompts/synthesize.prompt"
{
  cat "$PROMPTS/section_synthesize.md"
  printf '\n=== PAPER (line-numbered LaTeX) ===\n'
  cat "$NUM"
  printf '\n=== ROH-BEFUNDE DER REVIEWER ===\n'
  cat "$FINDINGS"
} > "$SPROMPT"
REPORT="$OUT/improvement-report.md"
OR_MAX_TOKENS="${SYNTH_MAX_TOKENS:-30000}" OR_TIMEOUT=900 \
  "$HERE/or_query.sh" "$SYNTH_MODEL" "$SPROMPT" > "$OUT/synthesis.json"
if [ "$(jq -r '.ok' "$OUT/synthesis.json")" = "true" ]; then
  jq -r '.content' "$OUT/synthesis.json" > "$REPORT"
  echo "[review] report: $REPORT" >&2
else
  echo "[review] synthesis FAILED: $(jq -r '.error' "$OUT/synthesis.json") — raw findings kept: $FINDINGS" >&2
  exit 1
fi
