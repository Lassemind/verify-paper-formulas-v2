#!/usr/bin/env bash
# Orchestrate a full two-round verification of ONE claim across all models.
# Usage: run_claim.sh <claim-file> [out-dir]
#
# <claim-file> is a plain-text file with two sections marked exactly like this:
#   === CLAIM ===
#   <the paper's formula / derivation to verify>
#   === CONTEXT ===
#   <surrounding definitions and symbols>
#
# It runs:
#   Round 1 — fill prompts/derive.md, fan out to all models (independent derivation)
#   digest  — collect Round-1 outputs
#   Round 2 — fill prompts/refute.md with the digest, fan out (adversarial refute)
# and prints a verdict tally. Raw JSONL for both rounds is written to <out-dir>.
#
# This driver exists because doing it by hand is error-prone (e.g. shell
# word-splitting of the model list). Everything goes through fan_out.sh / or_query.sh.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$HERE/.." && pwd)"
CLAIM_FILE="${1:?usage: run_claim.sh <claim-file> [out-dir]}"
OUT_DIR="${2:-$(mktemp -d)}"
mkdir -p "$OUT_DIR"

if [ ! -f "$CLAIM_FILE" ]; then
  echo "claim file not found: $CLAIM_FILE" >&2
  exit 2
fi

# --- split the claim file into CLAIM, CONTEXT and (optional) NUMBERS -------
# Sections are delimited by lines like "=== CLAIM ===", "=== CONTEXT ===",
# "=== NUMBERS ===" (in that order). NUMBERS is optional: when present it turns
# the run into a *numeric* check — the models must plug the values in, compute,
# and compare against the paper's reference result (Dieter's "test cases").
CLAIM_TXT="$(awk '/^=== *CLAIM *===/{f=1;next} /^=== *(CONTEXT|NUMBERS) *===/{f=0} f' "$CLAIM_FILE")"
CONTEXT_TXT="$(awk '/^=== *CONTEXT *===/{f=1;next} /^=== *NUMBERS *===/{f=0} f' "$CLAIM_FILE")"
NUMBERS_TXT="$(awk '/^=== *NUMBERS *===/{f=1;next} f' "$CLAIM_FILE")"
if [ -z "$CLAIM_TXT" ]; then
  echo "no '=== CLAIM ===' section found in $CLAIM_FILE" >&2
  exit 2
fi

# If a NUMBERS section is given, fold it into the context as an explicit
# numeric-check instruction. Both prompts already ask for units + sanity
# checks, so no prompt-file change is needed.
if [ -n "$NUMBERS_TXT" ]; then
  CONTEXT_TXT="$CONTEXT_TXT

NUMERIC CHECK — plug these values into the formula, compute the result yourself,
and compare with the paper's reference value. Report your computed number, the
relative error vs. the reference, and treat a disagreement beyond the stated
tolerance as a DISCREPANCY:
$NUMBERS_TXT"
  echo ">> numeric mode: NUMBERS section detected" >&2
fi

# helper: substitute a {{TOKEN}} in a template with file contents, safely
fill() {  # fill <template> <token> <value-file> <out>
  local tmpl="$1" token="$2" valfile="$3" out="$4"
  awk -v tok="{{$token}}" -v vf="$valfile" '
    $0 ~ tok {
      while ((getline line < vf) > 0) print line
      next
    }
    { print }
  ' "$tmpl" > "$out"
}

verdict_of() {  # extract the verdict word from a single JSON line
  jq -r '(.content // "")
         | gsub("\\*";"")                       # drop markdown bold
         | split("\n")
         | map(select(test("VERDICT";"i")))
         | last // ""
         | capture("VERDICT:\\s*<?(?<v>[A-Za-z]+)";"i").v // "NO-VERDICT"' 2>/dev/null
}

print_verdicts() {  # print_verdicts <jsonl-file>
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local m len v
    m="$(printf '%s' "$line" | jq -r '.requested // "?"' | sed 's#/.*##')"
    len="$(printf '%s' "$line" | jq -r '(.content//"")|length')"
    v="$(printf '%s' "$line" | verdict_of)"
    printf '  %-10s [len=%s]: %s\n' "$m" "$len" "$v"
  done < "$1"
}

# one short reason line per model (the text after "VERDICT:")
reason_of() {  # reason_of  (reads one JSON line on stdin)
  jq -r '(.content // "")
         | gsub("\\*";"")
         | split("\n")
         | map(select(test("VERDICT";"i")))
         | last // ""
         | sub("(?i)^.*VERDICT:\\s*";"")
         | gsub("^\\s+|\\s+$";"")' 2>/dev/null
}

