#!/usr/bin/env bash
# One-time setup: checks dependencies, stores the user's own OpenRouter key,
# and (optionally) installs the /verify-paper slash command for Claude Code.
# Safe to re-run; never overwrites an existing key without asking.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
KEY_FILE="$HOME/.config/openrouter.env"

echo "== verify-paper-formulas Setup =="

# 1. Dependencies
MISSING=""
for c in git curl jq; do
  command -v "$c" >/dev/null 2>&1 || MISSING="$MISSING $c"
done
if [ -n "$MISSING" ]; then
  echo "Fehlende Programme:$MISSING"
  echo "Mac: brew install$MISSING   |   Linux: sudo apt install$MISSING"
  exit 1
fi
echo "✓ git, curl, jq vorhanden"

# 2. OpenRouter key (each user brings their own)
have_key() {
  [ -n "${OPENROUTER_API_KEY:-}" ] && return 0
  [ -f "$REPO_ROOT/.env" ] && grep -q '^OPENROUTER_API_KEY=sk-' "$REPO_ROOT/.env" && return 0
  [ -f "$KEY_FILE" ] && grep -q '^OPENROUTER_API_KEY=sk-' "$KEY_FILE" && return 0
  return 1
}
if have_key; then
  echo "✓ OpenRouter-Schlüssel gefunden"
else
  echo "Kein OpenRouter-Schlüssel gefunden."
  echo "Schlüssel anlegen: https://openrouter.ai/keys"
  printf "Schlüssel einfügen (Eingabe bleibt unsichtbar): "
  read -rs KEY
  echo
  case "$KEY" in
    sk-or-*) ;;
    *) echo "Das sieht nicht wie ein OpenRouter-Schlüssel aus (beginnt mit sk-or-). Abbruch."; exit 1 ;;
  esac
  mkdir -p "$(dirname "$KEY_FILE")"
  printf 'OPENROUTER_API_KEY=%s\n' "$KEY" > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  echo "✓ Schlüssel gespeichert in $KEY_FILE (nur für dich lesbar)"
fi

# 3. Claude Code integration (optional, skipped if Claude Code isn't set up)
if [ -d "$HOME/.claude" ]; then
  SKILL_DIR="$HOME/.claude/skills/verify-paper-formulas"
  if [ ! -e "$SKILL_DIR" ]; then
    mkdir -p "$HOME/.claude/skills"
    ln -s "$REPO_ROOT" "$SKILL_DIR"
    echo "✓ Als Claude-Code-Skill verlinkt ($SKILL_DIR)"
  else
    echo "✓ Claude-Code-Skill bereits vorhanden"
  fi
  mkdir -p "$HOME/.claude/commands"
  cp "$REPO_ROOT/commands/verify-paper.md" "$HOME/.claude/commands/verify-paper.md"
  echo "✓ Slash-Command installiert: in Claude Code einfach  /verify-paper <pfad/zu/main.tex>"
fi

echo
echo "Fertig. Direkt loslegen:"
echo "  scripts/review_sections.sh /pfad/zum/main.tex ./review-ergebnis"
echo "oder in Claude Code:  /verify-paper /pfad/zum/main.tex"
