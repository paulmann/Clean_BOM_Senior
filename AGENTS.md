# Проект: Clean_BOM_Senior

Инструкции для агента, работающего в этом каталоге. Актуализировано 2026-10-08
после выпуска v3.0.0 (ветка/коммиты `refactor/v3.0.0`). Исторический контекст
v2-эры — в `docs/RAGRAF-REPORT.md`, `docs/BAT-PORT.md` и git-истории.

---

## 1. Что это за проект

Инструмент очистки текстовых файлов от невидимого UTF-8 BOM и Windows CRLF
**с умной политикой**: перед любой записью доказывается, что (а) чистка вообще
нужна и (б) BOM не является для файла обязательным (Smart BOM Policy —
`docs/SMART-BOM.md`).

| Файл | Что это |
|---|---|
| `clean-bom-senior.sh` | **эталон v3.0.0**: bash ≥ 3.2 (macOS!), GNU+BSD, shellcheck-clean |
| `bin/bom.js` | **нативная Node-реализация v3.0.0** (npm `bom`/`clean-bom-senior`): Linux/macOS/**Windows** без bash; байт-в-байт паритет с эталоном подтверждён дифференциальным тестом |
| `clean-bom-senior.ps1` | **полный v3-порт** (PowerShell 7.6+, Windows/Linux/macOS): чистый .NET byte I/O, для очистки внешние инструменты НЕ нужны; паритет с эталоном подтверждён дифференциалом. Файл **чистый ASCII** (иначе BOM ломает shebang на Unix), но справка выдаёт настоящие em-dash/стрелки эталона — они хранятся плейсхолдерами и подставляются на выводе (`docs/PS-PORT.md` §5) |
| `clean-bom-senior.bat` | **legacy-порт 2.07.0** (cmd.exe, certutil), заморожен и **без автотестов** — почему, см. `docs/BAT-PORT.md` §8 |
| `tests/sh/run-tests.sh` | v3-набор для эталона: 167 assertion'ов, без фреймворков |
| `tests/node/run-tests.mjs` | v3-набор для Node (161) + **дифференциальный sh↔node** (8 фикстур) |
| `tests/ps/run-tests.ps1` | v3-набор для PowerShell-порта: 237 assertion'ов, 63 группы; вызывает инструмент in-process |
| `tests/ps/differential.py` | **дифференциальный sh↔ps1**: 77 сценариев — байты файлов, состав дерева, оба потока (нормализованные) и код выхода |
| `scripts/gen-ps-help.py` | **генератор** справки ps1 из here-doc'ов эталона; `--check` — гейт в CI. Справка — часть контракта, руками её не копируем |
| `docs/CLI-CONTRACT.md` | нормативный контракт v3: флаги, коды выхода, потоки, JSON, байтовая семантика |
| `docs/SMART-BOM.md` | политика BOM: таблица решений и обоснования |
| `docs/UPDATE.md` | автообновление: проверка, зеркала, релизный чеклист |
| `docs/TESTING.md` | архитектура тестов, карта покрытия, оба дифференциала, ловушки вызова PowerShell |
| `docs/PS-PORT.md` | PowerShell-порт: структура, 6 осознанных расхождений, ловушки, что порт нашёл в эталоне |
| `scripts/check-version-consistency.sh` | страж версий: VERSION/sh/js/**ps1**/package.json/CHANGELOG = 3.x; bat = 2.07.0 |
| `VERSION` | единственный источник правды для `--update` |
| `package.json` | npm-пакет 3.0.0, `os` больше НЕ ограничен, engines ≥ 18 |
| `.github/workflows/ci.yml` | CI: shellcheck → sh-тесты (ubuntu+macos) → node-тесты (18/20/22 × 3 ОС) → **ps-тесты (3 ОС)** → оба дифференциала + гейт синхронности справки → npm pack → version guard |

Стек: bash (эталон) + Node (кросс-платформенный CLI) + PowerShell 7.6 (порт
для хостов без Node). Документация и комментарии в репозитории — английские;
этот файл — внутренний, русский.

## 2. Роль

Инженер по CLI-инструментам безопасности данных. Инструмент правит файлы на
месте, поэтому цена ошибки — испорченный файл пользователя.

