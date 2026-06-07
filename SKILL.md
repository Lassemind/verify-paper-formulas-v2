---
name: verify-paper-formulas
description: Use when independently verifying the formulas, derivations, and approximations in a physics paper (such as the energy_harvesting Overleaf project) by having multiple LLMs derive each quantity via OpenRouter and adversarially refute each other.
---

# Verify Paper Formulas

Independently checks the formulas and approximations in a physics paper. Each
claim is derived from scratch by several different LLMs (via OpenRouter), then
the models adversarially try to refute the paper's own derivation. Output is a
Markdown review report. **The paper is never modified.**

## When to Use

* Verifying derivations in an appendix (A, B, …) or formula-heavy section
* Cross-checking approximations / limiting cases with multiple independent models
* The user mentions the `energy_harvesting` paper, Overleaf project `69aaca…`, or
  "let several LLMs check the formulas against each other"

## Prerequisites

* `OPENROUTER_API_KEY` available via one of: `$OPENROUTER_ENV`, an exported env
  var, a local `.env` in the skill folder, or `~/.config/openrouter.env`
* `git`, `curl`, `jq` available
* Default models (all 5 from the OpenRouter workspace):
  `anthropic/claude-opus-4.8`, `openai/gpt-5.5`,
  `google/gemini-3.1-pro-preview`, `x-ai/grok-4.3`, `deepseek/deepseek-v4-pro`

## Workflow

### Phase A — Fetch & decompose

1. Clone or pull the paper:
   ```
   git clone https://git@git.overleaf.com/69aaca869873bcaf7b54ea90 <dir>
   ```
   If the clone fails (auth/network), ask the user for a local path instead.
2. Read the `.tex` files. Extract each formula/derivation from the appendices and
   formula sections as a **numbered list of claims**. Show this list to the user
   and confirm scope before spending API tokens.

For each claim record: an ID + source (`Appendix A, Eq. (A.3)`), the claim text,
and the surrounding definitions/symbols (the **context**).

### Phase B — Multi-model verification (per claim)

**Preferred: one driver per claim.** Write the claim to a plain-text file with
two (optionally three) `=== … ===` sections and run `run_claim.sh`:

```
=== CLAIM ===
<the paper's formula / derivation>
=== CONTEXT ===
<surrounding definitions and symbols>
=== NUMBERS ===          # optional — turns it into a NUMERIC check
<symbol values + the paper's reference result and tolerance>
```

```
CLAIM_ID=B1 CLAIM_TITLE="Ideal solenoid L" \
  scripts/run_claim.sh <claim-file> <out-dir>
```

This runs Round 1 (independent derivation) → digest → Round 2 (adversarial
refutation), prints a verdict tally, and writes three files to `<out-dir>`:
`round1.jsonl`, `round2.jsonl`, and a deterministic **`claim-report.md`**
fragment (claim text + per-model verdict tables + an "N/M confirm" headline).
The driver avoids the shell word-splitting trap of looping over the model list
by hand. A failed model shows up as `(no result)` and never aborts the others.

If a `=== NUMBERS ===` section is present, the models are instructed to plug the
values in, compute the result, and compare against the paper's reference within
the stated tolerance — this is how "more test cases" / numeric verification is done.

**Low-level fallback.** To drive the rounds by hand, fill `prompts/derive.md`
(`{{CLAIM}}`, `{{CONTEXT}}`) and run `scripts/fan_out.sh <prompt-file>`; then fill
`prompts/refute.md` (`{{CLAIM}}`, `{{CONTEXT}}`, `{{OTHER_DERIVATIONS}}` = the
Round-1 contents) and run `fan_out.sh` again. Each model ends with a line
`VERDICT: <...> — <reason>`; parse with:

```
... | jq -r 'select(.requested) | "\(.requested): \(.content)"'
```

### Phase C — Synthesis

You (Claude) read all model answers per claim and write the report. Determine the
verdict from the verdicts + reasoning — not a blind majority; weigh whether the
dissenting model found a *real* error or just made a mistake itself.

## Report Format

`run_claim.sh` already emits a deterministic `claim-report.md` per claim (verdict
tables + an "N/M confirm" headline). Assemble the per-claim fragments into
`<dir>/verify-reports/YYYY-MM-DD-<paper>.md` (do not commit it) and add, per claim,
the one thing the script can't decide for you — the **synthesis line**:

* **Claim** — formula/quantity + source location *(from the fragment)*
* **Solo / adversarial verdicts** — per-model tables *(from the fragment)*
* **Verdict** — ✅ confirmed / ⚠️ disagreement / ❌ error found, + confidence
  *(your call — not a blind majority; weigh whether a dissenter found a* real *error)*
