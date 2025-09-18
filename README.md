## Clean BOM Senior ( clean-bom-senior.sh )

# Removes invisible UTF-8 BOM and Windows CRLF from PHP, CSS, JS, TXT, XML, HTM, and HTML files.
# Prevents fatal PHP errors when namespace or declare(strict_types=1) must be first.
# Atomic, safe, CI/CD-friendly: only alters files if needed and preserves timestamps.
# Engineered for modern, cross-platform teams.


## What is This Project?

**clean-bom-senior.sh** is a professional-grade POSIX shell utility for Linux/Unix that safely detects and removes the invisible UTF-8 Byte Order Mark (BOM) and Windows CRLF (`\r\n`) line endings from your source code and text files. It’s designed for PHP developers working in multi-editor, cross-platform, and team environments.

### Why Is This Important?

- Invisible BOM or stray CRLF can trigger fatal PHP errors, especially when using `namespace` and `declare(strict_types=1)` as the very first statements in a file.  
- Such errors often surface only after merges, server migrations, or editor changes, making them hard to diagnose.  
- Manual cleanup is tedious, error-prone, and unscalable for real-world projects.

This tool automates the cleanup, ensuring reliability at every stage: local development, code review, and CI/CD deployment.

***

## Key Features

- **Safe atomic operation:** Files are only modified if BOM/CRLF is detected; otherwise timestamps remain intact.  
- **Recursive & glob support:** Cleans all supported extensions (`.php`, `.css`, `.js`, `.txt`, `.xml`, `.htm`, `.html`) in directories or on specified files.  
- **Robust error handling:** Atomic replace with secure temp files, backups, rollbacks, and permission checks.  
- **Dry-run & verbose modes:** Preview changes or get detailed logs per file.  
- **CI/CD & Git hook ready:** Easily integrate into pipelines or pre-commit hooks for automated code hygiene.

***

## Quick Start

Make the script executable:

```bash
chmod +x clean-bom-senior.sh
```

Process all supported files recursively:

```bash
./clean-bom-senior.sh
```

Preview changes without modifying files (dry-run):

```bash
./clean-bom-senior.sh --dry-run
```

Clean specific files:

```bash
./clean-bom-senior.sh src/index.php assets/main.js
```

Enable verbose output:

```bash
./clean-bom-senior.sh --verbose
```

Display help:

```bash
./clean-bom-senior.sh --help
```

***

## Usage and Options

```text
Usage: clean-bom-senior.sh [OPTIONS] [FILES...]
Options:
  -h, --help       Show help message and exit
  -v, --verbose    Enable detailed output
  -n, --dry-run    Preview files without modifying
  -V, --version    Show script version
If no FILES are specified, the script recursively processes all supported extensions
in the current directory.
```

***

## How It Works

1. **Detection:** Fast check of the first bytes and early lines for BOM/CRLF.  
2. **Atomic Replace:** Secure temp and backup files with preserved permissions and timestamps.  
3. **No-Op Guarantee:** Files without BOM or CRLF are never touched, preserving mtime.

Modify `SUPPORTED_EXTENSIONS` in the script to add or remove file types.

***

## Example: Why Use This Tool?

- **PHP scenario:** A hidden BOM byte before `namespace` or `declare(strict_types=1)` causes fatal errors.  
- **CI/CD integration:** Automate cleanup in pipelines or pre-commit to prevent encoding bugs in production.

***

## Recommended CI/CD Integration

Add to GitHub Actions, GitLab CI, or pre-commit hooks:

```bash
./clean-bom-senior.sh --dry-run   # Enforce before merge
./clean-bom-senior.sh             # Cleanup step before deploy
```

***

## Contributing & Support

Pull requests, bug reports, and suggestions are welcome. Ensure contributions pass `shellcheck` and remain POSIX-compliant.

- Issues: [GitHub Issues](https://github.com/YOUR_REPO/clean-bom-senior/issues)  
- Docs & examples: see the `docs/` directory

***

## License

MIT License — see [LICENSE](LICENSE) for details.

***

## Maintainers & Acknowledgements

Developed and maintained by [Mikhail Deynekin](https://deynekin.com). Inspired by real-world team collaboration challenges and extensive PHP production support.

***

## See Also

- [Why BOM breaks PHP? (StackOverflow)](https://stackoverflow.com/questions/21433086/fatal-error-namespace-declaration-statement-has-to-be-the-very-first-statement)  
- [PHP Namespaces manual](https://www.php.net/manual/en/language.namespaces.definition.php)  
- [GitHub README guide](https://docs.github.com/ru/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes)
