# Clean BOM Senior
Removes invisible UTF-8 BOM and CRLF from PHP, CSS, JS, TXT, XML, HTM, and HTML files. Prevents fatal PHP errors with namespace/declare. Atomic, safe, and CI-friendly: only changes files if needed and preserves timestamps. Ideal for cross-platform teams. 

```markdown
# clean-bom-senior.sh

**A secure, atomic, and robust BOM/CRLF batch cleaner for PHP, HTML, CSS, JS, and text files – engineered for modern, team-based development with CI/CD and pre-commit support.**

---

## What is This Project?

**clean-bom-senior.sh** is a professional-grade command-line utility that safely detects and removes the invisible UTF-8 Byte Order Mark (BOM) and Windows CRLF (`\r\n`) line endings from your source code and text files. The tool is written for Linux/Unix environments (POSIX shell), with a special focus on the needs of PHP developers working in multi-editor, cross-platform, and team scenarios.

### Why is This Important?

BOM and stray CRLF may silently break your PHP and web projects:

- They can trigger cryptic fatal errors in PHP, especially when using `namespace` and `declare(strict_types=1)`, which must be the very first statements in a PHP file.
- Such errors often appear only after a merge, server migration, or editor change, making them hard to diagnose.
- Manually cleaning files is slow, error-prone, and unscalable for real projects.

This script provides peace of mind, automation, and reliability in every stage: local development, code review, and automated deployment.

---

## Key Features

- **Safe atomic operation:** Never modifies a file unless BOM or CRLF is truly present. File timestamps are unchanged if nothing changed.
- **Full recursion and glob support:** Cleans all supported file types (PHP, CSS, JS, TXT, XML, HTM, HTML) in project trees or by explicit file list.
- **Professional error handling:** Each operation is atomic, with secure temp files, backup/rollback, and robust permission validation.
- **Dry-run and verbose reporting:** Preview changes before applying, and get detailed logs per file.
- **CI/CD and pre-commit ready:** Easy to integrate as a code hygiene step in automated pipelines and Git hooks.

---

## Quick Start

```
# Make executable
chmod +x clean-bom-senior.sh

# Recursively process all relevant files (in the current directory and subfolders)
./clean-bom-senior.sh

# Check what would be cleaned, do not modify (dry run mode)
./clean-bom-senior.sh --dry-run

# Clean only specific files
./clean-bom-senior.sh src/index.php assets/main.js

# Extra options (see --help for full list)
./clean-bom-senior.sh --verbose
./clean-bom-senior.sh --help
```

---

## Usage and Options

```
Usage: clean-bom-senior.sh [OPTIONS] [FILES...]
Options:
  -h, --help       Show help message and exit
  -v, --verbose    Enable detailed output of all actions
  -n, --dry-run    Show which files would be processed, but do not modify
  -V, --version    Show script version

If no files are specified, the script recursively processes all PHP, CSS, JS, TXT, XML, HTM, and HTML files in the current directory.
```

---

## How Does It Work?

- **Detection:** Checks only first bytes and early lines for BOM and CRLF—fast, safe, and efficient.
- **Atomic Replace:** Changes are made in secure temporary and backup files with permissions and timestamps preserved. Original files are only replaced if needed.
- **No-Op Guarantee:** If no BOM or CRLF is found, file is never touched and its modification time remains intact.

### Supported Extensions

- `.php`, `.css`, `.js`, `.txt`, `.xml`, `.htm`, `.html`

You can modify the SUPPORTED_EXTENSIONS variable at the top of the script to add/remove file types.

---

## Example: Why Use This Tool?

- **Real-world PHP example:**  
  If any single byte—even BOM or a Windows newline—precedes your `namespace` or `declare(strict_types=1)`, PHP will break with fatal error.  
  This happens frequently in teams, with editors adding encoding marks invisibly.

- **CI/CD Integration:**  
  Clean up all code before deploy and in pre-commit, preventing bugs and maximizing uptime.

---

## Recommended Usage in CI/CD

Add to `.gitlab-ci.yml`, GitHub Actions, or pre-commit hooks:

```
./clean-bom-senior.sh --dry-run  # To preview or enforce before merge
./clean-bom-senior.sh            # As a cleanup step before packaging or deploy
```

---

## Contributing & Support

Pull requests, bug reports, and suggestions are welcome! Please ensure your code passes basic `shellcheck` and stays POSIX-compliant.

- **Issues:** Use [GitHub Issues](https://github.com/YOUR_REPO/clean-bom-senior/issues)
- **Wiki & FAQ:** See the [docs/](docs/) directory for extended manuals and examples.

---

## License

MIT License. See [LICENSE](LICENSE) for details.

---

## Maintainers & Acknowledgements

This script is developed and maintained by [Mikhail Deynekin](https://deynekin.com), with community contributions.  
Inspired by real-world team collaboration problems and years of PHP production support.

---

## See Also

- [Why BOM breaks PHP? (StackOverflow)](https://stackoverflow.com/questions/21433086/fatal-error-namespace-declaration-statement-has-to-be-the-very-first-statement)
- [PHP: Namespaces](https://www.php.net/manual/en/language.namespaces.definition.php)
- [GitHub README guide](https://docs.github.com/ru/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes)

---

*Built for high-reliability, human safety, and robust automation in real-world projects. Stop invisible encoding bugs in their tracks!*
