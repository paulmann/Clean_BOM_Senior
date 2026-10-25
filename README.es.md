# Clean BOM Senior 🧹✨

[![Versión](https://img.shields.io/badge/version-3.0.0-blue.svg)](CHANGELOG.md)
[![versión de npm](https://img.shields.io/npm/v/clean-bom-senior.svg?color=red)](https://www.npmjs.com/package/clean-bom-senior)
[![descargas de npm](https://img.shields.io/npm/dm/clean-bom-senior.svg?color=brightgreen)](https://www.npmjs.com/package/clean-bom-senior)
[![CI](https://github.com/paulmann/Clean_BOM_Senior/actions/workflows/ci.yml/badge.svg)](https://github.com/paulmann/Clean_BOM_Senior/actions/workflows/ci.yml)
[![shellcheck](https://img.shields.io/badge/shellcheck-clean-brightgreen.svg)](https://www.shellcheck.net/)
[![Plataforma](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey.svg)]()

<!-- md-i18n:switcher -->
**En otros idiomas:** [English](README.md) · [Deutsch](README.de.md) · [中文](README.zh.md) · [हिन्दी](README.hi.md) · Español · [Русский](README.ru.md)

> **Elimina el BOM UTF-8 invisible y los CRLF de Windows de los archivos fuente — y sabe
> cuándo no debe hacerlo.** Atómico, exacto al byte, apto para CI: un archivo se reescribe
> solo cuando la limpieza es realmente necesaria y realmente segura, y nunca cuando su BOM
> cumple una función.

Un BOM UTF-8 (`EF BB BF`) al principio de un archivo PHP rompe `header()`, las sesiones y
las API JSON; los finales de línea CRLF de un editor de Windows ensucian los diffs y los
scripts de shell. Pero la solución ingenua — «quitar todos los BOM» — **corrompe archivos**:
en UTF-16/UTF-32 el BOM *es* el formato, y en un `.txt`/`.csv` no ASCII es lo único que hace
que Excel y el Bloc de notas de Windows lean el archivo como UTF-8 y no como mojibake.

**Clean BOM Senior v3 responde dos preguntas por archivo, según sus bytes reales, antes de
escribir nada:**

1. *¿Hace falta limpiar?* — detección exacta al byte de todo el archivo (un archivo limpio
   nunca se reescribe: el inodo, el mtime y los enlaces duros quedan intactos).
2. *¿Es posible que el BOM sea necesario?* — la [**Política Inteligente de BOM**](docs/SMART-BOM.md):
   los archivos UTF-16/32 y binarios se rechazan sin condiciones, el UTF-8 inválido se
   protege, el texto «sensible» conserva su BOM con una explicación, y los archivos de código
   (php/js/css/html/xml…) se limpian. Cada decisión queda registrada con su motivo y está
   disponible en JSON.

---

## Inicio rápido

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

## Qué obtienes

| | |
|---|---|
| 🧠 **Política Inteligente de BOM** | Nunca quita un BOM que el archivo necesita: UTF-16/32 rechazado sin condiciones, binario con NUL rechazado, UTF-8 inválido protegido, el texto sensible para Excel/Bloc de notas (`txt csv ps1…`, no ASCII) se conserva con una explicación — `--force` para saltarse los casos leves. [Tabla de decisión completa →](docs/SMART-BOM.md) |
| 🔬 **Detección exacta al byte** | Escaneo de todo el archivo, sin ventanas de muestreo: sin falsos positivos (la v2 reescribía archivos cuyo *volcado hexadecimal* solo contenía `0d0a`), sin falsos negativos (la v2 no veía CRLF más allá del byte 1024). |
| 🛡️ **Escrituras atómicas y verificadas** | Archivo temporal en el mismo directorio → verificación del contenido → `rename(2)`. Los enlaces duros se reescriben en el sitio, los enlaces simbólicos se resuelven, se conservan permisos, propietario y marcas de tiempo. Un fallo nunca puede dejar un archivo a medio escribir. |
| 🤖 **Nativo para CI** | `--check` (salida 10), informe `--json`, `--strict`, `--quiet`, `NO_COLOR`, salida determinista, listo para enganches de git. |
| 🚫 **Alcance sensato** | `.git`, `.svn`, `.hg`, `node_modules` excluidos por defecto; `--ext/--add-ext/--exclude/--exclude-dir/--max-size/--git` para moldear el resto. |
| 🔄 **Autoactualizable** | `--check-update` (salida 11) y `--update` con verificación del contenido; espejos vía `CLEAN_BOM_UPDATE_URL`; las instalaciones npm se redirigen a npm. [Detalles →](docs/UPDATE.md) |
| 📖 **Ayuda completa** | `--help` y 12 temas: `--help bom-policy`, `--help ci`, `--help json`, … |

## Implementaciones — un solo contrato

| Implementación | Versión | Plataformas | Estado |
|---|---|---|---|
| [`clean-bom-senior.sh`](clean-bom-senior.sh) | **3.0.0** | Linux, macOS, *BSD, WSL, Git Bash (bash ≥ 3.2, userland GNU **y** BSD) | referencia |
| [`bin/bom.js`](bin/bom.js) — npm `bom` / `clean-bom-senior` | **3.0.0** | **dondequiera que corra Node ≥ 18, incluido Windows nativo** | CLI nativa |
| [`clean-bom-senior.ps1`](clean-bom-senior.ps1) | **3.0.0** | **PowerShell 7.6+ — Windows, Linux, macOS. Sin herramientas externas** | adaptación completa |
| [`clean-bom-senior.bat`](clean-bom-senior.bat) | 2.07.0 | `cmd.exe` de Windows (sin PowerShell, sin Git Bash) | **heredada**, congelada en el contrato de la v2 |

Las tres implementaciones de la v3 quedan fijadas byte a byte por dos pruebas
diferenciales — `node tests/node/run-tests.mjs differential` (sh ↔ node) y
`python3 tests/ps/differential.py` (sh ↔ ps1, 77 escenarios). En Windows, use la CLI de npm
o la adaptación a PowerShell; la adaptación batch sigue existiendo para equipos que no
tienen ninguna de las dos, y es una herramienta **v2.07** — véase
[`docs/BAT-PORT.md`](docs/BAT-PORT.md) §8 para saber por qué no se llevó a la v3.
Contrato: [`docs/CLI-CONTRACT.md`](docs/CLI-CONTRACT.md).

---

## Instalación

### npm (recomendado — todas las plataformas, incl. Windows)

```bash
npm install -g clean-bom-senior
bom --version            # → bom version 3.0.0 (Node.js implementation)
clean-bom-senior --help  # same tool, longer alias
```

### Shell POSIX — desde el código fuente

```bash
git clone https://github.com/paulmann/Clean_BOM_Senior.git
cd Clean_BOM_Senior
sudo install -m 755 clean-bom-senior.sh /usr/local/bin/clean-bom-senior
clean-bom-senior --self-test
```

### Shell POSIX — en una línea

```bash
curl -fsSL https://raw.githubusercontent.com/paulmann/Clean_BOM_Senior/main/clean-bom-senior.sh \
  -o clean-bom-senior.sh && chmod +x clean-bom-senior.sh
```

### PowerShell 7.6+ — desde el código fuente (Windows, Linux, macOS)

Para limpiar no hace falta ninguna herramienta externa; todo es E/S de bytes de .NET.

```powershell
git clone https://github.com/paulmann/Clean_BOM_Senior.git
cd Clean_BOM_Senior
./clean-bom-senior.ps1 --self-test          # 10 fixtures, verifies this host
./clean-bom-senior.ps1 --help bom-policy    # the Smart BOM Policy in detail

# optional: put it on PATH
Copy-Item clean-bom-senior.ps1 "$HOME/.local/bin/clean-bom-senior.ps1"
```

> El archivo es **ASCII puro a propósito**, para que `./clean-bom-senior.ps1` funcione
> directamente en Unix — un BOM UTF-8 delante del shebang haría que el núcleo recurriera a
> `/bin/sh`. La ayuda incorporada sigue emitiendo las rayas y las flechas del original: se
> guardan como marcadores y se restauran al imprimir.
> Véase [`docs/PS-PORT.md`](docs/PS-PORT.md) §5.

### Autoactualización (las tres implementaciones de la v3)

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

### Desinstalación

```bash
npm uninstall -g clean-bom-senior    # npm install
sudo rm /usr/local/bin/clean-bom-senior   # manual install
```

---

## Uso

```bash
clean-bom-senior.sh [OPTIONS] [PATH...]
```

`PATH` es un archivo **o un directorio** (se recorre de forma recursiva); sin `PATH` se
recorre el directorio actual. Las opciones pueden ir intercaladas; `--` termina el análisis
de opciones (por eso los nombres de archivo pueden empezar por `-`).

### Los comandos del día a día

```bash
bom                          # clean the tree with smart safe defaults
bom --dry-run                # what would change, and why (no writes)
bom --check                  # CI gate: exit 10 if anything is dirty
bom --check --json > r.json  # machine-readable gate report
bom src index.php            # a directory + a file
bom --git                    # only git-tracked files
bom -v                       # per-file log with every decision
```

### La Política Inteligente de BOM en una imagen

```
                      ┌─ UTF-16/32 BOM ────────────► REFUSE (never touch)
file bytes ──classify─┼─ NUL bytes ────────────────► REFUSE (never touch)
                      ├─ invalid UTF-8 ────────────► PROTECT (--force: byte-clean)
                      ├─ UTF-8 BOM + sensitive ext ┐
                      │   + non-ASCII content ─────► KEEP BOM, fix CRLF, explain
                      ├─ UTF-8 BOM + code/ASCII ───► STRIP BOM (+ fix CRLF)
                      └─ no BOM, no CRLF ──────────► CLEAN: not rewritten at all
```

Detalles, razones y referencias: [`docs/SMART-BOM.md`](docs/SMART-BOM.md) ·
`bom --help bom-policy`.

### Referencia de opciones (abreviada — completa: `--help options`)

| Grupo | Opciones |
|---|---|
| Operación | `-n/--dry-run` `-c/--check` `-f/--fix` `-v/--verbose` `-q/--quiet` `--silent` `-j/--json` `--color auto\|always\|never` `--log-file FILE` |
| Selección | `--ext LIST` `--add-ext LIST` `--exclude GLOB` `--exclude-dir NAME` `--no-default-excludes` `--max-size 10M` `--git` |
| Política de BOM | `--bom-policy auto\|strip\|keep` `--sensitive-ext LIST` `--force` |
| Transformación | `--no-bom-clear` `--no-rn-normalize`/`--no-crlf-normalize` `--update-mtime` `--backup` `--backup-dir DIR` |
| Información | `-h/--help [TOPIC]` `-V/--version` `--self-test` `--completion` `--strict` |
| Actualización | `--check-update` `--update` |

### Códigos de salida

| Código | Significado |
|---|---|
| 0 | éxito (árbol limpio, o todo limpio) |
| 1 | errores por archivo, o `--strict` vio archivos conservados/protegidos |
| 2 | error de uso |
| 3 | problema de entorno (dependencias, temporales, red de actualización, `--update` gestionado por npm) |
| 4 | error interno crítico |
| **10** | `--check`: hay archivos que necesitan limpieza |
| **11** | `--check-update`: hay actualización disponible |

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

### Enganche de pre-commit

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

Más recetas: `bom --help ci`.

---

## Por qué los BOM hacen daño (la historia de PHP)

```php
\xEF\xBB\xBF<?php           ← invisible BOM
header('Content-Type: application/json');
```

- `Warning: Cannot modify header information — headers already sent`: el BOM *es* salida,
  emitida antes de que se ejecute `header()`.
- API JSON/XML rotas: los consumidores tropiezan con `\uFEFF{...}`.
- Las compilaciones concatenadas y los archivos incluidos con `include` filtran BOM a mitad
  del flujo.
- Los árboles con CRLF y LF mezclados producen diffs de archivo completo y rompen los
  shebangs `#!/bin/sh` (`/bin/sh^M: bad interpreter`).

Y por qué «quitar todo» es *también* incorrecto:

- **UTF-16/UTF-32**: el BOM es la firma del orden de bytes — quitarlo corrompe el archivo
  (el `.txt` «Unicode» del Bloc de notas es exactamente esto).
- **Excel / Bloc de notas heredado / API ANSI de Win32**: un `.csv`/`.txt` UTF-8 sin BOM con
  contenido no ASCII se muestra como mojibake (`café` → `cafÃ©`).
- **Windows PowerShell 5.1**: interpreta un `.ps1` no ASCII sin BOM como ANSI — el script
  cambia de significado o falla.

La v3 conserva el BOM exactamente donde cumple una función y lo quita exactamente donde es
suciedad — y te dice qué decisión tomó, archivo por archivo.

---

## Garantías de seguridad

- **Nunca se reescribe si no hace falta**: los archivos limpios conservan su inodo y su mtime
  (lo afirman las pruebas).
- **Atómico y verificado**: archivo temporal en el mismo directorio → verificación (BOM
  fuera / CRLF fuera / nada añadido) → `rename(2)`; copias de reversión para las
  reescrituras en el sitio; sin restos (lo afirman las pruebas).
- **Rechazos duros que ninguna opción puede saltarse**: UTF-16/32, binario con NUL
  (`--force` solo desbloquea las protecciones *leves*).
- **Metadatos**: los permisos siempre, el propietario como root, las marcas de tiempo de los
  archivos modificados por defecto (`--update-mtime` lo desactiva).
- **Enlaces duros y simbólicos**: los enlaces siguen siendo enlaces (reescritura en el sitio
  + aviso); los argumentos que son enlaces simbólicos se resuelven; el recorrido nunca sigue
  enlaces simbólicos.
- Lista completa: `bom --help safety` · [`docs/SMART-BOM.md`](docs/SMART-BOM.md) §4.

## Documentación

| Documento | Contenido |
|---|---|
| [`docs/SMART-BOM.md`](docs/SMART-BOM.md) | la política: tabla de decisión, razones, referencias de codificación |
| [`docs/CLI-CONTRACT.md`](docs/CLI-CONTRACT.md) | contrato normativo de la v3: opciones, códigos de salida, flujos, esquema JSON, semántica de bytes |
| [`docs/UPDATE.md`](docs/UPDATE.md) | diseño de la autoactualización, verificación, espejos, lista de comprobación de publicación |
| [`docs/TESTING.md`](docs/TESTING.md) | arquitectura de pruebas, mapa de cobertura, los dos diferenciales, trampas al invocar PowerShell |
| [`docs/PS-PORT.md`](docs/PS-PORT.md) | la adaptación a PowerShell: estructura, divergencias, trampas encontradas, qué descubrió en el original |
| [`docs/LLM-AGENT-USAGE.md`](docs/LLM-AGENT-USAGE.md) | conectar la herramienta a un agente LLM: puntero a la skill y a las reglas, puntos de entrada por plataforma, instalación si falta |
| [`skills/clean-bom-crlf/SKILL.md`](skills/clean-bom-crlf/SKILL.md) | la skill portable en sí, para cualquier framework de agentes que cargue skills |
| [`docs/PROMPT-OTHER-HARNESS.md`](docs/PROMPT-OTHER-HARNESS.md) | prompt para copiar y pegar que hace que un agente externo adopte la regla (RU) |
| [`CHANGELOG.md`](CHANGELOG.md) | v3.0.0: cada defecto de la v2 corregido, medido |
| [`docs/BAT-PORT.md`](docs/BAT-PORT.md) | (heredada) cómo funciona la adaptación a cmd.exe y por qué no hay adaptación batch en la v3 |
| [`docs/RAGRAF-REPORT.md`](docs/RAGRAF-REPORT.md) | (heredada) informe de auditoría de la época de la v2 |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) · [`SECURITY.md`](SECURITY.md) | reglas básicas · notificación de vulnerabilidades |

## Desarrollo y pruebas

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

Matriz de CI: shellcheck → suites bash (Ubuntu, macOS) → suites Node
({18,20,22} × {Ubuntu, macOS, Windows}) → suites PowerShell (Ubuntu, macOS, Windows) → las
dos pruebas diferenciales + control de sincronía de la ayuda → npm pack → control de versión.
Véase [`docs/TESTING.md`](docs/TESTING.md).

## Requisitos

- **CLI de npm**: Node ≥ 18. Nada más — cualquier sistema operativo.
- **Adaptación a PowerShell**: PowerShell 7.6+ (Core). Para limpiar no hace falta nada más;
  `git` para `--git`, `curl` para `--update`/`--check-update` (`Invoke-WebRequest` como
  alternativa), `stat`/`fsutil` para detectar enlaces duros, `chown` para transferir la
  propiedad como root.
- **Referencia en shell**: bash ≥ 3.2 (sirve el bash del sistema en macOS), userland estándar
  (`find sed awk od grep stat tail wc tr mv cp touch chmod mktemp`); opcional: `iconv`
  (validación UTF-8), `curl`/`wget` (`--update`), `git` (`--git`).
- **Adaptaciones heredadas**: PowerShell 7.6+ / `cmd.exe` de Windows 10–11.

## Licencia

[PolyForm Noncommercial 1.0.0](LICENSE) © Mikhail Deynekin — [deynekin.com](https://deynekin.com)
