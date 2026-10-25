# Clean BOM Senior 🧹✨

[![版本](https://img.shields.io/badge/version-3.0.0-blue.svg)](CHANGELOG.md)
[![npm 版本](https://img.shields.io/npm/v/clean-bom-senior.svg?color=red)](https://www.npmjs.com/package/clean-bom-senior)
[![npm 下载量](https://img.shields.io/npm/dm/clean-bom-senior.svg?color=brightgreen)](https://www.npmjs.com/package/clean-bom-senior)
[![CI](https://github.com/paulmann/Clean_BOM_Senior/actions/workflows/ci.yml/badge.svg)](https://github.com/paulmann/Clean_BOM_Senior/actions/workflows/ci.yml)
[![shellcheck](https://img.shields.io/badge/shellcheck-clean-brightgreen.svg)](https://www.shellcheck.net/)
[![平台](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey.svg)]()

<!-- md-i18n:switcher -->
**其他语言：** [English](README.md) · [Deutsch](README.de.md) · 中文 · [हिन्दी](README.hi.md) · [Español](README.es.md) · [Русский](README.ru.md)

> **从源文件中移除不可见的 UTF-8 BOM 和 Windows 换行 CRLF —— 并且知道什么时候不能这么做。**
> 原子、字节精确、对 CI 友好：只有当清理确实必要且确实安全时才重写文件，当 BOM 承担
> 格式作用时绝不触碰。

PHP 文件开头的 UTF-8 BOM（`EF BB BF`）会破坏 `header()`、会话和 JSON API；Windows
编辑器产生的 CRLF 行尾会污染 diff 和 shell 脚本。但天真的做法——“剥掉每一个
BOM”——**会损坏文件**：对 UTF-16/UTF-32 来说，BOM *就是* 格式本身，而对含非 ASCII 内容的
`.txt`/`.csv` 来说，它是让 Excel 和 Windows 记事本按 UTF-8 而不是乱码读取该文件的唯一
依据。

**Clean BOM Senior v3 在写入任何内容之前，按文件的实际字节回答两个问题：**

1. *到底需不需要清理？* —— 全文件字节级检测（干净的文件从不被重写：inode、mtime
   和硬链接都保持原样）。
2. *BOM 是否可能是必需的？* —— [**智能 BOM 策略**](docs/SMART-BOM.md)：
   UTF-16/32 与二进制文件无条件拒绝，非法 UTF-8 受保护，“敏感”文本连同说明一并保留其
   BOM，代码文件（php/js/css/html/xml……）则被清理。每个决定都连同理由记入日志，
   并可作为 JSON 获取。

---

## 快速开始

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

## 你得到什么

| | |
|---|---|
| 🧠 **智能 BOM 策略** | 绝不剥掉文件所需要的 BOM：UTF-16/32 无条件拒绝，含 NUL 的二进制文件拒绝，非法 UTF-8 受保护，Excel/记事本敏感的文本（`txt csv ps1…`，非 ASCII）连同说明一并保留 —— 软性情况可用 `--force` 覆盖。[完整判定表 →](docs/SMART-BOM.md) |
| 🔬 **字节级精确检测** | 全文件扫描，没有采样窗口：没有误报（v2 会重写那些 *十六进制转储* 里仅仅出现 `0d0a` 的文件），也没有漏报（v2 漏掉了第 1024 字节之后的 CRLF）。 |
| 🛡️ **原子且经校验的写入** | 同目录临时文件 → 内容校验 → `rename(2)`。硬链接就地重写，符号链接被解析，权限/属主/时间戳保留。崩溃绝不会留下写了一半的文件。 |
| 🤖 **原生支持 CI** | `--check`（退出码 10）、`--json` 报告、`--strict`、`--quiet`、`NO_COLOR`、确定性输出、可直接用于 git 钩子。 |
| 🚫 **合理的范围** | 默认排除 `.git`、`.svn`、`.hg`、`node_modules`；其余范围用 `--ext/--add-ext/--exclude/--exclude-dir/--max-size/--git` 来塑造。 |
| 🔄 **自我更新** | `--check-update`（退出码 11）以及带内容校验的 `--update`；通过 `CLEAN_BOM_UPDATE_URL` 使用镜像；npm 安装会被引导回 npm。[详情 →](docs/UPDATE.md) |
| 📖 **完备的帮助** | `--help` 之外另有 12 个主题：`--help bom-policy`、`--help ci`、`--help json`…… |

## 实现 —— 同一份契约

| 实现 | 版本 | 平台 | 状态 |
|---|---|---|---|
| [`clean-bom-senior.sh`](clean-bom-senior.sh) | **3.0.0** | Linux、macOS、*BSD、WSL、Git Bash（bash ≥ 3.2，GNU **与** BSD userland） | 参考实现 |
| [`bin/bom.js`](bin/bom.js) —— npm `bom` / `clean-bom-senior` | **3.0.0** | **凡是 Node ≥ 18 能运行的地方，包括原生 Windows** | 原生 CLI |
| [`clean-bom-senior.ps1`](clean-bom-senior.ps1) | **3.0.0** | **PowerShell 7.6+ —— Windows、Linux、macOS。不需要任何外部工具** | 完整移植版 |
| [`clean-bom-senior.bat`](clean-bom-senior.bat) | 2.07.0 | Windows `cmd.exe`（没有 PowerShell，没有 Git Bash） | **旧版**，冻结在 v2 契约 |

三个 v3 实现由两个差分测试逐字节钉死 ——
`node tests/node/run-tests.mjs differential`（sh ↔ node）和
`python3 tests/ps/differential.py`（sh ↔ ps1，77 个场景）。在 Windows 上请用
npm CLI 或 PowerShell 移植版；批处理移植版留给两者都没有的主机，它是 **v2.07**
工具 —— 为何没有带到 v3，见 [`docs/BAT-PORT.md`](docs/BAT-PORT.md) §8。
契约：[`docs/CLI-CONTRACT.md`](docs/CLI-CONTRACT.md)。

---

## 安装

### npm（推荐 —— 所有平台，含 Windows）

```bash
npm install -g clean-bom-senior
bom --version            # → bom version 3.0.0 (Node.js implementation)
clean-bom-senior --help  # same tool, longer alias
```

### POSIX shell —— 从源码安装

```bash
git clone https://github.com/paulmann/Clean_BOM_Senior.git
cd Clean_BOM_Senior
sudo install -m 755 clean-bom-senior.sh /usr/local/bin/clean-bom-senior
clean-bom-senior --self-test
```

### POSIX shell —— 一行命令

```bash
curl -fsSL https://raw.githubusercontent.com/paulmann/Clean_BOM_Senior/main/clean-bom-senior.sh \
  -o clean-bom-senior.sh && chmod +x clean-bom-senior.sh
```

### PowerShell 7.6+ —— 从源码安装（Windows、Linux、macOS）

清理不需要任何外部工具；一切都是 .NET 字节 I/O。

```powershell
git clone https://github.com/paulmann/Clean_BOM_Senior.git
cd Clean_BOM_Senior
./clean-bom-senior.ps1 --self-test          # 10 fixtures, verifies this host
./clean-bom-senior.ps1 --help bom-policy    # the Smart BOM Policy in detail

# optional: put it on PATH
Copy-Item clean-bom-senior.ps1 "$HOME/.local/bin/clean-bom-senior.ps1"
```

> 该文件**有意写成纯 ASCII**，因此 `./clean-bom-senior.ps1` 可以直接在 Unix 上
> 运行 —— shebang 前面若有 UTF-8 BOM，内核就会退回到 `/bin/sh`。内置帮助仍会输出
> 参考实现里的长破折号和箭头：它们以占位符形式存储，输出时还原。
> 见 [`docs/PS-PORT.md`](docs/PS-PORT.md) §5。

### 自我更新（三个 v3 实现）

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

### 卸载

```bash
npm uninstall -g clean-bom-senior    # npm install
sudo rm /usr/local/bin/clean-bom-senior   # manual install
```

---

## 用法

```bash
clean-bom-senior.sh [OPTIONS] [PATH...]
```

`PATH` 可以是文件，**也可以是目录**（递归扫描）；不给 `PATH` 时扫描当前目录。
选项可以交错出现；`--` 结束选项解析（因此文件名可以以 `-` 开头）。

### 日常命令

```bash
bom                          # clean the tree with smart safe defaults
bom --dry-run                # what would change, and why (no writes)
bom --check                  # CI gate: exit 10 if anything is dirty
bom --check --json > r.json  # machine-readable gate report
bom src index.php            # a directory + a file
bom --git                    # only git-tracked files
bom -v                       # per-file log with every decision
```

### 一张图看懂智能 BOM 策略

```
                      ┌─ UTF-16/32 BOM ────────────► REFUSE (never touch)
file bytes ──classify─┼─ NUL bytes ────────────────► REFUSE (never touch)
                      ├─ invalid UTF-8 ────────────► PROTECT (--force: byte-clean)
                      ├─ UTF-8 BOM + sensitive ext ┐
                      │   + non-ASCII content ─────► KEEP BOM, fix CRLF, explain
                      ├─ UTF-8 BOM + code/ASCII ───► STRIP BOM (+ fix CRLF)
                      └─ no BOM, no CRLF ──────────► CLEAN: not rewritten at all
```

细节、理由与参考资料：[`docs/SMART-BOM.md`](docs/SMART-BOM.md) ·
`bom --help bom-policy`。

### 参数参考（节选 —— 完整版：`--help options`）

| 分组 | 参数 |
|---|---|
| 操作 | `-n/--dry-run` `-c/--check` `-f/--fix` `-v/--verbose` `-q/--quiet` `--silent` `-j/--json` `--color auto\|always\|never` `--log-file FILE` |
| 选择 | `--ext LIST` `--add-ext LIST` `--exclude GLOB` `--exclude-dir NAME` `--no-default-excludes` `--max-size 10M` `--git` |
| BOM 策略 | `--bom-policy auto\|strip\|keep` `--sensitive-ext LIST` `--force` |
| 转换 | `--no-bom-clear` `--no-rn-normalize`/`--no-crlf-normalize` `--update-mtime` `--backup` `--backup-dir DIR` |
| 信息 | `-h/--help [TOPIC]` `-V/--version` `--self-test` `--completion` `--strict` |
| 更新 | `--check-update` `--update` |

### 退出码

| 代码 | 含义 |
|---|---|
| 0 | 成功（目录已干净，或全部已清理） |
| 1 | 逐文件错误，或 `--strict` 发现有 kept/protected 文件 |
| 2 | 用法错误 |
| 3 | 环境问题（依赖、临时目录、更新网络、npm 托管的 `--update`） |
| 4 | 严重的内部错误 |
| **10** | `--check`：有文件需要清理 |
| **11** | `--check-update`：有可用更新 |

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

### pre-commit 钩子

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

更多配方：`bom --help ci`。

---

## BOM 为什么有害（PHP 的故事）

```php
\xEF\xBB\xBF<?php           ← invisible BOM
header('Content-Type: application/json');
```

- `Warning: Cannot modify header information — headers already sent`：BOM
  *就是*输出，在 `header()` 运行之前就被发出去了。
- JSON/XML API 被破坏：消费方在 `\uFEFF{...}` 上卡住。
- 拼接式构建和用 `include` 引入的文件会在数据流中间泄漏 BOM。
- CRLF/LF 混杂的目录会产生整文件 diff，并破坏 `#!/bin/sh`
  shebang（`/bin/sh^M: bad interpreter`）。

以及为什么“剥掉一切”*同样*是错的：

- **UTF-16/UTF-32**：BOM 是字节序标记 —— 去掉它就损坏了文件（记事本的
  “Unicode” `.txt` 正是这种情况）。
- **Excel / 旧版记事本 / Win32 ANSI API**：含非 ASCII 内容、不带 BOM 的 UTF-8
  `.csv`/`.txt` 会显示为乱码（`café` → `cafÃ©`）。
- **Windows PowerShell 5.1**：把不带 BOM 的非 ASCII `.ps1` 按 ANSI 解析 ——
  脚本语义改变或直接失败。

v3 恰好在 BOM 承担格式作用的地方保留它，恰好在它只是脏东西的地方剥掉它 ——
并且按文件告诉你它做了哪个决定。

---

## 安全保证

- **非必要不重写**：干净文件保留其 inode 与 mtime（由测试断言）。
- **原子且经校验**：同目录临时文件 → 校验
  （BOM 已去除 / CRLF 已去除 / 没有添加内容）→ `rename(2)`；就地重写保留回滚副本；
  没有残留文件（由测试断言）。
- **任何参数都无法推翻的硬性拒绝**：UTF-16/32、含 NUL 的二进制文件
  （`--force` 只解锁*软性*保护）。
- **元数据**：权限始终保留，以 root 运行时保留属主，默认保留被修改文件的时间戳
  （`--update-mtime` 可退出）。
- **硬链接与符号链接**：链接仍是链接（就地重写 + 警告）；
  作为参数的符号链接会被解析；遍历从不跟随符号链接。
- 完整清单：`bom --help safety` · [`docs/SMART-BOM.md`](docs/SMART-BOM.md) §4。

## 文档

| 文档 | 内容 |
|---|---|
| [`docs/SMART-BOM.md`](docs/SMART-BOM.md) | 策略：判定表、理由、编码参考资料 |
| [`docs/CLI-CONTRACT.md`](docs/CLI-CONTRACT.md) | 规范性的 v3 契约：参数、退出码、数据流、JSON 模式、字节语义 |
| [`docs/UPDATE.md`](docs/UPDATE.md) | 自动更新设计、校验、镜像、发布检查清单 |
| [`docs/TESTING.md`](docs/TESTING.md) | 测试架构、覆盖地图、两个差分测试、PowerShell 调用陷阱 |
| [`docs/PS-PORT.md`](docs/PS-PORT.md) | PowerShell 移植版：结构、差异、踩到的陷阱、它在参考实现里发现了什么 |
| [`docs/LLM-AGENT-USAGE.md`](docs/LLM-AGENT-USAGE.md) | 把工具接入 LLM 代理：技能 + 规则指针、各平台入口、缺失时安装 |
| [`skills/clean-bom-crlf/SKILL.md`](skills/clean-bom-crlf/SKILL.md) | 可移植技能本体，供任何加载技能的代理框架使用 |
| [`docs/PROMPT-OTHER-HARNESS.md`](docs/PROMPT-OTHER-HARNESS.md) | 让外部代理采纳该规则的复制粘贴提示词（RU） |
| [`CHANGELOG.md`](CHANGELOG.md) | v3.0.0：每个被修复的 v2 缺陷，附测量 |
| [`docs/BAT-PORT.md`](docs/BAT-PORT.md) | （旧版）cmd.exe 移植版如何工作，以及为什么没有 v3 批处理移植版 |
| [`docs/RAGRAF-REPORT.md`](docs/RAGRAF-REPORT.md) | （旧版）v2 时期的审计报告 |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) · [`SECURITY.md`](SECURITY.md) | 基本规则 · 漏洞报告 |

## 开发与测试

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

CI 矩阵：shellcheck → bash 套件（Ubuntu、macOS）→ Node 套件
（{18,20,22} × {Ubuntu, macOS, Windows}）→ PowerShell 套件（Ubuntu、macOS、
Windows）→ 两个差分测试 + 帮助同步闸门 → npm pack → 版本守卫。
见 [`docs/TESTING.md`](docs/TESTING.md)。

## 环境要求

- **npm CLI**：Node ≥ 18。别无他求 —— 任何操作系统。
- **PowerShell 移植版**：PowerShell 7.6+（Core）。清理本身不需要其他东西；
  `--git` 需要 `git`，`--update`/`--check-update` 需要 `curl`
  （`Invoke-WebRequest` 是备选），硬链接检测需要 `stat`/`fsutil`，
  以 root 转移属主需要 `chown`。
- **Shell 参考实现**：bash ≥ 3.2（macOS 自带的 bash 可用）、标准
  userland（`find sed awk od grep stat tail wc tr mv cp touch chmod mktemp`）；
  可选：`iconv`（UTF-8 校验）、`curl`/`wget`（`--update`）、`git`
  （`--git`）。
- **旧版移植**：PowerShell 7.6+ / Windows 10–11 `cmd.exe`。

## 许可证

[PolyForm Noncommercial 1.0.0](LICENSE) © Mikhail Deynekin — [deynekin.com](https://deynekin.com)