Что здесь считается провалом:
- запись туда, куда политика писать запретила (UTF-16/32, NUL-бинарь —
  абсолютный запрет даже под `--force`; invalid-UTF-8 и sensitive-BOM —
  запрет по умолчанию, снимаемый только явным `--force`);
- перезапись ЧИСТОГО файла (инвариант: inode и mtime не меняются);
- расхождение байтов или кодов выхода между sh и node реализациями;
- документация/`--help`, обещающие то, чего код не делает;
- regression любого дефекта, перечисленного в CHANGELOG.md §Fixed (на каждый
  есть именованный тест).

## 3. Команды

```bash
# тесты (локально и в CI)
bash tests/sh/run-tests.sh [-v] [-k] [FILTER]
node tests/node/run-tests.mjs [FILTER]
bash clean-bom-senior.sh --self-test      # встроенный acceptance, 10 фикстур
node bin/bom.js --self-test

# качество
shellcheck clean-bom-senior.sh tests/sh/run-tests.sh scripts/check-version-consistency.sh
node --check bin/bom.js
bash scripts/check-version-consistency.sh

# справка (контракт help-системы)
bash clean-bom-senior.sh --help            # полный текст
bash clean-bom-senior.sh --help bom-policy # тематический (12 тем)
```

## 4. Незыблемые инварианты v3

1. **Чистый файл не перезаписывается вообще** — проверяется стабильность
   inode и mtime, а не «байты совпали».
2. **Жёсткие отказы**: UTF-16/32 BOM и NUL-байты → файл не трогается ни при
   каких флагах. Мягкие защиты (invalid-utf8, sensitive keep) снимаются
   `--force`.
3. **Детекция байт-точная по всему файлу**: CRLF = байт `0D` непосредственно
   перед `0A`; одиночный CR в середине строки сохраняется; CR в самом конце
   файла БЕЗ LF не делает файл грязным, но удаляется, если файл всё равно
   переписывается из-за настоящих CRLF (семантика sed, наследие v2).
4. **Запись атомарна и верифицирована**: temp в ТОМ ЖЕ каталоге → проверка
   результата (BOM исчез / CRLF исчез / ничего не добавлено) → rename.
   Hard links (nlink>1) — in-place через inode с откатом; symlink-аргументы
   резолвятся в цель; обход каталогов symlinks НЕ следует.
5. **Коды выхода** (контракт): 0 успех · 1 файловые ошибки/`--strict` ·
   2 usage · 3 окружение/сеть/npm-update · 4 internal · 10 `--check` нашёл
   грязь · 11 `--check-update` нашёл новую версию. Приоритет: 2/3/4 > 1 > 10/11 > 0.
6. **Потоки**: stderr — человеческий лог `[YYYY-MM-DD HH:MM:SS LEVEL]`;
   stdout — только машинные каналы (`--json`, `--help`, `--version`,
   `--completion`). С `--json` stdout обязан парситься как JSON целиком.
7. **Пути в логе**: рекурсия от `.` → `./name`; аргумент-каталог → `dir/name`;
   явный аргумент-файл — дословно (verbatim).
8. **bash 3.2**: никаких ассоциативных массивов, `${var,,}`, `mapfile`,
   `&>>`. bash 4+ фичи ломают macOS.
9. **GNU и BSD**: `stat` только через шимы (`file_size/file_nlink/file_attrs`),
   `\r` в sed-паттерны — только литеральным байтом (`CR_BYTE`), BSD sed не
   понимает `\r`. `tail -c +4` — байтовая операция для снятия BOM (заодно
   лечит MSYS-дефект sed из v2).
10. **Legacy не трогаем**: `.bat` остаётся на 2.07.0; его правка «в сторону
    v3» запрещена без Windows-машины, на которой результат можно исполнить и
    сравнить с эталоном. `tests/legacy/` удалён вместе с v2.07-портом ps1
    (исчезла базовая линия сравнения); восстановить —
    `git show v3.0.0:tests/legacy/`.
11. **Справка ps1 — генерируемая**: правь `clean-bom-senior.sh`, затем
    `python3 scripts/gen-ps-help.py`. Блок между `# BEGIN GENERATED HELP` и
    `# END GENERATED HELP` руками не редактируется.
