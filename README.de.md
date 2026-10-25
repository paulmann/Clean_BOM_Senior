# Clean BOM Senior 🧹✨

[![Version](https://img.shields.io/badge/version-3.0.0-blue.svg)](CHANGELOG.md)
[![npm-Version](https://img.shields.io/npm/v/clean-bom-senior.svg?color=red)](https://www.npmjs.com/package/clean-bom-senior)
[![npm-Downloads](https://img.shields.io/npm/dm/clean-bom-senior.svg?color=brightgreen)](https://www.npmjs.com/package/clean-bom-senior)
[![CI](https://github.com/paulmann/Clean_BOM_Senior/actions/workflows/ci.yml/badge.svg)](https://github.com/paulmann/Clean_BOM_Senior/actions/workflows/ci.yml)
[![shellcheck](https://img.shields.io/badge/shellcheck-clean-brightgreen.svg)](https://www.shellcheck.net/)
[![Plattform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey.svg)]()

<!-- md-i18n:switcher -->
**In anderen Sprachen:** [English](README.md) · Deutsch · [中文](README.zh.md) · [हिन्दी](README.hi.md) · [Español](README.es.md) · [Русский](README.ru.md)

> **Entfernt unsichtbare UTF-8-BOM und Windows-CRLF aus Quelldateien — und weiß,
> wann es das nicht darf.** Atomar, bytegenau, CI-freundlich: Eine Datei wird nur
> dann neu geschrieben, wenn die Reinigung wirklich nötig und wirklich sicher ist,
> und nie, wenn ihre BOM tragend ist.

Eine UTF-8-BOM (`EF BB BF`) am Anfang einer PHP-Datei bricht `header()`, Sessions
und JSON-APIs; CRLF-Zeilenenden aus einem Windows-Editor verunreinigen Diffs und
Shell-Skripte. Doch die naive Lösung — „jede BOM entfernen“ — **beschädigt Dateien**:
Bei UTF-16/UTF-32 *ist* die BOM das Format, und bei einer nicht-ASCII-`.txt`/`.csv`
ist sie das Einzige, was Excel und Windows Notepad die Datei als UTF-8 statt als
Zeichensalat lesen lässt.

**Clean BOM Senior v3 beantwortet vor jedem Schreibvorgang zwei Fragen pro Datei,
anhand ihrer tatsächlichen Bytes:**

1. *Ist eine Reinigung überhaupt nötig?* — bytegenaue Prüfung der ganzen Datei
   (eine saubere Datei wird nie neu geschrieben: Inode, mtime und Hardlinks
   bleiben unverändert).
2. *Wird die BOM vielleicht gebraucht?* — die [**Smart BOM Policy**](docs/SMART-BOM.md):
   UTF-16/32 und Binärdateien werden ausnahmslos abgelehnt, ungültiges UTF-8 wird
   geschützt, „sensibler“ Text behält seine BOM mit Begründung, und Codedateien
   (php/js/css/html/xml…) werden gereinigt. Jede Entscheidung wird mit Begründung
   protokolliert und ist als JSON verfügbar.

---

## Schnellstart

```bash
# Anywhere (npm, Node ≥ 18 — Linux, macOS, Windows):
npm install -g clean-bom-senior
bom --dry-run                      # explain what would change and why
bom                                # clean the current tree, smart & safe

# POSIX (no npm needed):
curl -fsSLO https://raw.githubusercontent.com/paulmann/Clean_BOM_Senior/main/clean-bom-senior.sh
chmod +x clean-bom-senior.sh
./clean-bom-senior.sh --self-test  # verify the tool on THIS machine
./clean-bom-senior.sh              # clean the current tree

# CI gate — fail the build when anything needs cleaning:
bom --check                        # exit 10 = dirty, 0 = clean
```

## Was Sie bekommen

| | |
|---|---|
| 🧠 **Smart BOM Policy** | Entfernt nie eine BOM, die die Datei benötigt: UTF-16/32 wird ausnahmslos abgelehnt, NUL-Binärdateien werden abgelehnt, ungültiges UTF-8 wird geschützt, für Excel/Notepad sensibler Text (`txt csv ps1…`, nicht-ASCII) bleibt mit Begründung erhalten — `--force` hebt die weichen Fälle auf. [Vollständige Entscheidungstabelle →](docs/SMART-BOM.md) |
| 🔬 **Bytegenaue Erkennung** | Prüfung der ganzen Datei, keine Stichprobenfenster: keine Fehlalarme (v2 schrieb Dateien neu, deren *Hexdump* lediglich `0d0a` enthielt), keine übersehenen Fälle (v2 übersah CRLF jenseits von Byte 1024). |
| 🛡️ **Atomare und geprüfte Schreibvorgänge** | Temporäre Datei im selben Verzeichnis → Inhaltsprüfung → `rename(2)`. Hardlinks werden an Ort und Stelle neu geschrieben, Symlinks aufgelöst, Rechte, Eigentümer und Zeitstempel beibehalten. Ein Absturz kann nie eine halb geschriebene Datei hinterlassen. |
| 🤖 **CI-nativ** | `--check` (Exit 10), `--json`-Bericht, `--strict`, `--quiet`, `NO_COLOR`, deterministische Ausgabe, bereit für Git-Hooks. |
| 🚫 **Vernünftiger Geltungsbereich** | `.git`, `.svn`, `.hg`, `node_modules` sind standardmäßig ausgeschlossen; `--ext/--add-ext/--exclude/--exclude-dir/--max-size/--git` formen den Rest. |
| 🔄 **Selbstaktualisierend** | `--check-update` (Exit 11) und `--update` mit Inhaltsprüfung; Mirrors über `CLEAN_BOM_UPDATE_URL`; npm-Installationen werden an npm verwiesen. [Details →](docs/UPDATE.md) |
| 📖 **Ausführliche Hilfe** | `--help` plus 12 Themen: `--help bom-policy`, `--help ci`, `--help json`, … |

## Implementierungen — ein Vertrag

| Implementierung | Version | Plattformen | Status |
|---|---|---|---|
| [`clean-bom-senior.sh`](clean-bom-senior.sh) | **3.0.0** | Linux, macOS, *BSD, WSL, Git Bash (bash ≥ 3.2, GNU-**und**-BSD-Userland) | Referenz |
| [`bin/bom.js`](bin/bom.js) — npm `bom` / `clean-bom-senior` | **3.0.0** | **überall, wo Node ≥ 18 läuft, inkl. nativem Windows** | native CLI |
| [`clean-bom-senior.ps1`](clean-bom-senior.ps1) | **3.0.0** | **PowerShell 7.6+ — Windows, Linux, macOS. Kein externes Werkzeug erforderlich** | vollständige Portierung |
| [`clean-bom-senior.bat`](clean-bom-senior.bat) | 2.07.0 | Windows `cmd.exe` (kein PowerShell, keine Git Bash) | **Legacy**, beim v2-Vertrag eingefroren |

Die drei v3-Implementierungen sind durch zwei Differentialtests bytegenau
aneinander gebunden — `node tests/node/run-tests.mjs differential` (sh ↔ node) und
`python3 tests/ps/differential.py` (sh ↔ ps1, 77 Szenarien). Unter Windows nutzen
Sie die npm-CLI oder die PowerShell-Portierung; die Batch-Portierung bleibt für
Rechner, die beides nicht haben, und ist ein **v2.07**-Werkzeug — warum sie nicht
nach v3 übernommen wurde, steht in [`docs/BAT-PORT.md`](docs/BAT-PORT.md) §8.
Vertrag: [`docs/CLI-CONTRACT.md`](docs/CLI-CONTRACT.md).

---

## Installation

### npm (empfohlen — alle Plattformen, inkl. Windows)

```bash
npm install -g clean-bom-senior
bom --version            # → bom version 3.0.0 (Node.js implementation)
clean-bom-senior --help  # same tool, longer alias
```

### POSIX-Shell — aus dem Quelltext

```bash
git clone https://github.com/paulmann/Clean_BOM_Senior.git
cd Clean_BOM_Senior
sudo install -m 755 clean-bom-senior.sh /usr/local/bin/clean-bom-senior
clean-bom-senior --self-test
```

### POSIX-Shell — Einzeiler

```bash
curl -fsSL https://raw.githubusercontent.com/paulmann/Clean_BOM_Senior/main/clean-bom-senior.sh \
  -o clean-bom-senior.sh && chmod +x clean-bom-senior.sh
```

### PowerShell 7.6+ — aus dem Quelltext (Windows, Linux, macOS)

Für die Reinigung ist kein externes Werkzeug nötig; alles läuft über .NET-Byte-I/O.

```powershell
git clone https://github.com/paulmann/Clean_BOM_Senior.git
cd Clean_BOM_Senior
./clean-bom-senior.ps1 --self-test          # 10 fixtures, verifies this host
./clean-bom-senior.ps1 --help bom-policy    # the Smart BOM Policy in detail

# optional: put it on PATH
Copy-Item clean-bom-senior.ps1 "$HOME/.local/bin/clean-bom-senior.ps1"
```

> Die Datei ist **absichtlich reines ASCII**, damit `./clean-bom-senior.ps1`
> unter Unix direkt läuft — eine UTF-8-BOM vor dem Shebang würde den Kernel
> auf `/bin/sh` zurückfallen lassen. Die eingebaute Hilfe gibt trotzdem die
> Gedankenstriche und Pfeile der Referenz aus: Sie liegen als Platzhalter vor
> und werden bei der Ausgabe wiederhergestellt.
> Siehe [`docs/PS-PORT.md`](docs/PS-PORT.md) §5.

### Selbstaktualisierung (alle drei v3-Implementierungen)

```bash
clean-bom-senior.sh --check-update   # exit 11 when a newer release exists
clean-bom-senior.sh --update         # verified atomic self-replace
```

```powershell
./clean-bom-senior.ps1 --check-update   # same contract, same exit codes
./clean-bom-senior.ps1 --update         # verifies the #Requires header + version stamp
```

```bash
npm i -g clean-bom-senior@latest     # the npm way (enforced automatically:
                                     # --update refuses npm-managed installs)
```

### Deinstallation

```bash
npm uninstall -g clean-bom-senior    # npm install
sudo rm /usr/local/bin/clean-bom-senior   # manual install
```

---

## Verwendung

```bash
clean-bom-senior.sh [OPTIONS] [PATH...]
```

`PATH` ist eine Datei **oder ein Verzeichnis** (wird rekursiv durchsucht); ohne
`PATH` wird das aktuelle Verzeichnis durchsucht. Optionen dürfen dazwischen
stehen; `--` beendet die Optionsauswertung (Dateinamen dürfen daher mit `-`
beginnen).

### Die alltäglichen Befehle

```bash
bom                          # clean the tree with smart safe defaults
bom --dry-run                # what would change, and why (no writes)
bom --check                  # CI gate: exit 10 if anything is dirty
bom --check --json > r.json  # machine-readable gate report
bom src index.php            # a directory + a file
bom --git                    # only git-tracked files
bom -v                       # per-file log with every decision
```

### Smart BOM Policy in einem Bild

```
                      ┌─ UTF-16/32 BOM ────────────► REFUSE (never touch)
file bytes ──classify─┼─ NUL bytes ────────────────► REFUSE (never touch)
                      ├─ invalid UTF-8 ────────────► PROTECT (--force: byte-clean)
                      ├─ UTF-8 BOM + sensitive ext ┐
                      │   + non-ASCII content ─────► KEEP BOM, fix CRLF, explain
                      ├─ UTF-8 BOM + code/ASCII ───► STRIP BOM (+ fix CRLF)
                      └─ no BOM, no CRLF ──────────► CLEAN: not rewritten at all
```

Details, Begründung und Quellen: [`docs/SMART-BOM.md`](docs/SMART-BOM.md) ·
`bom --help bom-policy`.

### Flag-Referenz (gekürzt — vollständig: `--help options`)

| Gruppe | Flags |
|---|---|
| Operation | `-n/--dry-run` `-c/--check` `-f/--fix` `-v/--verbose` `-q/--quiet` `--silent` `-j/--json` `--color auto\|always\|never` `--log-file FILE` |
| Auswahl | `--ext LIST` `--add-ext LIST` `--exclude GLOB` `--exclude-dir NAME` `--no-default-excludes` `--max-size 10M` `--git` |
| BOM-Richtlinie | `--bom-policy auto\|strip\|keep` `--sensitive-ext LIST` `--force` |
| Transformation | `--no-bom-clear` `--no-rn-normalize`/`--no-crlf-normalize` `--update-mtime` `--backup` `--backup-dir DIR` |
| Info | `-h/--help [TOPIC]` `-V/--version` `--self-test` `--completion` `--strict` |
| Update | `--check-update` `--update` |

### Exit-Codes

| Code | Bedeutung |
|---|---|
| 0 | Erfolg (sauberer Baum oder alles gereinigt) |
| 1 | Fehler pro Datei oder `--strict` hat beibehaltene/geschützte Dateien gesehen |
| 2 | Aufruffehler |
| 3 | Umgebungsproblem (Abhängigkeiten, Temp, Update-Netzwerk, npm-verwaltetes `--update`) |
| 4 | kritischer interner Fehler |
| **10** | `--check`: Dateien müssen gereinigt werden |
| **11** | `--check-update`: Aktualisierung verfügbar |

---

## CI / CD

### GitHub Actions

```yaml
- uses: actions/setup-node@v4
  with: { node-version: 20 }
- run: npm i -g clean-bom-senior
- name: BOM/CRLF gate
  run: bom --check --quiet --json > bom-report.json || exit $?
  # exit 10 fails the job; upload bom-report.json as an artifact
```

### Pre-Commit-Hook

```bash
#!/bin/sh
# .git/hooks/pre-commit  (chmod +x)
clean-bom-senior --check --git --quiet || {
  echo "BOM/CRLF issues found. Fix with: clean-bom-senior --git" >&2
  exit 1
}
```

### Make

```make
.PHONY: bom-check bom-fix
bom-check:
	@bom --check --quiet
bom-fix:
	@bom --quiet
```

Weitere Rezepte: `bom --help ci`.

---

## Warum BOMs schaden (die PHP-Geschichte)

```php
\xEF\xBB\xBF<?php           ← invisible BOM
header('Content-Type: application/json');
```

- `Warning: Cannot modify header information — headers already sent`: Die BOM
  *ist* Ausgabe, die vor dem Lauf von `header()` gesendet wird.
- Kaputte JSON-/XML-APIs: Konsumenten scheitern an `\uFEFF{...}`.
- Zusammengebaute Builds und `include`te Dateien schleppen BOMs mitten in den
  Datenstrom ein.
- Gemischte CRLF-/LF-Bäume erzeugen Diffs über die ganze Datei und brechen
  `#!/bin/sh`-Shebangs (`/bin/sh^M: bad interpreter`).

Und warum „alles entfernen“ *ebenfalls* falsch ist:

- **UTF-16/UTF-32**: Die BOM ist die Signatur der Byte-Reihenfolge — entfernt man
  sie, ist die Datei beschädigt (Notepads „Unicode“-`.txt` ist genau das).
- **Excel / älteres Notepad / Win32-ANSI-APIs**: UTF-8 ohne BOM in `.csv`/`.txt`
  mit nicht-ASCII-Inhalt erscheint als Zeichensalat (`café` → `cafÃ©`).
- **Windows PowerShell 5.1**: liest nicht-ASCII-`.ps1` ohne BOM als ANSI — das
  Skript ändert seine Bedeutung oder schlägt fehl.

v3 behält die BOM genau dort, wo sie tragend ist, und entfernt sie genau dort,
wo sie Schmutz ist — und teilt pro Datei mit, welche Entscheidung getroffen wurde.

---

## Sicherheitsgarantien

- **Nie neu geschrieben, wenn nicht nötig**: Saubere Dateien behalten Inode und
  mtime (durch Tests zugesichert).
- **Atomar und geprüft**: Temporäre Datei im selben Verzeichnis → Prüfung
  (BOM weg / CRLF weg / nichts hinzugefügt) → `rename(2)`; Rollback-Kopien für
  Neuschreiben an Ort und Stelle; keine Reste (zugesichert).
- **Harte Ablehnungen, die kein Flag aufhebt**: UTF-16/32, NUL-Binärdateien
  (`--force` öffnet nur die *weichen* Schutzmechanismen).
- **Metadaten**: Rechte immer, Eigentümer als root, Zeitstempel geänderter
  Dateien standardmäßig (`--update-mtime` verzichtet darauf).
- **Hardlinks und Symlinks**: Links bleiben Links (Neuschreiben an Ort und
  Stelle + Warnung); Symlink-Argumente werden aufgelöst; der Durchlauf folgt
  nie Symlinks.
- Vollständige Liste: `bom --help safety` · [`docs/SMART-BOM.md`](docs/SMART-BOM.md) §4.

## Dokumentation

| Dokument | Inhalt |
|---|---|
| [`docs/SMART-BOM.md`](docs/SMART-BOM.md) | die Richtlinie: Entscheidungstabelle, Begründung, Referenzen zu Kodierungen |
| [`docs/CLI-CONTRACT.md`](docs/CLI-CONTRACT.md) | normativer v3-Vertrag: Flags, Exit-Codes, Streams, JSON-Schema, Byte-Semantik |
| [`docs/UPDATE.md`](docs/UPDATE.md) | Entwurf der Selbstaktualisierung, Prüfung, Mirrors, Release-Checkliste |
| [`docs/TESTING.md`](docs/TESTING.md) | Testarchitektur, Abdeckungskarte, die beiden Differentiale, Fallstricke beim PowerShell-Aufruf |
| [`docs/PS-PORT.md`](docs/PS-PORT.md) | die PowerShell-Portierung: Aufbau, Abweichungen, getroffene Fallstricke, was sie in der Referenz gefunden hat |
| [`docs/LLM-AGENT-USAGE.md`](docs/LLM-AGENT-USAGE.md) | das Werkzeug an einen LLM-Agenten anbinden: Skill und Regelzeiger, Einstiegspunkte je Plattform, Installation bei Fehlen |
| [`skills/clean-bom-crlf/SKILL.md`](skills/clean-bom-crlf/SKILL.md) | der portable Skill selbst, für jedes Agent-Framework, das Skills lädt |
| [`docs/PROMPT-OTHER-HARNESS.md`](docs/PROMPT-OTHER-HARNESS.md) | Copy-and-paste-Prompt, mit dem ein fremder Agent die Regel übernimmt (RU) |
| [`CHANGELOG.md`](CHANGELOG.md) | v3.0.0: jeder behobene v2-Defekt, gemessen |
| [`docs/BAT-PORT.md`](docs/BAT-PORT.md) | (Legacy) wie die cmd.exe-Portierung funktioniert und warum es keine v3-Batch-Portierung gibt |
| [`docs/RAGRAF-REPORT.md`](docs/RAGRAF-REPORT.md) | (Legacy) Prüfbericht aus der v2-Zeit |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) · [`SECURITY.md`](SECURITY.md) | Grundregeln · Meldung von Sicherheitslücken |

## Entwicklung und Tests

```bash
bash tests/sh/run-tests.sh -v    # reference suite (167 assertions)
node tests/node/run-tests.mjs    # Node suite (161 assertions) + sh↔node differential
pwsh -File tests/ps/run-tests.ps1 # PowerShell suite (237 assertions) + sh↔ps1 differential
python3 tests/ps/differential.py # sh ↔ ps1 byte parity, 77 scenarios
bom --self-test                  # built-in acceptance, any host
./clean-bom-senior.ps1 --self-test
shellcheck clean-bom-senior.sh   # 0 findings
bash scripts/check-version-consistency.sh
python3 scripts/gen-ps-help.py --check   # ps1 help still derived from the reference
```

CI-Matrix: shellcheck → bash-Suiten (Ubuntu, macOS) → Node-Suiten
({18,20,22} × {Ubuntu, macOS, Windows}) → PowerShell-Suiten (Ubuntu, macOS,
Windows) → beide Differentiale + Help-Sync-Gate → npm pack → Versionswächter.
Siehe [`docs/TESTING.md`](docs/TESTING.md).

## Anforderungen

- **npm-CLI**: Node ≥ 18. Sonst nichts — jedes Betriebssystem.
- **PowerShell-Portierung**: PowerShell 7.6+ (Core). Für die Reinigung ist sonst
  nichts erforderlich; `git` für `--git`, `curl` für `--update`/`--check-update`
  (`Invoke-WebRequest` ist der Rückfallweg), `stat`/`fsutil` für die Erkennung
  von Hardlinks, `chown` für die Eigentümerübergabe als root.
- **Shell-Referenz**: bash ≥ 3.2 (das macOS-System-bash genügt), Standard-Userland
  (`find sed awk od grep stat tail wc tr mv cp touch chmod mktemp`);
  optional: `iconv` (UTF-8-Prüfung), `curl`/`wget` (`--update`), `git`
  (`--git`).
- **Legacy-Portierungen**: PowerShell 7.6+ / Windows 10–11 `cmd.exe`.

## Lizenz

[PolyForm Noncommercial 1.0.0](LICENSE) © Mikhail Deynekin — [deynekin.com](https://deynekin.com)
