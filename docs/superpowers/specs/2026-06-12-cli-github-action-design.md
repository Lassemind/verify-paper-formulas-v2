# verify-paper v2 — Standalone CLI + GitHub Action

**Datum:** 2026-06-12
**Status:** Entwurf (vom Nutzer zu reviewen)
**Kontext:** Auftrag von Dieter Suess (Mails 29.05./03.06.2026): Appendix A, B, … des
`energy_harvesting`-Papers von *verschiedenen* LLMs unabhängig ableiten und gegenseitig
checken lassen, plus mehr (numerische) Test Cases. Bisherige Umsetzung ist eine
Claude-Code-Skill mit 5-Modell-Panel (~150 Calls, ~10 €/Lauf). Ziele des Umbaus:
läuft ohne Claude Code auf jedem Laptop, für Dieter per Browser-Klick bedienbar,
günstiger pro Lauf, Abschnitts-Checks zusätzlich zur Formel-Ebene.

## Entscheidungen

1. **Modell-Panel: 3 statt 5.** `anthropic/claude-fable-5`, `openai/gpt-5.5`,
   `google/gemini-3.1-pro-preview` — ein Spitzenmodell pro Lab. Grok und DeepSeek
   entfallen (wenig unabhängiges Signal, häufigste Timeouts). Die Multi-LLM-Vorgabe
   des Profs bleibt erfüllt; ein Single-Model-Setup ist explizit ausgeschlossen.
2. **Fable 5 in den Single-Pass-Rollen:** Claim-/Section-Extraktion, Round-3-Schlichtung
   (`resolve`), Report-Synthese (`SYNTH_MODEL`). Dort zählt das stärkste Modell, ohne
   die Unabhängigkeit des Panels zu berühren. (Fable auf OpenRouter: $10/$50 pro MTok.)
3. **Auslieferung: standalone CLI als Kern + GitHub-Actions-Wrapper für Dieter.**
   Keine Webseite (Hosting, Key-im-Browser, 10–20-min-Läufe, Overleaf-Clone bräuchte
   Backend). Die Claude-Skill bleibt als dünner Wrapper, der das CLI aufruft.

## Architektur

```
bin/verify-paper <overleaf-url-oder-pfad> [Optionen]
  ├─ Phase 0  Fetch        git clone/pull des Papers (Overleaf-Git oder lokaler Pfad)
  ├─ Phase 1  Extraktion   EIN Fable-Call übers ganze Paper (1M Kontext reicht) →
  │                          a) Section-Befunde (Notation, Definitionen, Konventionen)
  │                          b) Cross-Appendix-Notationscheck (fällt hier gratis ab)
  │                          c) Claim-Dateien im bestehenden ===CLAIM===-Format
  │                             (inkl. ===NUMBERS=== wo Tabellenwerte existieren)
  ├─ Phase 2  Verifikation  Eskalations-Pipeline pro Claim:
  │             Stufe 0    Python-Numerikcheck zuerst (deterministisch, ~kostenlos)
  │             Stufe 1    3 Modelle, unabhängige Ableitung (immer — Multi-LLM-Kern)
  │             Stufe 2    adversariale Refute-Runde NUR bei Dissens in Stufe 1
  │                        oder Numerik-Fail (--full erzwingt sie immer)
  │             Stufe 3    Fable-Schlichtung nur bei echtem Split
  │                        Cache: sha256(claim+context+modelset+promptversion) →
  │                        unveränderte Claims übersprungen, Verdicts wiederverwendet
  ├─ Phase 3  Synthese      synthesize_report.sh (Fable) + Section-Befunde
  │                          → Markdown + HTML
  └─ Output   verify-reports/YYYY-MM-DD-<paper>.md / -review.md / -review.html
```

**Warum diese Reihenfolge:** Der Python-Check ist härter und billiger als jede
LLM-Debatte — wo Tabellenwerte existieren, entscheidet er. Die adversariale Runde
feuert bei einem korrekten Paper fast nie; gespart wird dort, nicht an der
3-Modell-Unabhängigkeit (explizite Anforderung des Profs). Bewusst verworfen:
mehrere Claims pro Prompt bündeln (ein Parse-Fehler killt mehrere Verdicts,
Einzelverdicts werden unschärfer) und Single-Model-Betrieb.

### CLI-Interface

```
verify-paper <quelle> [--appendix A,B,…] [--quick | --full] [--out DIR] [--dry-run]
  --quick   nur Round 1, kein refute, kein Python-Numerikcheck (~1–2 €)
  (default) Round 2 konditional bei Dissens, Numerik wo NUMBERS vorhanden (~3–5 €)
  --full    Round 2 immer, Round 3 bei Split, volle Numerik (~5–6 €)
  --dry-run geplante Claims/Calls anzeigen, keine API-Kosten
```

Voraussetzungen nur: `git`, `curl`, `jq`, `python3`, `OPENROUTER_API_KEY`
(Auflösung wie bisher: env / .env / ~/.config/openrouter.env).

### Phase 1 ersetzt die interaktive Phase A

Bisher extrahiert Claude Code die Claims interaktiv — der einzige Teil, der nicht
ohne Claude Code läuft. Neu: ein Prompt (`prompts/extract.md`) bekommt den
line-numbered `.tex` eines Appendix und liefert striktes JSON:

```json
{ "section_findings": [ {"issue", "tex_line", "severity"} ],
  "claims": [ {"id", "title", "claim", "context", "numbers?"} ] }
```

Das CLI schreibt daraus die Claim-Dateien (Kontrakt von `run_batch.sh` bleibt
unverändert) und `.paper_path`. Section-Befunde (z. B. fehlende
Vorzeichenkonvention wie in Appendix E) fließen direkt in den Report.

### Inkrementeller Cache

`cache/<sha256>.json` pro Claim (Hash über Claim-Text + Kontext + Modell-Set +
Prompt-Version). Treffer → Verdict wiederverwenden, Eintrag im Report als
„unverändert seit <Datum>" markiert. Damit kosten Folgeläufe auf dem lebenden
Overleaf-Paper ~1–2 € statt ~10 €. `--no-cache` erzwingt Neuprüfung.

### GitHub Action (`.github/workflows/verify.yml`)

- Trigger: `workflow_dispatch` mit Inputs `appendices` (default: alle) und
  `mode` (quick/default/full); optional `schedule` (z. B. wöchentlich).
- Secrets: `OPENROUTER_API_KEY`, `OVERLEAF_GIT_TOKEN` (Overleaf-Git braucht Auth).
- Schritte: checkout Tool-Repo → clone Paper → `verify-paper` → Report
  (md + html) als Artifact hochladen; optional Job-Summary mit der Verdict-Tabelle.
- Bedienung für Dieter: Browser → Actions → „Run workflow" → Artifact laden.
  Null Installation.

### Was sich an den bestehenden Skripten ändert

| Datei | Änderung |
|---|---|
| `scripts/fan_out.sh` | Default-Modellset → 3er-Panel |
| `scripts/or_query.sh` | `OR_MOCK_DIR`-Modus: Dosen-Antworten statt API (für Tests) |
| `scripts/run_claim.sh` | Round 2 konditional (Skip bei einstimmigem Round 1, außer `VPF_FULL=1`) |
| `scripts/run_batch.sh` | Cache-Lookup/Write um `run_claim.sh` herum |
| `scripts/synthesize_report.sh` | `SYNTH_MODEL` → Fable; Section-Befunde einmischen; HTML-Export |
| `prompts/extract.md` | **neu** (Phase-1-Extraktion) |
| `bin/verify-paper` | **neu** (Orchestrierung, ersetzt SKILL.md-Phase A–C) |
| `SKILL.md` | schrumpft auf „rufe `bin/verify-paper` auf" |

## Fehlerbehandlung

Unverändert zur v1-Philosophie: kein Key → harter Abbruch mit Meldung; einzelnes
Modell-Timeout → „(no result)", Lauf geht weiter; Paper-Clone scheitert → klare
Meldung (lokalen Pfad angeben / Token prüfen). Neu: Extraktion liefert kein
valides JSON → ein Retry, dann Abbruch mit Roh-Antwort im Log. Key landet nie in
Reports, Logs oder Artifacts.

## Tests

Zwei getrennte Fragen, zwei getrennte Testarten — Plumbing und Detektionsqualität
nicht in einem teuren E2E-Test vermischen:

1. **Mock-Layer (Plumbing, 0 €, CI bei jedem Push).** `or_query.sh` bekommt einen
   `OR_MOCK_DIR`-Modus: statt OpenRouter werden aufgezeichnete JSON-Antworten
   ausgeliefert. `tests/run.sh` prüft damit offline und deterministisch:
   Extraktion → Claim-Dateien (Fixture-Appendix mit 2 Claims, 1× NUMBERS),
   Eskalationslogik (Dissens-Mock → Round 2 feuert, Konsens-Mock → nicht),
   Cache-Hit beim zweiten Lauf, `--quick` macht keine Round-2-Calls,
   JSON-Retry bei kaputter Extraktionsantwort, Report-Assembly.
2. **Seeded-Error-Benchmark (Detektionsqualität, ~1–2 €, manuell/`tests/benchmark.sh`).**
   Appendix-Kopie mit absichtlich injizierten Fehlern (Vorzeichen, Faktor 2,
   falscher Exponent) plus Lehrbuch-Claims mit bekannter Wahrheit. Erwartung:
   injizierte Fehler 🔴, korrekte 🟢. Misst die Erkennungsrate des Tools selbst.
3. **Overleaf-Historie als natürlicher Testsatz (einmaliges Validierungs-Experiment).**
   Alte Commits des Papers enthalten echte, später gefixte Fehler. Tool auf einen
   alten Stand laufen lassen → findet es die später korrigierten Stellen? Echte
   Fehler statt künstlicher; zugleich Beleg fürs Tool gegenüber Dieter.
4. **`--dry-run`-Flag:** zeigt geplante Calls/Claims ohne API-Kosten; testet
   CLI-Parsing und Extraktionsplan gratis.

Action-Smoke-Test läuft gegen den Mock-Layer statt echte API (kein Key, kein
Token nötig).

## Offene Punkte

1. **Overleaf-Auth in CI:** Overleaf-Git-Token von Dieter/Lasse als Secret, oder
   Overleaf↔GitHub-Sync aktivieren. Vor dem Action-Teil klären.
2. Wo das Tool-Repo für Dieter liegt (bestehendes `Lassemind/verify-paper-formulas`
   oder Fork in der Gruppe).