# Markdown table of verdicts for one round, appended to $REPORT
verdict_table_md() {  # verdict_table_md <jsonl-file>
  printf '\n| Model | Verdict | Reason |\n|---|---|---|\n' >> "$REPORT"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local m ok v r
    m="$(printf '%s' "$line" | jq -r '.requested // "?"' | sed 's#/.*##')"
    ok="$(printf '%s' "$line" | jq -r '.ok // false')"
    if [ "$ok" != "true" ]; then
      printf '| %s | (no result) | %s |\n' "$m" \
        "$(printf '%s' "$line" | jq -r '(.error // "call failed")|gsub("[|\n]";" ")|.[0:120]')" >> "$REPORT"
      continue
    fi
    v="$(printf '%s' "$line" | verdict_of)"
    r="$(printf '%s' "$line" | reason_of | tr '\n' ' ' | sed 's/|/\\|/g' | cut -c1-160)"
    printf '| %s | %s | %s |\n' "$m" "$v" "$r" >> "$REPORT"
  done < "$1"
}

# count how many models returned a given verdict word (case-insensitive substring)
count_verdict() {  # count_verdict <jsonl-file> <word>
  local n=0 line v
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    v="$(printf '%s' "$line" | verdict_of | tr 'A-Z' 'a-z')"
    case "$v" in *"$(printf '%s' "$2" | tr 'A-Z' 'a-z')"*) n=$((n+1)) ;; esac
  done < "$1"
  printf '%s' "$n"
}

# extract the first ```python ... ``` fenced block from a model answer
extract_python() {  # extract_python <text-file>
  awk '/^[[:space:]]*```[[:space:]]*python/{f=1;next} /^[[:space:]]*```/{if(f)exit} f' "$1"
}

# pull the first number that looks like a reference value out of the NUMBERS text
# (scientific or decimal). Heuristic: the number following "reference" if present,
# else the last standalone number in the block.
reference_value() {  # reference_value <numbers-file>
  local ref
  ref="$(grep -iEo 'reference[^0-9eE+-]*([+-]?[0-9]*\.?[0-9]+([eE][+-]?[0-9]+)?)' "$1" \
         | grep -Eo '[+-]?[0-9]*\.?[0-9]+([eE][+-]?[0-9]+)?' | tail -1)"
  [ -z "$ref" ] && ref="$(grep -Eo '[+-]?[0-9]*\.?[0-9]+([eE][+-]?[0-9]+)?' "$1" | tail -1)"
  printf '%s' "$ref"
}

printf '%s\n' "$CLAIM_TXT"    > "$OUT_DIR/_claim.txt"
printf '%s\n' "$CONTEXT_TXT"  > "$OUT_DIR/_context.txt"
[ -n "$NUMBERS_TXT" ] && printf '%s\n' "$NUMBERS_TXT" > "$OUT_DIR/_numbers.txt"

# --- Round 1: independent derivation ----------------------------------------
# Each model derives the quantity exactly once. Self-consistency sampling is
# intentionally disabled: one derivation per model keeps the run deterministic
# in cost and avoids the majority-vote consolidation entirely.
fill "$SKILL_ROOT/prompts/derive.md" CLAIM   "$OUT_DIR/_claim.txt"   "$OUT_DIR/_r1.tmp"
fill "$OUT_DIR/_r1.tmp"              CONTEXT "$OUT_DIR/_context.txt" "$OUT_DIR/_r1.prompt"

echo ">> Round 1 (independent derivation) ..." >&2
bash "$HERE/fan_out.sh" "$OUT_DIR/_r1.prompt" > "$OUT_DIR/round1.jsonl"

# --- digest of Round-1 derivations -----------------------------------------
# Each derivation is kept up to OR_DIGEST_CHARS (default 4000) chars. The old
# 700-char cap silently truncated long derivations (Gemini especially), so
# Round 2 refuted only half the argument. 4000 keeps the full reasoning while
# bounding the Round-2 prompt size.
DIGEST_CHARS="${OR_DIGEST_CHARS:-4000}"
jq -r --argjson n "$DIGEST_CHARS" 'select(.requested) |
  "[\(.requested|sub("/.*";""))]: \((.content // "(no output)") | gsub("\n";" ") | .[0:$n])"' \
  "$OUT_DIR/round1.jsonl" > "$OUT_DIR/_others.txt"

