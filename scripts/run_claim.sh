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

# --- split the claim file into CLAIM and CONTEXT ---------------------------
CLAIM_TXT="$(awk '/^=== *CLAIM *===/{f=1;next} /^=== *CONTEXT *===/{f=0} f' "$CLAIM_FILE")"
CONTEXT_TXT="$(awk '/^=== *CONTEXT *===/{f=1;next} f' "$CLAIM_FILE")"
if [ -z "$CLAIM_TXT" ]; then
  echo "no '=== CLAIM ===' section found in $CLAIM_FILE" >&2
  exit 2
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

printf '%s\n' "$CLAIM_TXT"    > "$OUT_DIR/_claim.txt"
printf '%s\n' "$CONTEXT_TXT"  > "$OUT_DIR/_context.txt"

# --- Round 1: independent derivation ---------------------------------------
fill "$SKILL_ROOT/prompts/derive.md" CLAIM   "$OUT_DIR/_claim.txt"   "$OUT_DIR/_r1.tmp"
fill "$OUT_DIR/_r1.tmp"              CONTEXT "$OUT_DIR/_context.txt" "$OUT_DIR/_r1.prompt"
echo ">> Round 1 (independent derivation) ..." >&2
bash "$HERE/fan_out.sh" "$OUT_DIR/_r1.prompt" > "$OUT_DIR/round1.jsonl"

# --- digest of Round-1 derivations -----------------------------------------
jq -r 'select(.requested) |
  "[\(.requested|sub("/.*";""))]: \((.content // "(no output)") | gsub("\n";" ") | .[0:700])"' \
  "$OUT_DIR/round1.jsonl" > "$OUT_DIR/_others.txt"

# --- Round 2: adversarial refutation ---------------------------------------
fill "$SKILL_ROOT/prompts/refute.md" CLAIM            "$OUT_DIR/_claim.txt"   "$OUT_DIR/_r2a.tmp"
fill "$OUT_DIR/_r2a.tmp"             CONTEXT          "$OUT_DIR/_context.txt" "$OUT_DIR/_r2b.tmp"
fill "$OUT_DIR/_r2b.tmp"             OTHER_DERIVATIONS "$OUT_DIR/_others.txt"  "$OUT_DIR/_r2.prompt"
echo ">> Round 2 (adversarial refutation) ..." >&2
bash "$HERE/fan_out.sh" "$OUT_DIR/_r2.prompt" > "$OUT_DIR/round2.jsonl"

# --- report ----------------------------------------------------------------
echo ""
echo "=== Round 1 verdicts ==="
print_verdicts "$OUT_DIR/round1.jsonl"
echo "=== Round 2 verdicts (adversarial) ==="
print_verdicts "$OUT_DIR/round2.jsonl"
echo ""
echo "Raw outputs: $OUT_DIR/round1.jsonl , $OUT_DIR/round2.jsonl"
