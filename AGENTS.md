# Copilot Agents for dev-bootstrap

## Repository Baseline

1. Write code, comments, log messages, and documentation in professional, concise English.
2. Target PowerShell 7.0+ only and keep 4-space indentation.
3. Prefer small functions, explicit names, and minimal branching.
4. Keep `src/automation/`, `config/automation.catalog.json`, `config/config.example.json`, tests, and README aligned when automation behavior changes.
5. After every PowerShell change, run `pwsh ./scripts/Invoke-CodeQuality.ps1`. If formatting drift exists, run `pwsh ./scripts/Invoke-CodeQuality.ps1 -FixFormat` and rerun the quality gate.
6. All `Write-Log` messages authored by the app must be in English, regardless of the OS display language. External tool output (winget, git, az, etc.) is not translated: if it is localized by the OS, log it at `-Level Debug` only, and add an English `-Level Info` summary line around it.
7. Keep module log formatting consistent across `src/modules/`: progress lines use `"<Entity> [n/N]: <label>"`, and each processed item logs `  Action: <message>` followed by `  Status: <STATUS> (<duration>)`.

## Code Review Agent

When reviewing PowerShell code in this project:

1. Verify `#Requires -Version 7.0` is present in executable `.ps1` scripts.
2. Ensure functions use `[CmdletBinding()]` and typed `param()` blocks.
3. Check that `Write-Log` is used instead of `Write-Host` in module code.
4. Allow `Write-ConsoleStatus` only for transient console-only progress messages.
5. Confirm no aliases are used and positional parameters are avoided.
6. Verify secrets are never hard-coded or logged.
7. Check that report-producing paths use `New-ReportEntry` consistently.
8. Require a validation step after edits: formatter, lint, tests, and a focused smoke run when behavior changes.

## Testing Agent

When writing or updating tests:

1. Use Pester 5+ syntax with `Describe`, `Context`, `It`, `BeforeAll`, and `AfterAll`.
2. Place test files in `tests/` with the naming convention `<Feature>.Tests.ps1`.
3. Source required modules in `BeforeAll` using dot-sourcing from `$script:projectRoot`.
4. Initialize a temporary logger with `Initialize-Logger -LogDirectory $testLogDir -Level 'Error' -Silent`.
5. Clean up temporary files in `AfterAll`.
6. Restore environment variables modified during tests.
7. Use `Mock` for external dependencies such as API calls, filesystem access, `git`, `az`, and `docker`.

## Documentation Agent

When updating documentation:

1. Keep `README.md` as the single source of truth for user-facing docs.
2. Place developer and contributor guidance in `docs/` or `CONTRIBUTING.md`.
3. Use consistent Markdown formatting with ATX-style headers.
4. Update the README Table of Contents when headings change.
5. Keep configuration examples, quality commands, and automation catalogs in sync with the implementation.
