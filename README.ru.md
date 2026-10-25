# Clean BOM Senior 🧹✨

[![Версия](https://img.shields.io/badge/version-3.0.0-blue.svg)](CHANGELOG.md)
[![версия npm](https://img.shields.io/npm/v/clean-bom-senior.svg?color=red)](https://www.npmjs.com/package/clean-bom-senior)
[![загрузки npm](https://img.shields.io/npm/dm/clean-bom-senior.svg?color=brightgreen)](https://www.npmjs.com/package/clean-bom-senior)
[![CI](https://github.com/paulmann/Clean_BOM_Senior/actions/workflows/ci.yml/badge.svg)](https://github.com/paulmann/Clean_BOM_Senior/actions/workflows/ci.yml)
[![shellcheck](https://img.shields.io/badge/shellcheck-clean-brightgreen.svg)](https://www.shellcheck.net/)
[![Платформа](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey.svg)]()

<!-- md-i18n:switcher -->
**На других языках:** [English](README.md) · [Deutsch](README.de.md) · [中文](README.zh.md) · [हिन्दी](README.hi.md) · [Español](README.es.md) · Русский

> **Убирает невидимый UTF-8 BOM и виндовые CRLF из исходных файлов — и знает,
> когда этого делать нельзя.** Атомарно, побайтово точно, с оглядкой на CI: файл
> перезаписывается только тогда, когда очистка действительно нужна и действительно
> безопасна, и никогда — когда его BOM несущий.

UTF-8 BOM (`EF BB BF`) в начале PHP-файла ломает `header()`, сессии и JSON API;
CRLF, оставленные виндовым редактором, засоряют диффы и shell-скрипты. Но
наивное решение — «снять все BOM» — **портит файлы**: у UTF-16/UTF-32 BOM *и есть*
формат, а для не-ASCII `.txt`/`.csv` он — единственное, что заставляет Excel и
«Блокнот» Windows прочитать файл как UTF-8, а не как кракозябры.

**Clean BOM Senior v3 отвечает на два вопроса по каждому файлу, по его
фактическим байтам, до любой записи:**

1. *Нужна ли очистка вообще?* — побайтовое определение по всему файлу (чистый
   файл не перезаписывается: inode, mtime и жёсткие ссылки остаются нетронутыми).
2. *Может, BOM обязателен?* — [**Smart BOM Policy**](docs/SMART-BOM.md):
   UTF-16/32 и бинарные файлы отклоняются безусловно, невалидный UTF-8
   защищается, «чувствительный» текст сохраняет BOM вместе с объяснением, а файлы
   кода (php/js/css/html/xml…) очищаются. Каждое решение записывается в журнал
   с причиной и доступно в JSON.

---

## Быстрый старт

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

## Что вы получаете

| | |
|---|---|
| 🧠 **Умная политика BOM** | Никогда не снимает BOM, который файлу нужен: UTF-16/32 отклоняются безусловно, бинарные с NUL — отклоняются, невалидный UTF-8 защищается, чувствительный для Excel и «Блокнота» текст (`txt csv ps1…`, не-ASCII) сохраняется с объяснением — `--force` снимает мягкие случаи. [Полная таблица решений →](docs/SMART-BOM.md) |
| 🔬 **Побайтовое определение** | Сканируется весь файл, без окон выборки: ни ложных срабатываний (v2 перезаписывала файлы, у которых `0d0a` встречался лишь в *hex-дампе*), ни пропусков (v2 не видела CRLF после байта 1024). |
| 🛡️ **Атомарная запись с проверкой** | Временный файл в том же каталоге → проверка содержимого → `rename(2)`. Жёсткие ссылки перезаписываются на месте, симлинки раскрываются, права, владелец и метки времени сохраняются. Сбой не оставит недописанного файла. |
| 🤖 **Родной для CI** | `--check` (код 10), отчёт `--json`, `--strict`, `--quiet`, `NO_COLOR`, детерминированный вывод, готовность к git-хукам. |
| 🚫 **Разумные границы** | `.git`, `.svn`, `.hg`, `node_modules` исключены по умолчанию; `--ext/--add-ext/--exclude/--exclude-dir/--max-size/--git` задают остальное. |
| 🔄 **Самообновление** | `--check-update` (код 11) и `--update` с проверкой содержимого; зеркала через `CLEAN_BOM_UPDATE_URL`; установки из npm перенаправляются в npm. [Подробности →](docs/UPDATE.md) |
| 📖 **Подробная справка** | `--help` и 12 тем: `--help bom-policy`, `--help ci`, `--help json`, … |

## Реализации — один контракт

| Реализация | Версия | Платформы | Статус |
|---|---|---|---|
| [`clean-bom-senior.sh`](clean-bom-senior.sh) | **3.0.0** | Linux, macOS, *BSD, WSL, Git Bash (bash ≥ 3.2, userland GNU **и** BSD) | эталон |
| [`bin/bom.js`](bin/bom.js) — npm `bom` / `clean-bom-senior` | **3.0.0** | **везде, где работает Node ≥ 18, включая нативный Windows** | нативный CLI |
| [`clean-bom-senior.ps1`](clean-bom-senior.ps1) | **3.0.0** | **PowerShell 7.6+ — Windows, Linux, macOS. Внешние инструменты не нужны** | полный порт |
| [`clean-bom-senior.bat`](clean-bom-senior.bat) | 2.07.0 | Windows `cmd.exe` (без PowerShell, без Git Bash) | **устаревшая**, заморожена на контракте v2 |

Три реализации v3 прибиты друг к другу побайтово двумя дифференциальными
тестами — `node tests/node/run-tests.mjs differential` (sh ↔ node) и
`python3 tests/ps/differential.py` (sh ↔ ps1, 77 сценариев). В Windows берите
npm CLI или порт PowerShell; пакетный порт остаётся для хостов, где нет ни того,
ни другого, и это инструмент **v2.07** — см. [`docs/BAT-PORT.md`](docs/BAT-PORT.md)
§8 о том, почему его не перенесли в v3.
Контракт: [`docs/CLI-CONTRACT.md`](docs/CLI-CONTRACT.md).

---

## Установка

### npm (рекомендуется — все платформы, включая Windows)

```bash
npm install -g clean-bom-senior
bom --version            # → bom version 3.0.0 (Node.js implementation)
clean-bom-senior --help  # same tool, longer alias
```

### POSIX shell — из исходников

```bash
git clone https://github.com/paulmann/Clean_BOM_Senior.git
cd Clean_BOM_Senior
sudo install -m 755 clean-bom-senior.sh /usr/local/bin/clean-bom-senior
clean-bom-senior --self-test
```

### POSIX shell — одной строкой

```bash
curl -fsSL https://raw.githubusercontent.com/paulmann/Clean_BOM_Senior/main/clean-bom-senior.sh \
  -o clean-bom-senior.sh && chmod +x clean-bom-senior.sh
```

### PowerShell 7.6+ — из исходников (Windows, Linux, macOS)

Для очистки внешних инструментов не нужно; весь ввод-вывод — байтовые операции .NET.

```powershell
git clone https://github.com/paulmann/Clean_BOM_Senior.git
cd Clean_BOM_Senior
./clean-bom-senior.ps1 --self-test          # 10 fixtures, verifies this host
./clean-bom-senior.ps1 --help bom-policy    # the Smart BOM Policy in detail

# optional: put it on PATH
Copy-Item clean-bom-senior.ps1 "$HOME/.local/bin/clean-bom-senior.ps1"
```

> Файл **намеренно чистый ASCII**, поэтому `./clean-bom-senior.ps1` работает
> прямо в Unix — UTF-8 BOM перед шебангом заставил бы ядро отступить на
> `/bin/sh`. Встроенная справка всё равно выводит длинные тире и стрелки
> эталона: они хранятся заглушками и восстанавливаются при выводе.
> См. [`docs/PS-PORT.md`](docs/PS-PORT.md) §5.

### Самообновление (все три реализации v3)

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

### Удаление

```bash
npm uninstall -g clean-bom-senior    # npm install
sudo rm /usr/local/bin/clean-bom-senior   # manual install
```

---

## Использование

```bash
clean-bom-senior.sh [OPTIONS] [PATH...]
```

`PATH` — это файл **или каталог** (сканируется рекурсивно); без `PATH`
сканируется текущий каталог. Ключи можно перемежать; `--` завершает разбор
ключей (так что имена файлов могут начинаться с `-`).

### Команды на каждый день

```bash
bom                          # clean the tree with smart safe defaults
bom --dry-run                # what would change, and why (no writes)
bom --check                  # CI gate: exit 10 if anything is dirty
bom --check --json > r.json  # machine-readable gate report
bom src index.php            # a directory + a file
bom --git                    # only git-tracked files
bom -v                       # per-file log with every decision
```

### Умная политика BOM на одной картинке

```
                      ┌─ UTF-16/32 BOM ────────────► REFUSE (never touch)
file bytes ──classify─┼─ NUL bytes ────────────────► REFUSE (never touch)
                      ├─ invalid UTF-8 ────────────► PROTECT (--force: byte-clean)
                      ├─ UTF-8 BOM + sensitive ext ┐
                      │   + non-ASCII content ─────► KEEP BOM, fix CRLF, explain
                      ├─ UTF-8 BOM + code/ASCII ───► STRIP BOM (+ fix CRLF)
                      └─ no BOM, no CRLF ──────────► CLEAN: not rewritten at all
```

Подробности, обоснование и ссылки: [`docs/SMART-BOM.md`](docs/SMART-BOM.md) ·
`bom --help bom-policy`.

### Справочник ключей (сокращённо — полностью: `--help options`)

| Группа | Ключи |
|---|---|
| Операция | `-n/--dry-run` `-c/--check` `-f/--fix` `-v/--verbose` `-q/--quiet` `--silent` `-j/--json` `--color auto\|always\|never` `--log-file FILE` |
| Выбор файлов | `--ext LIST` `--add-ext LIST` `--exclude GLOB` `--exclude-dir NAME` `--no-default-excludes` `--max-size 10M` `--git` |
| Политика BOM | `--bom-policy auto\|strip\|keep` `--sensitive-ext LIST` `--force` |
| Преобразование | `--no-bom-clear` `--no-rn-normalize`/`--no-crlf-normalize` `--update-mtime` `--backup` `--backup-dir DIR` |
| Информация | `-h/--help [TOPIC]` `-V/--version` `--self-test` `--completion` `--strict` |
| Обновление | `--check-update` `--update` |

### Коды возврата

| Код | Значение |
|---|---|
| 0 | успех (дерево чистое либо всё очищено) |
| 1 | ошибки по отдельным файлам либо `--strict` увидел сохранённые/защищённые файлы |
| 2 | ошибка в аргументах |
| 3 | проблема окружения (зависимости, temp, сеть при обновлении, `--update` на npm-установке) |
| 4 | критическая внутренняя ошибка |
| **10** | `--check`: файлы требуют очистки |
| **11** | `--check-update`: доступно обновление |

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

### Хук pre-commit

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

Другие рецепты: `bom --help ci`.

---

## Почему BOM вредит (история про PHP)

```php
\xEF\xBB\xBF<?php           ← invisible BOM
header('Content-Type: application/json');
```

- `Warning: Cannot modify header information — headers already sent`: BOM
  *и есть* вывод, он уходит до вызова `header()`.
- Сломанные JSON/XML API: потребители спотыкаются о `\uFEFF{...}`.
- Склеенные сборки и файлы, подключённые через `include`, роняют BOM в середину
  потока.
- Смешанные CRLF/LF-деревья дают диффы на весь файл и ломают шебанги `#!/bin/sh`
  (`/bin/sh^M: bad interpreter`).

И почему «снять всё» — тоже неверно:

- **UTF-16/UTF-32**: BOM — это подпись порядка байтов, его удаление портит файл
  («Unicode»-файл `.txt` из «Блокнота» — ровно этот случай).
- **Excel / устаревший «Блокнот» / ANSI API Win32**: UTF-8 `.csv`/`.txt` без BOM
  и с не-ASCII содержимым выводится кракозябрами (`café` → `cafÃ©`).
- **Windows PowerShell 5.1**: разбирает не-ASCII `.ps1` без BOM как ANSI —
  скрипт меняет смысл или падает.

v3 сохраняет BOM ровно там, где он несущий, и снимает ровно там, где он грязь, —
и говорит, какое решение принято, по каждому файлу.

---

## Гарантии безопасности

- **Без нужды не перезаписывается**: чистые файлы сохраняют inode и mtime
  (проверяется тестами).
- **Атомарно и с проверкой**: временный файл в том же каталоге → проверка
  (BOM исчез / CRLF исчезли / ничего не добавлено) → `rename(2)`; копии для
  отката при перезаписи на месте; остатков не остаётся (проверяется).
- **Жёсткие отказы, которые не снимает ни один ключ**: UTF-16/32, бинарные
  с NUL (`--force` открывает только *мягкие* защиты).
- **Метаданные**: права — всегда, владелец — под root, метки времени изменённых
  файлов — по умолчанию (`--update-mtime` отключает).
- **Жёсткие ссылки и симлинки**: ссылки остаются ссылками (перезапись на месте +
  предупреждение); аргументы-симлинки раскрываются; обход никогда не идёт по
  симлинкам.
- Полный список: `bom --help safety` · [`docs/SMART-BOM.md`](docs/SMART-BOM.md) §4.

## Документация

| Документ | Содержание |
|---|---|
| [`docs/SMART-BOM.md`](docs/SMART-BOM.md) | политика: таблица решений, обоснование, ссылки по кодировкам |
| [`docs/CLI-CONTRACT.md`](docs/CLI-CONTRACT.md) | нормативный контракт v3: ключи, коды возврата, потоки, схема JSON, байтовая семантика |
| [`docs/UPDATE.md`](docs/UPDATE.md) | устройство самообновления, проверка, зеркала, чек-лист выпуска |
| [`docs/TESTING.md`](docs/TESTING.md) | архитектура тестов, карта покрытия, два дифференциала, ловушки запуска PowerShell |
| [`docs/PS-PORT.md`](docs/PS-PORT.md) | порт PowerShell: структура, расхождения, пойманные ловушки, что он нашёл в эталоне |
| [`docs/LLM-AGENT-USAGE.md`](docs/LLM-AGENT-USAGE.md) | как встроить инструмент в LLM-агента: указатель на навык и правила, точки входа по платформам, установка при отсутствии |
| [`skills/clean-bom-crlf/SKILL.md`](skills/clean-bom-crlf/SKILL.md) | сам переносимый навык — для любого агентского каркаса, который загружает навыки |
| [`docs/PROMPT-OTHER-HARNESS.md`](docs/PROMPT-OTHER-HARNESS.md) | готовый к копированию промпт, который заставляет чужого агента принять правило (RU) |
| [`CHANGELOG.md`](CHANGELOG.md) | v3.0.0: каждый исправленный дефект v2, с замером |
| [`docs/BAT-PORT.md`](docs/BAT-PORT.md) | (устаревшее) как устроен порт cmd.exe и почему пакетного порта v3 нет |
| [`docs/RAGRAF-REPORT.md`](docs/RAGRAF-REPORT.md) | (устаревшее) отчёт аудита эпохи v2 |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) · [`SECURITY.md`](SECURITY.md) | базовые правила · сообщение об уязвимостях |

## Разработка и тестирование

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

Матрица CI: shellcheck → наборы bash (Ubuntu, macOS) → наборы Node
({18,20,22} × {Ubuntu, macOS, Windows}) → наборы PowerShell (Ubuntu, macOS,
Windows) → оба дифференциала + гейт синхронизации справки → npm pack → страж
версий.
См. [`docs/TESTING.md`](docs/TESTING.md).

## Требования

- **npm CLI**: Node ≥ 18. Больше ничего — любая ОС.
- **Порт PowerShell**: PowerShell 7.6+ (Core). Для очистки больше ничего не
  нужно; `git` — для `--git`, `curl` — для `--update`/`--check-update`
  (резервный путь — `Invoke-WebRequest`), `stat`/`fsutil` — для определения
  жёстких ссылок, `chown` — для передачи владельца под root.
- **Эталон на shell**: bash ≥ 3.2 (системный bash в macOS подходит), штатный
  userland (`find sed awk od grep stat tail wc tr mv cp touch chmod mktemp`);
  необязательно: `iconv` (проверка UTF-8), `curl`/`wget` (`--update`), `git`
  (`--git`).
- **Устаревшие порты**: PowerShell 7.6+ / `cmd.exe` на Windows 10–11.

## Лицензия

[PolyForm Noncommercial 1.0.0](LICENSE) © Mikhail Deynekin — [deynekin.com](https://deynekin.com)
