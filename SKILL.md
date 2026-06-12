---
name: verify-paper-formulas
description: Use when reviewing a physics paper section by section with multiple LLMs (e.g. the energy_harvesting Overleaf project) — each section is checked independently by two frontier models via OpenRouter, plus a whole-paper consistency pass, ending in a German improvement report. Also supports deep claim-level verification of single formulas.
---

# Verify Paper Formulas — Section Review

Reviews a physics paper **section by section**: every `\section` (main text and
appendices) is independently checked by two frontier models (math re-derived,
units, approximations, numbers, physics, notation), one extra pass checks
whole-paper consistency (main text ↔ appendix, notation drift, parameter
values), and a final synthesis verifies, dedupes, and writes a **German
improvement report** for the author. **The paper is never modified.**

## When to Use

* The user wants a paper "gründlich geprüft" / reviewed section by section
* The user mentions the `energy_harvesting` paper or Overleaf project `69aaca…`
* A final "what should be improved" report is the desired output

## Prerequisites

* `OPENROUTER_API_KEY` via env var, `.env` in the skill folder, or
  `~/.config/openrouter.env` — never print or commit it.
  **First-run onboarding:** if no key is found, don't fail — ask the user for
  their own OpenRouter key (openrouter.ai/keys), write it to
  `~/.config/openrouter.env` as `OPENROUTER_API_KEY=...` with mode 600, and
  continue. Never echo the key back or write it anywhere else.
* `git`, `curl`, `jq`
* Default panel: `anthropic/claude-fable-5` + `openai/gpt-5.5`
  (synthesis: Fable 5)

## Workflow

1. **Get the paper.** Clone/pull the Overleaf repo or use a local path. Find the
   main `.tex` (usually `main.tex`).
2. **Run the review** (one command does everything):
   ```
   scripts/review_sections.sh <paper.tex> <out-dir>
   ```
   It splits at `\section` boundaries, fans out 2 models × N sections plus one
   whole-paper cross-check, then synthesizes the report. Expect ~15–20 min and
   a handful of euros for a 3000-line paper; run it in the background.
3. **Deliver** `<out-dir>/improvement-report.md` — German, three buckets
   (🔴 Fehler / 🟡 Prüfen / 🟢 Kleinere Verbesserungen), paper order, each item
   with `main.tex:<line>` and a concrete fix. Raw per-model findings stay in
   `<out-dir>/findings.md` as the audit trail.

### Resume / partial failures

The script is **resumable**: re-running it skips every call that already has a
usable result (ok + non-empty content) and re-does only failed/empty ones, then
re-assembles findings and re-synthesizes. A single model failure shows up as
"(no result)" and never aborts the run.

### Tuning (env vars)

| Var | Default | Effect |
|-----|---------|--------|
| `REVIEW_MODELS` | Fable 5 + GPT-5.5 | comma-separated review panel |
| `SYNTH_MODEL` | `anthropic/claude-fable-5` | writes the final report |
| `MAX_PARALLEL` | `4` | concurrent API calls |
| `OR_MAX_TOKENS` | `24000` | per-call output cap — keep high: reasoning models spend it on thinking first; 8192 yields empty (but billed) replies on long sections |
| `OR_TIMEOUT` | `420` | per-call wall clock (s) |
| `SYNTH_MAX_TOKENS` | `30000` | output cap for the synthesis pass |

## Deep dive: claim-level verification (advanced)

For drilling into a *single* suspicious formula, the claim-level pipeline still
exists: write a claim file (`=== CLAIM === / === CONTEXT === / === NUMBERS ===`)
and run `scripts/run_claim.sh` (independent derivation → adversarial refutation
→ optional resolution; `=== NUMBERS ===` adds a sandboxed Python ground-truth
check via `scripts/run_python.sh`). Batch mode: `scripts/run_batch.sh
<claims-dir>`. See the script headers for details. Use section review first;
escalate to claims only where a finding needs a verdict.

## Error Handling

* No `OPENROUTER_API_KEY` → stop with a clear message, no silent fallback.
* Model timeout / rate limit → that call is "(no result)", the run continues;
  re-run the script to retry the gaps.
* Overleaf clone fails → ask the user for a local path.
* **Never** write the API key into reports, logs, or any file.
