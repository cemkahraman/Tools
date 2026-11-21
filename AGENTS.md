# Repository Guidelines

## Project Structure & Module Organization

This repository is a small Windows utility. `RAMMapOtomatik.ps1` contains the automation, `RAMMap.exe` is its bundled RAMMap executable, and `config.json` stores runtime settings. `log.txt` and `son_sonuc.txt` are generated during use. `Komutlar.txt` records the supported commands. There is no separate source, test, or asset directory; keep related files together because the script resolves paths relative to its own directory.

## Build, Test, and Development Commands

There is no build step or package manager. Run commands from the repository folder:

- `powershell -ExecutionPolicy Bypass -File .\RAMMapOtomatik.ps1 durum` displays settings, cache size, and recent log entries.
- `powershell -ExecutionPolicy Bypass -File .\RAMMapOtomatik.ps1 simdi` performs a one-time cleanup (requires the utility to be configured).
- `powershell -ExecutionPolicy Bypass -File .\RAMMapOtomatik.ps1 kur` installs and starts scheduled tasks; use `ac`, `kapat`, or `kaldir` to manage them.

For script-only checks, parse without running commands: `$null = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\RAMMapOtomatik.ps1), [ref]$null, [ref]$null)`. The repository includes `RAMMapOtomatik.Tests.ps1`, a Pester 5 test suite.

## Coding Style & Naming Conventions

Use PowerShell, four-space indentation, and descriptive names consistent with the existing Turkish identifiers. Keep helper functions focused and use the established `Verb-Noun` pattern where practical. Preserve comments that explain task scheduling, retries, atomic config writes, or other operational safeguards. Keep configuration keys aligned with the defaults in `Ayar-Yukle`; use valid JSON and retain UTF-8 encoding.

## Testing Guidelines

Run the tests with `Invoke-Pester .\RAMMapOtomatik.Tests.ps1 -Output Detailed` (Pester 5 or later), then run the parser check above. The suite mocks system calls and uses a temporary directory; for behavior changes that need a live system check, inspect `log.txt` in a safe Windows environment. Avoid installing or deleting scheduled tasks without considering their effect.

## Commit & Pull Request Guidelines

Git history is unavailable in this checkout, so no repository-specific commit convention can be confirmed. Use short imperative commit subjects (for example, `Handle missing RAMMap path`). Pull requests should explain the behavior change, list commands or manual checks performed, and include relevant log output when it clarifies the result. Call out any changes to configuration defaults or scheduled-task behavior.

## Configuration & Runtime Data

Treat `config.json` as user-editable runtime configuration and logs/result files as generated data. Do not commit personal logs, temporary files, or machine-specific paths unless the change explicitly requires them. Keep `RamMapYolu` portable when possible, or document why a fixed path is required.
