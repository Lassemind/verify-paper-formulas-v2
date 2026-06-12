---
description: Physik-Paper Abschnitt für Abschnitt mit mehreren LLMs prüfen → Verbesserungs-Report
argument-hint: <pfad/zu/main.tex oder Overleaf-Git-URL>
---

Review the paper given in `$ARGUMENTS` using the **verify-paper-formulas** skill
(installed at `~/.claude/skills/verify-paper-formulas`).

Steps:

1. If `$ARGUMENTS` is an Overleaf/git URL, clone it to a temp dir and locate the
   main `.tex` (usually `main.tex`). If it is a local path, use it directly. If
   it is empty, ask the user for the paper location.
2. Verify an OpenRouter key is available (env, skill-folder `.env`, or
   `~/.config/openrouter.env`). If none is found, ask the user for their key
   and write it to `~/.config/openrouter.env` (mode 600). Never echo or log it.
3. Run the review **in the background** (it takes 15–20 min):
   ```
   ~/.claude/skills/verify-paper-formulas/scripts/review_sections.sh <paper.tex> <paper-dir>/verify-reports/section-review-$(date +%F)
   ```
4. Tell the user it is running, roughly what it costs (~4–8 €), and check
   progress when notified. If individual calls fail, simply re-run the same
   command — it resumes.
5. When finished, read `improvement-report.md` and present the user a short
   summary (counts per 🔴/🟡/🟢 and the most important findings), pointing to
   the full report file.

The paper is never modified.
