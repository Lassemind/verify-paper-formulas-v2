# verify-paper-formulas

A [Claude Code](https://claude.com/claude-code) **skill** that independently
verifies the formulas, derivations, and approximations in a physics paper by
having several different large language models derive each quantity from scratch
(via [OpenRouter](https://openrouter.ai)) and then **adversarially refute** each
other's work. The output is a Markdown review report. **The paper itself is never
modified.**

> Built by **Lasse Parduhn** for **Prof. Dieter Süß** (University of Vienna), to
> cross-check the derivations in the `energy_harvesting` paper using multiple
> independent LLMs — per the task of independently re-deriving the quantities and
> letting different models check each other.

## How it works

Three phases:

1. **Fetch & decompose** — clone the paper (Overleaf Git or a local path), read the
   `.tex`, and extract each appendix/section formula as a numbered *claim*.
2. **Multi-model verification** — for every claim:
   - *Round 1 (independent):* each model derives the quantity solo, blind to the
     paper's result and to the other models.
   - *Round 2 (adversarial):* each model receives the paper's derivation plus the
     other models' derivations and actively tries to **refute** it.
3. **Synthesis** — the answers are merged into a per-claim verdict
   (✅ confirmed / ⚠️ disagreement / ❌ error found) with the exact discrepancy.

Default model panel (real cross-vendor diversity):
`claude-opus-4.8`, `gpt-5.5`, `gemini-3.1-pro`, `grok-4.3`, `deepseek-v4-pro`.

## Layout

```
verify-paper-formulas/
├── SKILL.md            # the skill definition + workflow Claude follows
├── README.md           # this file
├── scripts/
│   ├── or_query.sh     # one OpenRouter call → JSON {ok, model, content|error}
│   └── fan_out.sh      # runs all models in parallel → JSONL
└── prompts/
    ├── derive.md       # Round 1: independent derivation prompt
    └── refute.md       # Round 2: adversarial refutation prompt
```

## Requirements

- Claude Code
- `git`, `curl`, `jq`
- An OpenRouter API key exported as `OPENROUTER_API_KEY`
  (the scripts read `~/.config/openrouter.env`; the key is **never** written to
  any report, log, or file)

## Install

Clone into your personal Claude Code skills directory:

```bash
git clone https://github.com/Lassemind/verify-paper-formulas.git \
  ~/.claude/skills/verify-paper-formulas
```

Then in Claude Code just ask it to verify a paper's formulas, or invoke the
`verify-paper-formulas` skill directly.

## Verification

The mechanics were validated against the live model panel and two synthetic
control cases:

- a deliberately **wrong** derivation (kinetic energy stated as `m v²`, missing
  the ½) — all five models flagged a **DISCREPANCY**;
- the **correct** derivation (`½ m v²`) — all five models returned **CONFIRMED**.

## License

MIT