12. **Три v3-реализации меняются одновременно**: любое изменение поведения —
    это контракт (`docs/CLI-CONTRACT.md`) + sh + node + ps1 + все три набора
    тестов в одном коммите. Дифференциалы существуют, чтобы это ловить.

## 5. Как проверять правки

Минимальный прогон после любого изменения поведения:

```bash
shellcheck clean-bom-senior.sh && \
bash tests/sh/run-tests.sh && \
node tests/node/run-tests.mjs && \
pwsh -NoLogo -NoProfile -File tests/ps/run-tests.ps1 && \
python3 scripts/gen-ps-help.py --check && \
bash scripts/check-version-consistency.sh
```

Оба дифференциала обязаны оставаться зелёными:
`node tests/node/run-tests.mjs differential` (sh↔node, 8 фикстур) и
`python3 tests/ps/differential.py` (sh↔ps1, 77 сценариев — байты, состав
дерева, stderr, stdout, код выхода). Если поведение изменено намеренно —
меняй контракт (`docs/CLI-CONTRACT.md`), ВСЕ ТРИ реализации и все три набора
одновременно.

Правило самопроверки теста: внедри дефект, который тест должен ловить, и
убедись, что тест краснеет. Тест, который не падает на дефекте, ничего не
проверяет.

## 6. Ловушки (проверено на практике — свои и унаследованные)

**Этот репозиторий:**
- `.bat` обязан быть CRLF: LF-батник не исполняется cmd вовсе (exit 255).
  `.gitattributes` пинит это; при правке батника не нормализуй переводы строк.
- Python-скрипты, правящие `.bat`/`.ps1`, читай/пиши с `newline=''`:
  universal newlines молча конвертирует CRLF→LF и ломает батник.
- Фикстуры — только сырыми байтами (`printf '\xNN'` / `Buffer.from(hex)`).
- `od` БЕЗ `-v` сжимает повторяющиеся строки в `*` — в тестах больших
  однородных фикстур hex-ожидания ломаются. Всегда `od -v`.
- `grep` по hex-дампу (`0d0a`) даёт ложные срабатывания на стыках байтов —
  так был устроен v2; никогда не возвращайся к «оконной» детекции.
- `spawnSync` в node-тестах блокирует event-loop: тесты автообновления с
  локальным HTTP-сервером в родительском процессе обязаны использовать
  async spawn (иначе дедлок «This operation was aborted»).
- `set -e` + `[ cond ] && action` как ПОСЛЕДНЯЯ строка функции → функция
  возвращает 1. Заканчивай функции явным `return 0`.
- Пустые массивы под `set -u` в bash < 4.4: только `${arr[@]+"${arr[@]}"}`.
- Командная подстановка `$(cmd | head -1)` + pipefail = SIGPIPE-провал;
  используй `sed -n '1p'` (дочитывает вход) или `|| true`.

**PowerShell 7.6 — найдено при написании v3-порта. Каждое давало молча
неверный результат; все закрыты тестами:**
- `@()` — это fixed-size `System.Object[]`, а не пустой список: `.Add()`
  падает с «Collection was of a fixed size». Растущие коллекции — только
  `[System.Collections.Generic.List[string]]::new()`.
- **`-split` СОРТИРУЕТ** результаты по правилам текущей культуры:
  `--ext php,js` превращался в `js php`. Везде `[regex]::Matches($s,'[^\s]+')`.
- `[System.Array]::Sort` со скриптблоком-компаратором **молча не делает
  ничего**: делегат не резолвит функции script-scope, компаратор возвращает
  `$null`, все сравнения «равны». Сортировка — LSD radix sort (`Sort-Ordinal`).
- Компаратор обязан возвращать `-1/0/1`, а не `bool`: `$true` читается как 1,
  `$false` как 0 — сортировка получает противоречивый компаратор.
- `Path.Combine('.', 'a.php')` → `a.php`: теряется `./`, требуемый контрактом
  отображаемых путей; а `EnumerateFileSystemEntries('.')` возвращает `src`,
  не `./src`. Пути собираются явной конкатенацией `"$dir/$name"`.
- `& $script a,b` и `& $script @(a,b)` передают ОДИН строковый аргумент
  `"a b"`. Сплэттинг — только от переменной-массива: `[string[]]$a` + `& $t @a`.
