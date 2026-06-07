# verify-paper-formulas

A [Claude Code](https://claude.com/claude-code) **skill** that independently
checks the formulas, derivations, and approximations in a physics paper. Several
different large language models re-derive each quantity *from scratch* (via
[OpenRouter](https://openrouter.ai)), then **adversarially try to refute** each
other; disagreements get a focused third round, and numeric claims are verified
by **actually running Python**, not by trusting a model's mental arithmetic. The
result is a Markdown review report with a per-formula verdict. **The paper itself
is never modified.**

> Built by **Lasse Parduhn** for **Prof. Dieter Süß** (University of Vienna) to
> cross-check the derivations in the `energy_harvesting` paper — independently
> re-deriving each quantity and letting different models check one another.

---

## Quickstart

### 1. Install

```bash
git clone https://github.com/Lassemind/verify-paper-formulas.git \
  ~/.claude/skills/verify-paper-formulas
```

It lives in your **user** skills directory, so it's available in every Claude
Code session, from any folder.

### 2. Add your OpenRouter key

```bash
cp ~/.claude/skills/verify-paper-formulas/.env.example \
   ~/.claude/skills/verify-paper-formulas/.env
# then edit .env and paste your key
```

The `.env` is git-ignored and the key is **never** written to any report or log.
(Other key sources also work — see [Configuration](#configuration).)

### 3. Use it

**In Claude Code** — just ask, and the skill activates automatically:

> "Verify the formulas in Appendix B of the energy_harvesting paper — let several
> LLMs derive them independently and check each other."

…or invoke it explicitly with `/verify-paper-formulas`.

**From the shell** — run one claim, or a whole folder of them:

```bash
SKILL=~/.claude/skills/verify-paper-formulas

# one claim:
CLAIM_ID=B1 CLAIM_TITLE="Ideal solenoid L" \
  "$SKILL/scripts/run_claim.sh" my_claim.txt ./out

# a directory of claims → one assembled report:
"$SKILL/scripts/run_batch.sh" ./claims
```

For high-confidence runs (3× self-consistency sampling, auto Round 3, Python
ground-truth on numeric claims):

```bash
N_SAMPLES=3 "$SKILL/scripts/run_batch.sh" ./claims
```

### Requirements

Claude Code · `git` · `curl` · `jq` · `python3` · an OpenRouter API key.

---

## How it works (in depth)

### The claim file

Each formula to check is a small text file with two sections — plus an optional
third for numeric checks:

```
=== CLAIM ===
L_s = \mu_0 n^2 \pi R_c^2 / h
=== CONTEXT ===
Ideal solenoid, n turns, radius R_c, height h. \mu_0 is the vacuum permeability.
=== NUMBERS ===                      # optional — triggers numeric verification
R_c = 14.1e-6 m, h = 1.0e-3 m, n = 20.
Paper reference: L_s = 2.41e-9 H (tolerance ~5%).
```

In a batch, the **filename** sets the ID and title: `B1_ideal_solenoid.txt`
→ ID `B1`, title *"ideal solenoid"* (a `# Title: …` first line overrides).

### The verification pipeline

```
                       ┌──────────────────────────────────────────────┐
                       │              one claim file                   │
                       │   === CLAIM === / CONTEXT / (NUMBERS?)        │
                       └───────────────────────┬──────────────────────┘
                                               │
                 ┌─────────────────────────────▼─────────────────────────────┐
                 │  ROUND 1 — independent derivation   (prompts/derive.md)    │
                 │  all 5 models derive the quantity SOLO, blind to the       │
                 │  paper's result and to each other.                         │
                 │  N_SAMPLES>1 → each model runs N× (temp 0.5); per-model     │
                 │  verdict = MAJORITY of its N runs (tie → UNSURE).           │
                 └─────────────────────────────┬─────────────────────────────┘
                                               │ derivations digested
                 ┌─────────────────────────────▼─────────────────────────────┐
                 │  ROUND 2 — adversarial refutation   (prompts/refute.md)    │
                 │  each model gets the paper's derivation + the others' and  │
                 │  actively tries to find the FIRST step that breaks.        │
                 └─────────────────────────────┬─────────────────────────────┘
                                               │
                          unanimous? ──── yes ─┤
                                │              │
                                no             │
                                ▼              │
                 ┌──────────────────────────┐  │
                 │ ROUND 3 — resolve split  │  │   (only if ≥1 confirm AND
                 │ (prompts/resolve.md)     │  │    ≥1 dissent in Round 2)
                 │ models re-decide ONLY    │  │
                 │ the contested step.      │  │
                 └─────────────┬────────────┘  │
                               └───────┬────────┘
                                       │
              NUMBERS present? ────────┤
                       │               │
                       ▼               │
        ┌────────────────────────────┐ │   one model writes a Python snippet;
        │ PYTHON GROUND-TRUTH        │ │   run_python.sh executes it sandboxed
        │ (prompts/numeric.md +      │ │   (only `import math`, 10 s timeout);
        │  scripts/run_python.sh)    │ │   the computed number is compared to
        │ Python computes the value, │ │   the paper's reference (relative error).
        │ not the LLM.               │ │
        └─────────────┬──────────────┘ │
                      └────────┬────────┘
                               ▼
                 ┌─────────────────────────────────────────────┐
                 │  claim-report.md  (deterministic)            │
                 │  • "N/M models confirm" headline             │
                 │  • per-round verdict tables                  │
                 │  • Python ground-truth row (if numeric)      │
                 │  • a synthesis line for the human to fill in │
                 └─────────────────────────────────────────────┘
```

`run_batch.sh` runs many claims (up to `MAX_PARALLEL` at once, 5 models each),
then concatenates every `claim-report.md` into **one** report with a summary
table at the top. A claim that errors is marked `FAILED` and never aborts the batch.

### Why three rounds + Python?

- **Round 1 (blind, independent)** establishes what the answer *should* be without
  anchoring on the paper.
- **Round 2 (adversarial)** is the real test: every model is told to *break* the
  derivation, so a formula that survives has been attacked from five directions.
- **Round 3** only fires on genuine disagreement and forces the models to argue
  the single contested step rather than talk past each other.
- **Self-consistency** (`N_SAMPLES`) averages out a model's one-off slips.
- **Python ground-truth** removes the weakest link in LLM verification — numeric
  arithmetic — by computing the number for real.

The final verdict (✅ confirmed / ⚠️ disagreement / ❌ error) is the human's call,
informed by these tables — not a blind majority vote.

---

## Layout

```
verify-paper-formulas/
├── SKILL.md              # the skill definition + workflow Claude follows
├── README.md             # this file
├── scripts/
│   ├── run_batch.sh      # run a directory of claims → one assembled report
│   ├── run_claim.sh      # one claim: Round 1 → 2 → (3) → report fragment
│   ├── fan_out.sh        # run a prompt across all models in parallel → JSONL
│   ├── or_query.sh       # one OpenRouter call → JSON {ok, model, content|error}
│   └── run_python.sh     # sandboxed executor for numeric ground-truth snippets
└── prompts/
    ├── derive.md         # Round 1: independent derivation
    ├── refute.md         # Round 2: adversarial refutation
    ├── resolve.md        # Round 3: resolve a disagreement
    └── numeric.md        # numeric ground-truth: write a Python snippet
```

Default model panel (real cross-vendor diversity):
`claude-opus-4.8`, `gpt-5.5`, `gemini-3.1-pro`, `grok-4.3`, `deepseek-v4-pro`.

---

## Configuration

### Key resolution

The scripts read `OPENROUTER_API_KEY` from the first source that has it:

1. `$OPENROUTER_ENV` — a path you point at an env file
2. an already-exported `OPENROUTER_API_KEY` in your shell
3. a local `.env` in the skill folder (`.env.example` → `.env`)
4. `~/.config/openrouter.env`

### Tuning (environment variables)

All optional — defaults keep it fast and cheap.

| Var | Default | Effect |
|-----|---------|--------|
| `N_SAMPLES` | `1` | Self-consistency: derive each quantity N× in Round 1 (temp 0.5); per-model verdict = majority. `3` is a good high-confidence value. |
| `MAX_PARALLEL` | `5` | `run_batch.sh`: claims run at once (× 5 models = concurrent calls). |
| `OR_DIGEST_CHARS` | `4000` | Max chars of each Round-1 derivation carried into Round 2. |
| `OR_MAX_TOKENS` | `8192` | Per-call completion cap. |
| `OR_TEMP` | `0.2` | Sampling temperature (auto-raised to 0.5 during `N_SAMPLES` runs). |
| `GROUND_TRUTH_MODEL` | `claude-opus-4.8` | Model that writes the numeric-check Python snippet. |

> **Cost note:** `MAX_PARALLEL` and `N_SAMPLES` multiply. `MAX_PARALLEL=5
> N_SAMPLES=3` ≈ 75 concurrent calls. If you push both, drop `MAX_PARALLEL` to 2.

---

## Safety

- The paper is read-only — never modified.
- The API key is never written to any report, log, or file; `.env` is git-ignored.
- `run_python.sh` executes model-written code in a locked-down sandbox: a token
  blocklist allows only `import math`/`cmath` (no `os`/`sys`/`subprocess`/`open`/
  `eval`/`exec`/`__import__`/network), `python3 -I -S`, a 10 s timeout, and a
  throwaway working directory. Anything suspicious is refused rather than run.

## Verification

The mechanics were validated against the live model panel and two synthetic
controls: a deliberately **wrong** derivation (kinetic energy as `m v²`, missing
the ½) — all five models flagged a **DISCREPANCY**; and the **correct** one
(`½ m v²`) — all five returned **CONFIRMED**.

## License

MIT
