# Copilot Instructions for dev-bootstrap

## Project Overview

Cross-platform workstation bootstrap suite for PowerShell 7+. Installs software, synchronizes
GitHub/DevOps repositories, and pulls ACR container images through a modular orchestrator.

## Language and Style

- All code, comments, commit messages, and log messages must be in **professional, concise English**.
- Follow **Clean Code** principles: small functions, meaningful names, no dead code.
- Target **PowerShell 7.0+** syntax exclusively.
- Use **4-space indentation** (no tabs).
- Use **approved verbs** (`Get-Verb`) for function names.
- Every advanced function must include `[CmdletBinding()]` and a `param()` block.

## Static Analysis

- Linter and formatter: **PSScriptAnalyzer** (`Invoke-ScriptAnalyzer`, `Invoke-Formatter`) with settings in `PSScriptAnalyzerSettings.psd1`.
- Preferred local quality command:
  ```powershell
  pwsh .\scripts\Invoke-CodeQuality.ps1
  ```
- If formatting drift exists, run:
  ```powershell
  pwsh .\scripts\Invoke-CodeQuality.ps1 -FixFormat
  ```
- Error-severity issues are blocking. Warnings should be resolved when practical.

## Testing

- Framework: **Pester 5+**.
- Tests live in `tests/` with `*.Tests.ps1` naming.
- Run the full suite directly when needed:
  ```powershell
  Invoke-Pester -Path .\tests -Output Detailed
  ```
- After every code change, run format + lint + tests to verify correctness.
- Write tests for new public functions and bug fixes.

## Project Structure

```
config/          Configuration files, JSON schema, templates, icons
docs/            Extended documentation
scripts/         Setup and helper scripts (prerequisites, version bump)
src/common/      Shared helpers: logging, filtering, config, platform, utilities
src/modules/     Module implementations: apps, automation, GitHub, DevOps, ACR
src/automation/  Automation scripts executed by the automation module
src/orchestrator/ Main orchestration entry point
tests/           Pester test files
```

## Key Conventions

- **Configuration**: JSON config at `config/config.json`, validated against `config/config.schema.json`.
- **Secrets**: sourced from environment variables or `.env` file. Never hard-code secrets.
- **Logging**: use `Write-Log` (from `src/common/Logger.ps1`), never `Write-Host` in modules.
- **Log language**: every `Write-Log` message authored by the app is professional, concise English, regardless of the OS display language. Raw external tool output (winget, git, az) that is localized by the OS must be logged at `-Level Debug` only, paired with an English `-Level Info` summary line.
- **Log format consistency**: module progress lines use `"<Entity> [n/N]: <label>"`; each processed item logs `  Action: <message>` then `  Status: <STATUS> (<duration>)`.
- **Report entries**: use `New-ReportEntry` with statuses: `ADDED`, `UPDATED`, `NONE`, `SKIPPED`, `ERROR`, `ORPHAN`, `INSTALLED`, `ALREADY_PRESENT`.
- **Filtering**: use `Test-IncludeExcludeMatch` from `src/common/Filters.ps1` for include/exclude logic.
- **Retry**: use `Invoke-WithRetry` from `src/common/Utilities.ps1` for network operations.
- **Idempotency**: all modules must be safe to run repeatedly without side effects.

## When Modifying Code

1. Read the target file(s) to understand existing patterns.
2. Follow the same code style and conventions already in the file.
3. Run `pwsh .\scripts\Invoke-CodeQuality.ps1` after changes.
4. Update documentation (README, inline help) when behavior changes.
5. Keep `src/automation/`, `config/automation.catalog.json`, `config/config.example.json`, and tests aligned for automation changes.
6. Do not add unnecessary abstractions, comments, or features beyond what is requested.

## Do Not

- Use aliases in scripts (e.g., use `ForEach-Object` not `%`).
- Use positional parameters.
- Use `Write-Host` in module code (use `Write-Log`).
- Commit `.env` or secrets.
- Introduce breaking changes to config schema without migration support.
