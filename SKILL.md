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

- Verifying derivations in an appendix (A, B, …) or formula-heavy section
- Cross-checking approximations / limiting cases with multiple independent models
- The user mentions the `energy_harvesting` paper, Overleaf project `69aaca…`, or
  "let several LLMs check the formulas against each other"

## Prerequisites

- `~/.config/openrouter.env` exports `OPENROUTER_API_KEY`
- `git`, `curl`, `jq` available
- Default models (all 5 from the OpenRouter workspace):
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

**Round 1 — independent derivation.** Fill `prompts/derive.md` (`{{CLAIM}}`,
`{{CONTEXT}}`) into a temp file, then:
```
scripts/fan_out.sh <derive-prompt-file>
```
Every model derives the quantity solo, blind to the paper's result and to each
other. Output is JSONL (one line per model).

**Round 2 — adversarial refutation.** Fill `prompts/refute.md` (`{{CLAIM}}`,
`{{CONTEXT}}`, `{{OTHER_DERIVATIONS}}` = the Round-1 contents), then run
`fan_out.sh` again. Each model is told to actively refute the paper's derivation.

Each model ends with a line `VERDICT: <...> — <reason>`; parse it with jq:
```
... | jq -r 'select(.requested) | "\(.requested): \(.content)"'
```

### Phase C — Synthesis

You (Claude) read all model answers per claim and write the report. Determine the
verdict from the verdicts + reasoning — not a blind majority; weigh whether the
dissenting model found a *real* error or just made a mistake itself.

## Report Format

Write to `<dir>/verify-reports/YYYY-MM-DD-<paper>.md` (do not commit it). Per claim:

- **Claim** — formula/quantity + source location
- **Solo derivations** — one short line per model
- **Adversarial round** — who refuted what
- **Verdict** — ✅ confirmed / ⚠️ disagreement / ❌ error found, + confidence
- **Discrepancy note** — if any, the exact step/factor/sign that differs

## Error Handling

- No `OPENROUTER_API_KEY` / auth error → stop with a clear message, no silent fallback.
- A single model times out / rate-limits → it emits `ok:false`; mark it "no result"
  in the report and continue. `fan_out.sh` never aborts the others.
- Overleaf clone fails → ask for a local path.
- **Never** write the API key into the report, logs, or any file.

## Scripts

- `scripts/or_query.sh <model> <prompt-file>` — one OpenRouter call → JSON
  `{ok, requested, model, content|error}`.
- `scripts/fan_out.sh <prompt-file> [models...]` — runs all models in parallel,
  emits JSONL. Defaults to the 5-model set; pass model IDs to override.

## Notes

Use a low temperature (the scripts set 0.2) — this is verification, not ideation.
For long derivations, split into smaller claims so each fits comfortably in one
prompt and the verdicts stay checkable.
