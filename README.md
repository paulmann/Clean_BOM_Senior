# Clean BOM Senior 🧹✨

[![Version](https://img.shields.io/badge/version-2.06.4-blue.svg)](https://github.com/paulmann/Clean_BOM_Senior)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/shell-bash-orange.svg)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Unix-lightgrey.svg)]()

> **A production-ready shell utility for safely removing invisible UTF-8 BOM and Windows CRLF from source code files**

Clean BOM Senior is a robust, enterprise-grade bash script designed to detect and remove invisible UTF-8 Byte Order Marks (BOM) and Windows CRLF line endings that can cause critical errors in PHP, JavaScript, CSS, and other source code files.

## ⚡ Quick Start

```bash
# Clone and install
git clone https://github.com/paulmann/Clean_BOM_Senior.git
cd Clean_BOM_Senior
chmod +x clean-bom-senior.sh

# Clean all files recursively
./clean-bom-senior.sh

# Preview what would be cleaned (dry run)
./clean-bom-senior.sh --dry-run

# Verbose mode with detailed logging
./clean-bom-senior.sh --verbose

# Clean specific files
./clean-bom-senior.sh file1.php file2.js config.xml
```

## 🚨 Why Clean BOM Senior?

### The Hidden Problem

UTF-8 BOM markers are **invisible** 3-byte sequences (`EF BB BF`) that can break your code:

```php
<?php
// ⚠️ This file has invisible BOM - will cause FATAL ERROR!
namespace MyApp\Controllers;  // Fatal error: Namespace declaration statement has to be...
```

```javascript
// ⚠️ BOM here causes encoding issues
import { Component } from 'react';  // Potential parsing errors
```

### Real-World Impact

- **PHP Fatal Errors**: BOM before `namespace` or `declare(strict_types=1)` statements
- **JavaScript Parsing Issues**: BOM can break module imports and cause encoding problems  
- **CSS Rendering Problems**: BOM may cause unexpected styling behavior
- **Cross-Platform Conflicts**: Mixed CRLF/LF line endings between Windows and Unix systems
- **CI/CD Pipeline Failures**: Automated builds failing due to encoding issues

## ✨ Key Features

### 🛡️ **Enterprise-Grade Safety**
- **Atomic Operations**: Changes are applied atomically or rolled back completely
- **Automatic Backups**: Creates backup copies during processing with automatic cleanup
- **File Integrity**: Preserves original file ownership, permissions, and timestamps
- **Error Recovery**: Comprehensive rollback mechanism on any failure

### 🎯 **Intelligent Processing**
- **Smart Detection**: Only processes files that actually contain BOM or CRLF issues
- **Multi-Format Support**: PHP, CSS, JS, TXT, XML, HTM, HTML files
- **Size Limits**: Built-in protection against processing oversized files (100MB default)
- **Extension Filtering**: Configurable file extension support

### 📊 **Comprehensive Reporting**
- **Detailed Statistics**: Complete breakdown of processed files by type and issues fixed
- **Progress Tracking**: Real-time logging with timestamps and color coding
- **Dry-Run Mode**: Preview operations without making changes
- **Error Classification**: Categorized error reporting with resolution suggestions

### 🔄 **DevOps Integration**
- **CI/CD Ready**: Perfect for integration into build pipelines
- **Git Hooks**: Ideal for pre-commit hooks and automated workflows
- **Cross-Platform**: Works on Linux, macOS, and Unix systems
- **No Dependencies**: Pure bash script with standard Unix utilities only

## 📋 Installation & Usage

### System Requirements

- **Shell**: Bash 4.0+ (or compatible: sh, dash)
- **OS**: Linux, macOS, Unix-like systems
- **Tools**: Standard utilities (`find`, `sed`, `od`, `grep`, `stat`, `mv`, `cp`, `touch`, `chown`, `chmod`)
- **Permissions**: Write access to target directory and temp folder

### Installation Options

#### Option 1: Direct Download
```bash
wget https://github.com/paulmann/Clean_BOM_Senior/raw/main/clean-bom-senior.sh
chmod +x clean-bom-senior.sh
./clean-bom-senior.sh --help
```

#### Option 2: Git Clone
```bash
git clone https://github.com/paulmann/Clean_BOM_Senior.git
cd Clean_BOM_Senior
chmod +x clean-bom-senior.sh
```

#### Option 3: Global Installation
```bash
# Install globally (requires sudo)
sudo curl -o /usr/local/bin/bom https://github.com/paulmann/Clean_BOM_Senior/raw/main/clean-bom-senior.sh
sudo chmod +x /usr/local/bin/bom

# Now use anywhere with simple command
bom --help
bom --dry-run
```

#### Option 4: User Alias
```bash
# Add to ~/.bashrc or ~/.bash_profile
alias bom='/path/to/clean-bom-senior.sh'

# Reload shell configuration
source ~/.bashrc

# Use the alias
bom --verbose
```

### Command Line Options

| Option | Description |
|--------|-------------|
| `-h, --help` | Show comprehensive help message and exit |
| `-v, --verbose` | Enable detailed output and processing logs |
| `-n, --dry-run` | Preview mode - show what would be processed without making changes |
| `-V, --version` | Display script version and author information |

### Usage Examples

#### Basic Usage
```bash
# Clean all supported files in current directory and subdirectories
./clean-bom-senior.sh

# Clean with verbose output
./clean-bom-senior.sh --verbose

# Preview changes without modifying files
./clean-bom-senior.sh --dry-run
```

#### Specific Files
```bash
# Clean specific files
./clean-bom-senior.sh config.php script.js style.css

# Clean files with verbose logging
./clean-bom-senior.sh --verbose src/Controller.php src/Model.php

# Preview specific files
./clean-bom-senior.sh --dry-run templates/*.php
```

#### Directory Processing
```bash
# Clean entire project (recursive)
./clean-bom-senior.sh

# Clean specific directory with verbose output
./clean-bom-senior.sh --verbose src/

# Preview entire project changes
./clean-bom-senior.sh --dry-run --verbose
```

## 🏗️ Advanced Features

### File Preservation Guarantees

Clean BOM Senior ensures **complete file integrity**:

```bash
# Before processing (example file attributes)
-rw-r--r-- 1 developer team 1234 Oct 28 10:30 script.php

# After processing - ALL attributes preserved
-rw-r--r-- 1 developer team 1156 Oct 28 10:30 script.php
# ✅ Same owner, group, permissions, timestamp
# ❌ Only file size changed (BOM removed: 1234 → 1156 bytes)
```

**What's Preserved:**
- ✅ **Ownership**: Original user and group ownership
- ✅ **Permissions**: File mode/access rights (755, 644, etc.)
- ✅ **Timestamps**: Last modified time (crucial for build systems)
- ✅ **Content Integrity**: Only BOM and CRLF are removed

### Comprehensive Statistics

```bash
# Example output with statistics
=== PROCESSING SUMMARY ===
Execution time: 2 seconds
Files processed: 15
Files skipped (clean): 8
Errors encountered: 0

--- Issues Fixed ---
BOM signatures removed: 12
CRLF line endings fixed: 8

--- File Type Distribution ---
.php files: 10
.js files: 3
.css files: 2
```

### Supported File Types

| Extension | Purpose | Common Issues |
|-----------|---------|---------------|
| `.php` | PHP scripts | BOM breaks `namespace`, `declare()` |
| `.css` | Stylesheets | BOM can affect rendering |
| `.js` | JavaScript | BOM may break modules/imports |
| `.txt` | Text files | Mixed line endings |
| `.xml` | XML documents | BOM affects XML parsing |
| `.htm/.html` | Web pages | Encoding display issues |

### Error Handling

Clean BOM Senior provides **bulletproof error handling**:

```bash
--- Error Breakdown ---
Access errors: 2        # Permission denied files
File size errors: 1     # Files exceeding size limit
Processing errors: 0    # Content processing failures
Other errors: 0         # Miscellaneous issues
```

**Error Recovery Features:**
- 🔄 **Automatic Rollback**: Failed operations are completely reverted
- 💾 **Backup & Restore**: Temporary backups ensure data safety
- 📝 **Detailed Logging**: Every error includes context and suggestions
- 🛡️ **Safe Defaults**: Conservative approach prevents data loss

## 🔗 DevOps Integration

### CI/CD Pipeline Integration

#### GitHub Actions
```yaml
name: Clean BOM
on: [push, pull_request]
jobs:
  clean-bom:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Clean BOM markers
        run: |
          wget https://github.com/paulmann/Clean_BOM_Senior/raw/main/clean-bom-senior.sh
          chmod +x clean-bom-senior.sh
          ./clean-bom-senior.sh --dry-run --verbose
```

#### GitLab CI
```yaml
clean_bom:
  stage: test
  script:
    - wget https://github.com/paulmann/Clean_BOM_Senior/raw/main/clean-bom-senior.sh
    - chmod +x clean-bom-senior.sh
    - ./clean-bom-senior.sh --verbose
  only:
    - merge_requests
    - main
```

### Git Hooks

#### Pre-commit Hook
```bash
#!/bin/bash
# .git/hooks/pre-commit
./tools/clean-bom-senior.sh --dry-run > /dev/null
if [ $? -ne 0 ]; then
    echo "❌ BOM or CRLF issues found. Run: ./tools/clean-bom-senior.sh"
    exit 1
fi
echo "✅ No BOM/CRLF issues detected"
```

#### Pre-push Hook
```bash
#!/bin/bash
# .git/hooks/pre-push
echo "🧹 Cleaning BOM markers before push..."
./tools/clean-bom-senior.sh --verbose
```

### Docker Integration

```dockerfile
# Dockerfile example
FROM php:8.1-alpine
COPY . /app
WORKDIR /app

# Clean BOM as part of build process
RUN wget https://github.com/paulmann/Clean_BOM_Senior/raw/main/clean-bom-senior.sh \
    && chmod +x clean-bom-senior.sh \
    && ./clean-bom-senior.sh \
    && rm clean-bom-senior.sh

CMD ["php", "index.php"]
```

## 🏢 Team & Enterprise Usage

### Project Setup
```bash
# Add to project tools
mkdir -p tools
cd tools
wget https://github.com/paulmann/Clean_BOM_Senior/raw/main/clean-bom-senior.sh
chmod +x clean-bom-senior.sh

# Create project alias in package.json (for Node.js projects)
{
  "scripts": {
    "clean-bom": "./tools/clean-bom-senior.sh --verbose",
    "check-bom": "./tools/clean-bom-senior.sh --dry-run"
  }
}

# Or in Makefile
clean-bom:
	./tools/clean-bom-senior.sh --verbose

check-bom:
	./tools/clean-bom-senior.sh --dry-run
```

### Team Workflow
```bash
# Before committing changes
npm run check-bom          # or: make check-bom
# If issues found:
npm run clean-bom          # or: make clean-bom

# Regular maintenance
./tools/clean-bom-senior.sh --verbose  # Weekly cleanup
```

### IDE Integration

#### VS Code Task (`.vscode/tasks.json`)
```json
{
    "version": "2.0.0",
    "tasks": [
        {
            "label": "Clean BOM",
            "type": "shell",
            "command": "./tools/clean-bom-senior.sh",
            "args": ["--verbose"],
            "group": "build",
            "presentation": {
                "echo": true,
                "reveal": "always"
            }
        }
    ]
}
```

## 🔍 Troubleshooting

### Common Issues

#### Permission Errors
```bash
# Problem: Cannot write to file
[ERROR] Cannot write to file: protected.php

# Solution: Check file permissions
chmod 644 protected.php
# Or run with appropriate permissions
sudo ./clean-bom-senior.sh
```

#### No Files Found
```bash
# Problem: "No files found with supported extensions"
# Solution: Verify you're in the correct directory
ls -la *.{php,css,js,html}  # Check for supported files
pwd                          # Verify current directory
```

#### Large Files Skipped
```bash
# Problem: File size exceeds limit
# Check file sizes
find . -name "*.php" -size +100M -exec ls -lh {} \;

# Solution: Process large files individually if needed
./clean-bom-senior.sh specific-large-file.php
```

### Debugging Commands

```bash
# Check for BOM manually
hexdump -C file.php | head -1
# Look for: EF BB BF at beginning

# Check for CRLF
od -c file.php | head -5
# Look for: \r \n sequences

# Verify UTF-8 encoding
file -i file.php
# Should show: charset=utf-8
```

### Recovery Procedures

```bash
# If something goes wrong, backups are created as:
# filename.bak.PROCESS_ID

# Restore from backup
cp file.php.bak.12345 file.php

# Clean up backup files
rm *.bak.*
```

## 🤝 Contributing

We welcome contributions! Here's how to get involved:

### Development Setup
```bash
git clone https://github.com/paulmann/Clean_BOM_Senior.git
cd Clean_BOM_Senior

# Run tests (if available)
./test-suite.sh

# Check script syntax
bash -n clean-bom-senior.sh

# Test dry run
./clean-bom-senior.sh --dry-run --verbose
```

### Contribution Guidelines

1. **Fork** the repository
2. **Create** a feature branch (`git checkout -b feature/amazing-feature`)
3. **Test** your changes thoroughly
4. **Commit** your changes (`git commit -m 'Add amazing feature'`)
5. **Push** to the branch (`git push origin feature/amazing-feature`)
6. **Open** a Pull Request

### Code Standards

- ✅ **POSIX Compliance**: Ensure compatibility across different shells
- ✅ **Error Handling**: Comprehensive error checking and recovery
- ✅ **Documentation**: Comment complex logic and functions
- ✅ **Testing**: Verify functionality across different file types
- ✅ **Backwards Compatibility**: Maintain compatibility with existing usage

## 📄 License

This project is licensed under the **MIT License** - see the [LICENSE](LICENSE) file for details.

```
MIT License

Copyright (c) 2025 Mikhail Deynekin

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
```

## 👨‍💻 Author & Support

**Mikhail Deynekin**
- 🌐 Website: [deynekin.com](https://deynekin.com)
- 📧 Email: mid1977@gmail.com
- 🐙 GitHub: [@paulmann](https://github.com/paulmann)

### Getting Help

- 📖 **Documentation**: Read this README thoroughly
- 🐛 **Bug Reports**: [Open an issue](https://github.com/paulmann/Clean_BOM_Senior/issues/new)
- 💡 **Feature Requests**: [Request features](https://github.com/paulmann/Clean_BOM_Senior/issues/new)
- 💬 **Questions**: Check [Discussions](https://github.com/paulmann/Clean_BOM_Senior/discussions)

### Related Projects

- [ssg/unbom](https://github.com/ssg/unbom) - .NET tool for BOM removal
- [stdlib-js/string-remove-utf8-bom](https://github.com/stdlib-js/string-remove-utf8-bom) - Node.js BOM removal

## 🎯 Roadmap

### Upcoming Features

- [ ] **Web Interface**: Browser-based file upload and cleaning
- [ ] **Docker Image**: Pre-built container for CI/CD integration
- [ ] **Windows Support**: Native Windows PowerShell version
- [ ] **Plugin System**: Extensible architecture for custom processors
- [ ] **Performance Optimization**: Parallel processing for large codebases
- [ ] **Advanced Reporting**: HTML/JSON output formats

### Version History

- **v2.06.4** (2025-09-28): Fixed statistics reporting, improved process substitution
- **v2.06.3** (2025-09-28): Resolved unbound variable issues, enhanced error handling
- **v2.06.2** (2025-09-28): Added file attribute preservation, global command support
- **v2.05.0** (2025-09-28): Major refactor with comprehensive statistics and CI/CD integration

---

<div align="center">

### ⭐ Star this repository if it helped you!

**Clean BOM Senior** - *Making source code clean, one file at a time* 🧹✨

[Report Bug](https://github.com/paulmann/Clean_BOM_Senior/issues) · [Request Feature](https://github.com/paulmann/Clean_BOM_Senior/issues) · [Documentation](https://github.com/paulmann/Clean_BOM_Senior/wiki)

</div>
