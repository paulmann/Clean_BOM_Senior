# Clean BOM Senior 🧹✨

[![संस्करण](https://img.shields.io/badge/version-3.0.0-blue.svg)](CHANGELOG.md)
[![npm संस्करण](https://img.shields.io/npm/v/clean-bom-senior.svg?color=red)](https://www.npmjs.com/package/clean-bom-senior)
[![npm डाउनलोड](https://img.shields.io/npm/dm/clean-bom-senior.svg?color=brightgreen)](https://www.npmjs.com/package/clean-bom-senior)
[![CI](https://github.com/paulmann/Clean_BOM_Senior/actions/workflows/ci.yml/badge.svg)](https://github.com/paulmann/Clean_BOM_Senior/actions/workflows/ci.yml)
[![shellcheck](https://img.shields.io/badge/shellcheck-clean-brightgreen.svg)](https://www.shellcheck.net/)
[![प्लेटफ़ॉर्म](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey.svg)]()

<!-- md-i18n:switcher -->
**अन्य भाषाओं में:** [English](README.md) · [Deutsch](README.de.md) · [中文](README.zh.md) · हिन्दी · [Español](README.es.md) · [Русский](README.ru.md)

> **स्रोत फ़ाइलों से अदृश्य UTF-8 BOM और Windows CRLF हटाता है — और जानता है
> कि कब उसे ऐसा नहीं करना चाहिए।** Atomic, byte-exact, CI के अनुकूल: फ़ाइल
> तभी दोबारा लिखी जाती है जब सफ़ाई सचमुच ज़रूरी और सचमुच सुरक्षित हो, और कभी
> नहीं जब उसका BOM भार उठा रहा हो।

PHP फ़ाइल के शुरू में पड़ा UTF-8 BOM (`EF BB BF`) `header()`, सेशन और JSON API
तोड़ देता है; Windows एडिटर से आई CRLF लाइन एंडिंग diffs और शेल स्क्रिप्ट को
गंदा कर देती हैं। लेकिन भोला-भाला हल — "हर BOM हटा दो" — **फ़ाइलें ख़राब कर
देता है**: UTF-16/UTF-32 में BOM *ही* फ़ॉर्मैट है, और non-ASCII `.txt`/`.csv` में
यही अकेली चीज़ है जिसकी वजह से Excel और Windows Notepad फ़ाइल को mojibake की
जगह UTF-8 के रूप में पढ़ते हैं।

**Clean BOM Senior v3 कुछ भी लिखने से पहले, फ़ाइल के असली बाइट्स देखकर, हर
फ़ाइल पर दो सवालों के जवाब देता है:**

1. *सफ़ाई की ज़रूरत है ही?* — पूरी फ़ाइल की byte-exact जाँच (साफ़ फ़ाइल कभी
   दोबारा नहीं लिखी जाती: inode, mtime और hard links जस के तस रहते हैं)।
2. *कहीं BOM ज़रूरी तो नहीं?* — [**Smart BOM Policy**](docs/SMART-BOM.md):
   UTF-16/32 और बाइनरी फ़ाइलें बिना शर्त अस्वीकार, अमान्य UTF-8 सुरक्षित रहता
   है, "संवेदनशील" टेक्स्ट अपना BOM कारण के साथ बनाए रखता है, और कोड फ़ाइलें
   (php/js/css/html/xml…) साफ़ की जाती हैं। हर निर्णय कारण के साथ लॉग होता है
   और JSON के रूप में उपलब्ध रहता है।

---

## शुरुआत

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

## आपको क्या मिलता है

| | |
|---|---|
| 🧠 **Smart BOM Policy** | जिस BOM की फ़ाइल को ज़रूरत है उसे कभी नहीं हटाता: UTF-16/32 बिना शर्त अस्वीकृत, NUL-बाइनरी अस्वीकृत, अमान्य UTF-8 सुरक्षित, Excel/Notepad के लिए संवेदनशील टेक्स्ट (`txt csv ps1…`, non-ASCII) कारण के साथ बनाए रखा जाता है — नरम मामलों को बदलने के लिए `--force`. [पूरी निर्णय-तालिका →](docs/SMART-BOM.md) |
| 🔬 **Byte-exact पहचान** | पूरी फ़ाइल का स्कैन, कोई सैंपलिंग विंडो नहीं: न झूठे सकारात्मक (v2 उन फ़ाइलों को दोबारा लिख देता था जिनके *hex dump* में महज़ `0d0a` था), न झूठे नकारात्मक (v2 बाइट 1024 के बाद का CRLF चूक जाता था)। |
| 🛡️ **Atomic और सत्यापित लेखन** | उसी डायरेक्टरी में temp फ़ाइल → सामग्री का सत्यापन → `rename(2)`. Hard links जगह पर ही दोबारा लिखे जाते हैं, symlinks resolve होते हैं, permissions/ownership/टाइमस्टैम्प सुरक्षित रहते हैं। क्रैश कभी आधी लिखी फ़ाइल नहीं छोड़ सकता। |
| 🤖 **CI-native** | `--check` (exit 10), `--json` रिपोर्ट, `--strict`, `--quiet`, `NO_COLOR`, नियतात्मक आउटपुट, git-hook के लिए तैयार। |
| 🚫 **समझदार दायरा** | `.git`, `.svn`, `.hg`, `node_modules` डिफ़ॉल्ट रूप से बाहर; बाकी को आकार देने के लिए `--ext/--add-ext/--exclude/--exclude-dir/--max-size/--git`. |
| 🔄 **स्वयं-अपडेट** | सामग्री-सत्यापन के साथ `--check-update` (exit 11) और `--update`; `CLEAN_BOM_UPDATE_URL` से मिरर; npm इंस्टॉल npm की ओर भेजे जाते हैं। [विवरण →](docs/UPDATE.md) |
| 📖 **विस्तृत सहायता** | `--help` और 12 विषय: `--help bom-policy`, `--help ci`, `--help json`, … |

## कार्यान्वयन — एक ही करार

| कार्यान्वयन | संस्करण | प्लेटफ़ॉर्म | स्थिति |
|---|---|---|---|
| [`clean-bom-senior.sh`](clean-bom-senior.sh) | **3.0.0** | Linux, macOS, *BSD, WSL, Git Bash (bash ≥ 3.2, GNU **और** BSD userland) | संदर्भ |
| [`bin/bom.js`](bin/bom.js) — npm `bom` / `clean-bom-senior` | **3.0.0** | **हर जगह जहाँ Node ≥ 18 चलता है, native Windows सहित** | native CLI |
| [`clean-bom-senior.ps1`](clean-bom-senior.ps1) | **3.0.0** | **PowerShell 7.6+ — Windows, Linux, macOS. किसी बाहरी टूल की ज़रूरत नहीं** | पूर्ण पोर्ट |
| [`clean-bom-senior.bat`](clean-bom-senior.bat) | 2.07.0 | Windows `cmd.exe` (न PowerShell, न Git Bash) | **legacy**, v2 करार पर स्थिर |

तीनों v3 कार्यान्वयन दो differential टेस्ट से बाइट-दर-बाइट बँधे हैं —
`node tests/node/run-tests.mjs differential` (sh ↔ node) और
`python3 tests/ps/differential.py` (sh ↔ ps1, 77 परिदृश्य)। Windows पर npm CLI या
PowerShell पोर्ट इस्तेमाल करें; batch पोर्ट उन होस्ट के लिए रहता है जिनके पास ये
दोनों नहीं हैं, और वह **v2.07** टूल है — इसे v3 तक क्यों नहीं ले जाया गया, देखें
[`docs/BAT-PORT.md`](docs/BAT-PORT.md) §8.
करार: [`docs/CLI-CONTRACT.md`](docs/CLI-CONTRACT.md).

---

## इंस्टॉलेशन

### npm (अनुशंसित — सभी प्लेटफ़ॉर्म, Windows सहित)

```bash
npm install -g clean-bom-senior
bom --version            # → bom version 3.0.0 (Node.js implementation)
clean-bom-senior --help  # same tool, longer alias
```

### POSIX shell — स्रोत से

```bash
git clone https://github.com/paulmann/Clean_BOM_Senior.git
cd Clean_BOM_Senior
sudo install -m 755 clean-bom-senior.sh /usr/local/bin/clean-bom-senior
clean-bom-senior --self-test
```

### POSIX shell — एक पंक्ति में

```bash
curl -fsSL https://raw.githubusercontent.com/paulmann/Clean_BOM_Senior/main/clean-bom-senior.sh \
  -o clean-bom-senior.sh && chmod +x clean-bom-senior.sh
```

### PowerShell 7.6+ — स्रोत से (Windows, Linux, macOS)

सफ़ाई के लिए किसी बाहरी टूल की ज़रूरत नहीं; सब कुछ .NET byte I/O है।

```powershell
git clone https://github.com/paulmann/Clean_BOM_Senior.git
cd Clean_BOM_Senior
./clean-bom-senior.ps1 --self-test          # 10 fixtures, verifies this host
./clean-bom-senior.ps1 --help bom-policy    # the Smart BOM Policy in detail

# optional: put it on PATH
Copy-Item clean-bom-senior.ps1 "$HOME/.local/bin/clean-bom-senior.ps1"
```

> फ़ाइल जान-बूझकर **शुद्ध ASCII** है, इसलिए `./clean-bom-senior.ps1` Unix पर
> सीधे चलता है — shebang के आगे UTF-8 BOM होने पर kernel `/bin/sh` पर लौट आता
> है। अंतर्निहित सहायता फिर भी संदर्भ के em dashes और arrows छापती है: वे
> placeholder के रूप में रखे जाते हैं और आउटपुट पर बहाल हो जाते हैं।
> देखें [`docs/PS-PORT.md`](docs/PS-PORT.md) §5।

### स्वयं-अपडेट (तीनों v3 कार्यान्वयन)

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

### अनइंस्टॉल

```bash
npm uninstall -g clean-bom-senior    # npm install
sudo rm /usr/local/bin/clean-bom-senior   # manual install
```

---

## उपयोग

```bash
clean-bom-senior.sh [OPTIONS] [PATH...]
```

`PATH` कोई फ़ाइल **या डायरेक्टरी** है (पुनरावर्ती स्कैन); `PATH` न देने पर
मौजूदा डायरेक्टरी स्कैन होती है। विकल्प बीच में कहीं भी आ सकते हैं; `--`
विकल्प-पार्सिंग समाप्त करता है (इसलिए फ़ाइल नाम `-` से शुरू हो सकते हैं)।

### रोज़मर्रा के आदेश

```bash
bom                          # clean the tree with smart safe defaults
bom --dry-run                # what would change, and why (no writes)
bom --check                  # CI gate: exit 10 if anything is dirty
bom --check --json > r.json  # machine-readable gate report
bom src index.php            # a directory + a file
bom --git                    # only git-tracked files
bom -v                       # per-file log with every decision
```

### एक चित्र में Smart BOM Policy

```
                      ┌─ UTF-16/32 BOM ────────────► REFUSE (never touch)
file bytes ──classify─┼─ NUL bytes ────────────────► REFUSE (never touch)
                      ├─ invalid UTF-8 ────────────► PROTECT (--force: byte-clean)
                      ├─ UTF-8 BOM + sensitive ext ┐
                      │   + non-ASCII content ─────► KEEP BOM, fix CRLF, explain
                      ├─ UTF-8 BOM + code/ASCII ───► STRIP BOM (+ fix CRLF)
                      └─ no BOM, no CRLF ──────────► CLEAN: not rewritten at all
```

विवरण, तर्क और संदर्भ: [`docs/SMART-BOM.md`](docs/SMART-BOM.md) ·
`bom --help bom-policy`.

### फ़्लैग संदर्भ (संक्षिप्त — पूरा: `--help options`)

| समूह | फ़्लैग |
|---|---|
| कार्य | `-n/--dry-run` `-c/--check` `-f/--fix` `-v/--verbose` `-q/--quiet` `--silent` `-j/--json` `--color auto\|always\|never` `--log-file FILE` |
| चयन | `--ext LIST` `--add-ext LIST` `--exclude GLOB` `--exclude-dir NAME` `--no-default-excludes` `--max-size 10M` `--git` |
| BOM नीति | `--bom-policy auto\|strip\|keep` `--sensitive-ext LIST` `--force` |
| रूपांतरण | `--no-bom-clear` `--no-rn-normalize`/`--no-crlf-normalize` `--update-mtime` `--backup` `--backup-dir DIR` |
| जानकारी | `-h/--help [TOPIC]` `-V/--version` `--self-test` `--completion` `--strict` |
| अपडेट | `--check-update` `--update` |

### Exit कोड

| कोड | अर्थ |
|---|---|
| 0 | सफलता (साफ़ ट्री, या सब कुछ साफ़ हो गया) |
| 1 | प्रति-फ़ाइल त्रुटियाँ, या `--strict` ने रखी/सुरक्षित फ़ाइलें देखीं |
| 2 | उपयोग में त्रुटि |
| 3 | वातावरण की समस्या (deps, temp, अपडेट नेटवर्क, npm-प्रबंधित `--update`) |
| 4 | गंभीर आंतरिक त्रुटि |
| **10** | `--check`: फ़ाइलों को सफ़ाई चाहिए |
| **11** | `--check-update`: अपडेट उपलब्ध है |

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

### Pre-commit hook

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

और नुस्ख़े: `bom --help ci`.

---

## BOM क्यों नुकसान करते हैं (PHP की कहानी)

```php
\xEF\xBB\xBF<?php           ← invisible BOM
header('Content-Type: application/json');
```

- `Warning: Cannot modify header information — headers already sent`: BOM
  *आउटपुट ही है*, `header()` चलने से पहले ही भेजा जा चुका।
- टूटे JSON/XML API: उपभोक्ता `\uFEFF{...}` पर अटकते हैं।
- जोड़कर बनाए गए builds और `include` की गई फ़ाइलें स्ट्रीम के बीच में BOM
  लीक करती हैं।
- मिश्रित CRLF/LF ट्री पूरी फ़ाइल का diff बनाते हैं और `#!/bin/sh`
  shebang तोड़ते हैं (`/bin/sh^M: bad interpreter`)।

और "सब कुछ हटा दो" भी *ग़लत* क्यों है:

- **UTF-16/UTF-32**: BOM ही endianness का हस्ताक्षर है — उसे हटाने से फ़ाइल
  ख़राब होती है (Notepad का "Unicode" `.txt` ठीक यही है)।
- **Excel / पुराना Notepad / Win32 ANSI API**: non-ASCII सामग्री वाली
  BOM-रहित UTF-8 `.csv`/`.txt` mojibake दिखती है (`café` → `cafÃ©`)।
- **Windows PowerShell 5.1**: BOM-रहित non-ASCII `.ps1` को ANSI पढ़ता है —
  स्क्रिप्ट का अर्थ बदल जाता है या वह विफल होती है।

v3 BOM को ठीक वहाँ रखता है जहाँ वह भार उठाता है और ठीक वहाँ हटाता है जहाँ वह
गंदगी है — और बताता है कि हर फ़ाइल पर उसने कौन-सा निर्णय लिया।

---

## सुरक्षा की गारंटी

- **ज़रूरत के बिना कभी दोबारा नहीं लिखा जाता**: साफ़ फ़ाइलें अपना inode और
  mtime बनाए रखती हैं (टेस्ट इसे जाँचते हैं)।
- **Atomic + सत्यापित**: उसी डायरेक्टरी में temp फ़ाइल → सत्यापन
  (BOM गया / CRLF गया / कुछ जोड़ा नहीं गया) → `rename(2)`; जगह पर दोबारा
  लिखने के लिए rollback प्रतियाँ; कुछ शेष नहीं (जाँचा गया)।
- **कठोर अस्वीकृति जिन्हें कोई फ़्लैग नहीं बदल सकता**: UTF-16/32, NUL-बाइनरी
  (`--force` केवल *नरम* सुरक्षाएँ खोलता है)।
- **मेटाडेटा**: permissions हमेशा, ownership root के रूप में, बदली फ़ाइलों के
  टाइमस्टैम्प डिफ़ॉल्ट रूप से (`--update-mtime` इसे बंद करता है)।
- **Hard links और symlinks**: लिंक लिंक ही रहते हैं (जगह पर पुनर्लेखन +
  चेतावनी); symlink आर्ग्युमेंट resolve होते हैं; वॉक कभी symlink का पीछा
  नहीं करता।
- पूरी सूची: `bom --help safety` · [`docs/SMART-BOM.md`](docs/SMART-BOM.md) §4।

## दस्तावेज़ीकरण

| दस्तावेज़ | विषय-वस्तु |
|---|---|
| [`docs/SMART-BOM.md`](docs/SMART-BOM.md) | नीति: निर्णय-तालिका, तर्क, encoding संदर्भ |
| [`docs/CLI-CONTRACT.md`](docs/CLI-CONTRACT.md) | मानक v3 करार: फ़्लैग, exit कोड, streams, JSON schema, byte अर्थ |
| [`docs/UPDATE.md`](docs/UPDATE.md) | ऑटो-अपडेट की रूपरेखा, सत्यापन, मिरर, रिलीज़ चेकलिस्ट |
| [`docs/TESTING.md`](docs/TESTING.md) | टेस्ट आर्किटेक्चर, coverage का नक्शा, दोनों differential, PowerShell आह्वान के जाल |
| [`docs/PS-PORT.md`](docs/PS-PORT.md) | PowerShell पोर्ट: संरचना, अंतर, मिले जाल, संदर्भ में उसने क्या पाया |
| [`docs/LLM-AGENT-USAGE.md`](docs/LLM-AGENT-USAGE.md) | टूल को LLM एजेंट में जोड़ना: skill + rules संकेत, प्रति-प्लेटफ़ॉर्म प्रवेश बिंदु, न होने पर इंस्टॉल |
| [`skills/clean-bom-crlf/SKILL.md`](skills/clean-bom-crlf/SKILL.md) | portable skill स्वयं, किसी भी एजेंट फ़्रेमवर्क के लिए जो skills लोड करता है |
| [`docs/PROMPT-OTHER-HARNESS.md`](docs/PROMPT-OTHER-HARNESS.md) | copy-paste प्रॉम्प्ट जिससे बाहरी एजेंट यह नियम अपनाता है (RU) |
| [`CHANGELOG.md`](CHANGELOG.md) | v3.0.0: हर ठीक किया गया v2 दोष, मापा गया |
| [`docs/BAT-PORT.md`](docs/BAT-PORT.md) | (legacy) cmd.exe पोर्ट कैसे काम करता है, और v3 batch पोर्ट क्यों नहीं है |
| [`docs/RAGRAF-REPORT.md`](docs/RAGRAF-REPORT.md) | (legacy) v2-युग की audit रिपोर्ट |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) · [`SECURITY.md`](SECURITY.md) | बुनियादी नियम · भेद्यता की सूचना |

## विकास और परीक्षण

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

CI matrix: shellcheck → bash सूट (Ubuntu, macOS) → Node सूट
({18,20,22} × {Ubuntu, macOS, Windows}) → PowerShell सूट (Ubuntu, macOS,
Windows) → दोनों differential + help-sync गेट → npm pack → version guard.
देखें [`docs/TESTING.md`](docs/TESTING.md).

## आवश्यकताएँ

- **npm CLI**: Node ≥ 18. और कुछ नहीं — कोई भी OS।
- **PowerShell पोर्ट**: PowerShell 7.6+ (Core). सफ़ाई के लिए और कुछ ज़रूरी नहीं;
  `--git` के लिए `git`, `--update`/`--check-update` के लिए `curl`
  (`Invoke-WebRequest` fallback है), hard-link पहचान के लिए `stat`/`fsutil`,
  root के रूप में ownership हस्तांतरण के लिए `chown`।
- **Shell संदर्भ**: bash ≥ 3.2 (macOS का सिस्टम bash चलता है), मानक
  userland (`find sed awk od grep stat tail wc tr mv cp touch chmod mktemp`);
  वैकल्पिक: `iconv` (UTF-8 सत्यापन), `curl`/`wget` (`--update`), `git`
  (`--git`)।
- **Legacy पोर्ट**: PowerShell 7.6+ / Windows 10–11 `cmd.exe`।

## लाइसेंस

[PolyForm Noncommercial 1.0.0](LICENSE) © Mikhail Deynekin — [deynekin.com](https://deynekin.com)