# --- Round 2: adversarial refutation ---------------------------------------
fill "$SKILL_ROOT/prompts/refute.md" CLAIM            "$OUT_DIR/_claim.txt"   "$OUT_DIR/_r2a.tmp"
fill "$OUT_DIR/_r2a.tmp"             CONTEXT          "$OUT_DIR/_context.txt" "$OUT_DIR/_r2b.tmp"
fill "$OUT_DIR/_r2b.tmp"             OTHER_DERIVATIONS "$OUT_DIR/_others.txt"  "$OUT_DIR/_r2.prompt"
echo ">> Round 2 (adversarial refutation) ..." >&2
bash "$HERE/fan_out.sh" "$OUT_DIR/_r2.prompt" > "$OUT_DIR/round2.jsonl"

# --- Round 3: resolve disagreement (only on a real split) -------------------
# Trigger only when Round 2 is NOT unanimous: at least one model confirms AND at
# least one dissents (REFUTED / DISCREPANCY). Unanimous rounds need no Round 3.
R2_CONFIRM="$(count_verdict "$OUT_DIR/round2.jsonl" CONFIRM)"
R2_REFUTE="$(count_verdict "$OUT_DIR/round2.jsonl" REFUTE)"
R2_DISCREP="$(count_verdict "$OUT_DIR/round2.jsonl" DISCREP)"
R2_DISSENT=$(( R2_REFUTE + R2_DISCREP ))
RAN_ROUND3=0
if [ "$R2_CONFIRM" -ge 1 ] && [ "$R2_DISSENT" -ge 1 ]; then
  RAN_ROUND3=1
  echo ">> split detected ($R2_CONFIRM confirm vs $R2_DISSENT dissent) — Round 3 ..." >&2
  # the disagreement digest: the reason lines of the dissenting models
  : > "$OUT_DIR/_disagreement.txt"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    v="$(printf '%s' "$line" | verdict_of | tr 'A-Z' 'a-z')"
    case "$v" in
      *refute*|*discrep*)
        mname="$(printf '%s' "$line" | jq -r '.requested' | sed 's#/.*##')"
        rsn="$(printf '%s' "$line" | reason_of | tr '\n' ' ')"
        printf -- '- [%s] objects: %s\n' "$mname" "$rsn" >> "$OUT_DIR/_disagreement.txt" ;;
    esac
  done < "$OUT_DIR/round2.jsonl"
  # full Round-2 reviews as context
  jq -r --argjson n "$DIGEST_CHARS" 'select(.requested) |
    "[\(.requested|sub("/.*";""))]: \((.content // "(no output)") | gsub("\n";" ") | .[0:$n])"' \
    "$OUT_DIR/round2.jsonl" > "$OUT_DIR/_r2others.txt"

  fill "$SKILL_ROOT/prompts/resolve.md" CLAIM            "$OUT_DIR/_claim.txt"        "$OUT_DIR/_r3a.tmp"
  fill "$OUT_DIR/_r3a.tmp"              CONTEXT          "$OUT_DIR/_context.txt"      "$OUT_DIR/_r3b.tmp"
  fill "$OUT_DIR/_r3b.tmp"              DISAGREEMENT     "$OUT_DIR/_disagreement.txt" "$OUT_DIR/_r3c.tmp"
  fill "$OUT_DIR/_r3c.tmp"              OTHER_DERIVATIONS "$OUT_DIR/_r2others.txt"     "$OUT_DIR/_r3.prompt"
  bash "$HERE/fan_out.sh" "$OUT_DIR/_r3.prompt" > "$OUT_DIR/round3.jsonl"
fi

# --- console tally ---------------------------------------------------------
echo ""
echo "=== Round 1 verdicts ==="
print_verdicts "$OUT_DIR/round1.jsonl"
echo "=== Round 2 verdicts (adversarial) ==="
print_verdicts "$OUT_DIR/round2.jsonl"
if [ "$RAN_ROUND3" -eq 1 ]; then
  echo "=== Round 3 verdicts (resolution) ==="
  print_verdicts "$OUT_DIR/round3.jsonl"
fi

# --- deterministic Markdown report fragment --------------------------------
# Optional heading via env: CLAIM_ID (e.g. "B1"), CLAIM_TITLE (e.g. "Ideal solenoid L").
REPORT="$OUT_DIR/claim-report.md"
TITLE="${CLAIM_ID:+$CLAIM_ID — }${CLAIM_TITLE:-Claim}"
# Headline uses the LAST decisive round: Round 3 if it ran, else Round 2.
if [ "$RAN_ROUND3" -eq 1 ]; then
  HEAD_SRC="$OUT_DIR/round3.jsonl"; HEAD_LABEL="Round 3 (resolution)"
else
  HEAD_SRC="$OUT_DIR/round2.jsonl"; HEAD_LABEL="Round 2 (adversarial)"
fi
N_MODELS="$(jq -rs 'length' "$HEAD_SRC" 2>/dev/null || echo 0)"
N_CONF="$(count_verdict "$HEAD_SRC" CONFIRM)"