- Пустой массив из функции приходит как `$null` (конвейер разворачивает его).
  Возврат байтовых массивов — `return , $array`.
- `Push-Location` НЕ меняет `[Environment]::CurrentDirectory`, а .NET резолвит
  относительные пути от него; при этом PowerShell синхронизирует CWD процесса
  со своей Location перед запуском внешней команды. Нужно ОБА, иначе
  `[System.IO.File]` и `stat` расходятся в том, что такое `./file`.
- `[Console]::Out.Write` идёт мимо потоков PowerShell: это даёт байтовый UTF-8
  на stdout независимо от `$OutputEncoding`, но ловить вывод надо через
  `[Console]::SetOut/SetError` + `StringWriter`, не `2>&1 | Out-String`.
- В double-quoted строке `` `$ `` даёт ЛИТЕРАЛЬНЫЙ `$`, который regex читает
  как «конец строки» — паттерн версии молча не матчил ничего. Исходник regex
  пиши в одинарных кавычках.
- `Write-Foo "$a" + 'b'` передаёт ТРИ позиционных аргумента и падает с
  «A positional parameter cannot be found that accepts argument '+'».
- `UTF8Encoding.GetByteCount()` **не валидирует** UTF-8 (не запускает
  fallback): `C3 28`, `ED A0 80` и одиночный `FF` проходят. Валидация —
  `GetString()` или `Decoder.Convert` по чанкам с `flush:true` в конце.
- Хеш-таблица PowerShell сравнивает ключи БЕЗ учёта регистра; для имён файлов
  на Unix нужен `Dictionary[string,int]` с `StringComparer::Ordinal`.
- `exit N` внутри скрипта, вызванного через `&`, не завершает вызывающий
  процесс — код возврата читается из `$LASTEXITCODE`. На этом построен
  in-process прогон 64 групп тестов.

**Унаследованные от v2-эпохи (исторические, в v3 исправлены — см. CHANGELOG):**
- PowerShell: `exit (Функция)` теряет текст (массив); `-eq` регистронезависим
  (`-v` == `-V`, нужен `-cin`); `continue` в `switch` продолжает switch;
  `[System.IO]` резолвит пути от cwd ПРОЦЕССА, а не от провайдера;
  `Get-ChildItem -Filter` матчит 8.3-имена; зарезервированные имена `nul`,
  `con`, `com1`… в фикстурах не использовать.
- cmd: скобки в тексте внутри `if (…)` ломают блок; `set /a` внутри блока
  считает подставленные значения; подстановка по пустой переменной не
  выполняется; `for /r *.htm` матчит `.html` через 8.3; `copy /b`/`move`
  сбрасывают mtime; `pwsh -Command` искажает аргументы (только `-File`).
- shell/MSYS: sed читает файлы в текстовом режиме и режет CR (v2 из-за этого
  не выполнял `--no-rn-normalize`); `stat -c` нет на macOS (v2 на Mac молча
  «чистил ноль файлов»).

## 7. Где что искать

| Задача | Смотреть |
|---|---|
| Политика BOM (решения) | `clean-bom-senior.sh` → `analyze_file` + `plan_file`; `bin/bom.js` → `analyzeFile` + `planFile`; `clean-bom-senior.ps1` → `Get-FileAnalysis` + `Get-FilePlan`; текст — `docs/SMART-BOM.md` |
| Байтовая детекция | `read_magic/classify_bom/has_crlf/has_nul/is_valid_utf8/has_non_ascii` (sh); `classifyBom/hasCrlf/hasNul/isValidUtf8/hasNonAscii` (js); `Get-MagicHex/Get-BomClass/Test-HasCrlf/Test-HasNul/Test-IsValidUtf8/Test-HasNonAscii` (ps1) |
| Атомарная запись | `transform_file/apply_attrs_to/write_in_place` (sh); `transformFile/writeFileInPlace` (js) |
| Обход дерева | `scan_directory/scan_git_tracked/path_excluded` (sh); `walkDirectory/scanGitTracked/pathExcluded` (js) |
| Парсинг флагов | `parse_arguments` (sh); `parseArguments` (js) |
| Справка/топики | `show_help` + `help_*` (sh); `helpText` (js); `Show-Help` + `Write-Help*` (ps1, **генерируется** из sh — `scripts/gen-ps-help.py`) |
| Отчёты | `display_statistics/json_report` (sh); `displayStatistics/jsonReport` (js) |
| Автообновление | `do_check_update/do_update/fetch_remote_version/semver_gt` (sh); `doCheckUpdate/doUpdate/fetchRemoteVersion/semverGt` (js); `docs/UPDATE.md` |
| Контракт | `docs/CLI-CONTRACT.md` |
| Тесты | `docs/TESTING.md`; наборы — `tests/sh`, `tests/node`, `tests/ps`; дифференциалы — `tests/node/run-tests.mjs differential` и `tests/ps/differential.py` |
| Версии | `VERSION` + `scripts/check-version-consistency.sh` |

## 8. Решения по открытым вопросам

1. **Три активные реализации (sh + node + ps1), `.bat` заморожен.** Node-CLI
   закрывает Windows (v2 npm-пакет там не работал вовсе: обёртка звала bash,
   `os: [linux,darwin]`); ps1-порт закрывает хосты, где Node добавлять не
   хотят (WinRM-деплой, агенты сборки без node-тулчейна, изолированные
   машины) — для очистки ему не нужен ни один внешний инструмент. Паритет
   всех трёх держится двумя дифференциалами.
2. **`.sh` больше не «нечинимый эталон».** Решение v2-эпохи «эталон не
   правится» отменено владельцем 2026-10-08: эталон ОТРЕФАКТОРЕН до v3,
   все измеренные дефекты v2 исправлены и защищены тестами (CHANGELOG §Fixed).
   v2.07-порт PowerShell заменён полным v3-портом; `tests/legacy/` удалён
   вместе с ним (исчезла базовая линия для bat-дифференциала). Как её
   восстановить перед правкой `.bat` — `docs/BAT-PORT.md` §6.
3. **mtime изменённых файлов СОХРАНЯЕТСЯ по умолчанию** (контракт v2 README
   «preserves timestamps», в sh v2 не выполнявшийся; ps1-порт выполнял).
   Отказ — `--update-mtime`. Обоснование: idempotent-прогоны в CI не
   триггерят пересборки; кому нужна свежесть — флаг.
4. **mtime чистых файлов не меняется НИКОГДА** (файл не перезаписывается).
5. **Дефолтные исключения каталогов**: `.git .svn .hg node_modules`.
   `vendor` НЕ исключён (PHP-деплои часто несут его как first-party).
6. **Автообновление без телеметрии**: сеть — только по явным
   `--check-update/--update`. npm-установки `--update` отказывает (exit 3)
   и отправляет в `npm i -g` — целостность npm-метаданных важнее удобства.

## 9. Что осталось / roadmap

- **Порт `.bat` на v3-контракт.** Черновик был написан и НЕ выпущен: его
  негде исполнить (wine `cmd.exe` не реализует delayed expansion — `!V:~0,5!`
  возвращает литерал `[~0,5]`, ANSI-escapes не отдаются, `certutil` под wine
  отсутствует вовсе), а непроверенный инструмент безопасности хуже честно
  замороженного. Что cmd.exe может и не может, измерено в `docs/BAT-PORT.md`
  §8 — там же граница: политика BOM, `--check`/`--json`, исключения и
  `--max-size` достижимы; валидация UTF-8, hard links, атомарная замена и
  `durationSeconds` — нет. Нужна Windows-машина для разработки и прогона
  дифференциала.
- `ps1`: проверить на реальном Windows (сейчас порт прогнан на Linux/pwsh
  7.6.6; Windows-специфичные ветки — `fsutil hardlink list`, NTFS ACL,
  `Invoke-WebRequest` вместо `curl` — написаны, но не исполнялись).
- `--ignore-file` (gitignore-подобные паттерны) — заявлен как roadmap,
  в контракт не входит.
- Проверка поведения на реальных macOS/BSD хостах (CI покрывает macos-latest;
  FreeBSD — вручную).
- Гонки параллельных прогонов по одному файлу не сериализованы (как и в v2):
  temp-имена уникальны по pid+random, но два одновременных rename — last
  wins. Документировать как известное ограничение при жалобах.