* **Discrepancy note** — if any, the exact step/factor/sign that differs
* For numeric claims: the computed value, the reference, and the relative error

## Error Handling

* No `OPENROUTER_API_KEY` / auth error → stop with a clear message, no silent fallback.
* A single model times out / rate-limits → it emits `ok:false`; mark it "no result"
  in the report and continue. `fan_out.sh` never aborts the others.
* Overleaf clone fails → ask for a local path.
* **Never** write the API key into the report, logs, or any file.

## Scripts

* `scripts/run_batch.sh <claims-dir> [out-dir] [report-file]` — runs a whole
  **directory** of claim files through `run_claim.sh` (sorted by filename,
  claims sequential, 5 models parallel each) and assembles **one** report with a
  summary table. ID/title come from each filename (`B1_ideal_solenoid.txt` ->
  ID `B1`, title "ideal solenoid"); a `# Title: ...` first line overrides. A
  failing claim is marked `FAILED` and does not abort the batch. Use this so the
  orchestration never has to be hand-written.
* `scripts/run_claim.sh <claim-file> [out-dir]` — **single-claim driver**: runs
  Round 1 (derive) → Round 2 (refute) → optional Round 3 (resolve), writes a
  `claim-report.md`. Honours `CLAIM_ID` / `CLAIM_TITLE` for the heading and an
  optional `=== NUMBERS ===` section for numeric checks. Round 3 fires only on a
  real split (≥1 confirm AND ≥1 dissent in Round 2); the headline then uses Round 3.
* `scripts/run_python.sh <snippet-file>` — runs a model-written formula snippet in
  a locked-down sandbox (token blocklist → only `import math`/`cmath`; `python3 -I -S`;
  10 s timeout; throwaway cwd) → JSON `{ok, stdout | reason, error}`. Used for the
  numeric ground-truth.
* `scripts/or_query.sh <model> <prompt-file>` — one OpenRouter call → JSON
  `{ok, requested, model, content|error}`. `OR_MAX_TOKENS` (8192), `OR_TEMP` (0.2),
  HTTP 429/5xx backoff, one empty-content retry (on a shorter timeout).
* `scripts/fan_out.sh <prompt-file> [models...]` — runs all models in parallel,
  emits JSONL. Model set: CLI args > `$VPF_MODELS` > built-in 5-model default.

## Tuning (env vars)

All optional; defaults keep the cheap, fast behaviour.

| Var | Default | Effect |
|-----|---------|--------|
| `N_SAMPLES` | `1` | Self-consistency: derive each quantity N times (temp 0.5) in Round 1; per-model verdict = majority of N. Catches one-off slips. 3 is a good value. |
| `MAX_PARALLEL` | `5` | `run_batch.sh`: claims run at once (×5 models = concurrent calls). |
| `OR_DIGEST_CHARS` | `4000` | Max chars of each Round-1 derivation passed into Round 2. |
| `OR_MAX_TOKENS` | `8192` | Per-call completion cap. |
| `OR_TEMP` | `0.2` | Sampling temperature (raised to 0.5 automatically during `N_SAMPLES` runs). |
| `OR_TIMEOUT` | `240` | Per-call wall-clock cap (seconds). |
| `OR_RETRY_TIMEOUT` | `OR_TIMEOUT/2` | Shorter cap for the empty-content retry, so a stalled reasoning model doesn't burn a second full timeout. |
| `VPF_MODELS` | _(unset)_ | Comma/space-separated model set, overriding the 5-model default without editing `fan_out.sh`. Drop a slow/empty model for a whole run by leaving it out. |
| `GROUND_TRUTH_MODEL` | `anthropic/claude-opus-4.8` | Model that writes the numeric-check Python snippet. |

```
# fast default
run_batch.sh ~/claims
# high-confidence: 3-sample self-consistency, Round 3 auto on splits, Python on NUMBERS
N_SAMPLES=3 run_batch.sh ~/claims
# drop a slow/empty model (e.g. deepseek) for the whole run — no file edits
VPF_MODELS="anthropic/claude-opus-4.8,openai/gpt-5.5,google/gemini-3.1-pro-preview,x-ai/grok-4.3" run_batch.sh ~/claims
```

## Notes

Default temperature is 0.2 (verification, not ideation); self-consistency runs use
0.5 so the samples actually differ. For long derivations, split into smaller claims
so each fits comfortably in one prompt and the verdicts stay checkable. In numeric
mode, trust the **Python-computed** number over any model's mental arithmetic.