{
  printf '## %s\n\n' "$TITLE"
  printf '**Claim**\n\n```\n'
  cat "$OUT_DIR/_claim.txt"
  printf '```\n'
  printf '\n_%s: %s/%s models confirm._\n' "$HEAD_LABEL" "$N_CONF" "$N_MODELS"
} > "$REPORT"

printf '\n### Round 1 — independent derivation\n' >> "$REPORT"
verdict_table_md "$OUT_DIR/round1.jsonl"
printf '\n### Round 2 — adversarial refutation\n' >> "$REPORT"
verdict_table_md "$OUT_DIR/round2.jsonl"
if [ "$RAN_ROUND3" -eq 1 ]; then
  printf '\n### Round 3 — resolving disagreement\n' >> "$REPORT"
  verdict_table_md "$OUT_DIR/round3.jsonl"
fi

# --- Python ground-truth (numeric mode only) -------------------------------
# One model writes a Python snippet; PYTHON (not the LLM) computes the number,
# which is compared against the paper's reference value. Real verification of the
# arithmetic, instead of trusting the models' own mental math.
if [ -n "$NUMBERS_TXT" ]; then
  echo ">> Python ground-truth: requesting snippet ..." >&2
  GT_MODEL="${GROUND_TRUTH_MODEL:-anthropic/claude-opus-4.8}"
  fill "$SKILL_ROOT/prompts/numeric.md" CLAIM   "$OUT_DIR/_claim.txt"   "$OUT_DIR/_num1.tmp"
  fill "$OUT_DIR/_num1.tmp"             CONTEXT "$OUT_DIR/_context.txt" "$OUT_DIR/_num2.tmp"
  fill "$OUT_DIR/_num2.tmp"             NUMBERS "$OUT_DIR/_numbers.txt" "$OUT_DIR/_num.prompt"

  bash "$HERE/or_query.sh" "$GT_MODEL" "$OUT_DIR/_num.prompt" > "$OUT_DIR/_num.json" 2>/dev/null
  jq -r '.content // ""' "$OUT_DIR/_num.json" > "$OUT_DIR/_num.answer"
  extract_python "$OUT_DIR/_num.answer" > "$OUT_DIR/snippet.py"

  printf '\n### Python ground-truth\n\n' >> "$REPORT"
  if [ ! -s "$OUT_DIR/snippet.py" ]; then
    printf '> No Python snippet could be extracted from the model answer.\n' >> "$REPORT"
  else
    RUN_JSON="$(bash "$HERE/run_python.sh" "$OUT_DIR/snippet.py")"
    if [ "$(printf '%s' "$RUN_JSON" | jq -r '.ok')" = "true" ]; then
      # The numeric prompt asks the model to print ONLY the final value on the
      # LAST line, but models often print debug lines too. Take the last NON-EMPTY
      # line and trim it — not "strip all whitespace from the whole output and keep
      # the last 40 chars", which mashed multi-line output into garbage.
      COMPUTED="$(printf '%s' "$RUN_JSON" | jq -r '.stdout' \
                  | awk 'NF{last=$0} END{print last}' \
                  | tr -d '[:space:]')"
      REF="$(reference_value "$OUT_DIR/_numbers.txt")"
      REL="$(python3 -I -S -c "
try:
    c=float('$COMPUTED'); r=float('$REF')
    print(f'{abs(c-r)/abs(r)*100:.2f}' if r else 'n/a')
except Exception:
    print('n/a')" 2>/dev/null)"
      printf '| Computed (Python) | Paper reference | Rel. error |\n|---|---|---|\n' >> "$REPORT"
      printf '| `%s` | `%s` | %s%% |\n\n' "$COMPUTED" "${REF:-?}" "${REL:-n/a}" >> "$REPORT"
      printf '<details><summary>snippet</summary>\n\n```python\n' >> "$REPORT"
      cat "$OUT_DIR/snippet.py" >> "$REPORT"
      printf '\n```\n</details>\n' >> "$REPORT"
    else
      printf '> Snippet not executed: %s (%s)\n' \
        "$(printf '%s' "$RUN_JSON" | jq -r '.reason // "?"')" \
        "$(printf '%s' "$RUN_JSON" | jq -r '.error // ""' | tr -d '\n' | cut -c1-160)" >> "$REPORT"
    fi
  fi
fi

{
  printf '\n> _Synthesis (fill in): overall verdict + confidence; if any model dissents, '
  printf 'state whether it found a real error or erred itself._\n'
} >> "$REPORT"

echo ""
echo "Markdown report:  $REPORT"
echo "Raw outputs:      $OUT_DIR/round1.jsonl , $OUT_DIR/round2.jsonl"
