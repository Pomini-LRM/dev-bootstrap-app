#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0' }

BeforeAll {
    if ([string]::IsNullOrWhiteSpace($env:TEMP)) {
        $env:TEMP = [System.IO.Path]::GetTempPath()
    }

    $projectRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $projectRoot 'src' 'common' 'Logger.ps1')
    . (Join-Path $projectRoot 'src' 'common' 'Report.ps1')

    $testLogDir = Join-Path $env:TEMP 'dev-bootstrap-tests-report' 'log'
    Initialize-Logger -LogDirectory $testLogDir -Level 'Error' -Silent | Out-Null
    Clear-ReportEntries
}

Describe 'Report entries' {
    BeforeEach {
        Clear-ReportEntries
    }

    It 'creates a valid report entry' {
        $entry = New-ReportEntry -Module 'GitHub' -Item 'owner/repo' -Status 'ADDED' -Message 'Cloned'
        $entry.Module | Should -Be 'GitHub'
        $entry.Status | Should -Be 'ADDED'
    }

    It 'adds and clears report entries' {
        Add-ReportEntry -Entry (New-ReportEntry -Module 'Test' -Item 'x' -Status 'NONE')
        (Get-ReportEntries).Count | Should -Be 1
        Clear-ReportEntries
        (Get-ReportEntries).Count | Should -Be 0
    }
}

Describe 'Write-FinalReport' {
    BeforeEach {
        Clear-ReportEntries
    }

    It 'returns zero when no errors exist' {
        Add-ReportEntry -Entry (New-ReportEntry -Module 'Test' -Item 'x' -Status 'ADDED')
        (Write-FinalReport -TotalDuration ([TimeSpan]::FromSeconds(1))) | Should -Be 0
    }

    It 'returns number of errors' {
        Add-ReportEntry -Entry (New-ReportEntry -Module 'Test' -Item 'x' -Status 'ERROR')
        Add-ReportEntry -Entry (New-ReportEntry -Module 'Test' -Item 'y' -Status 'ERROR')
        (Write-FinalReport -TotalDuration ([TimeSpan]::FromSeconds(1))) | Should -Be 2
    }

    It 'writes ERROR entries using Error log level' {
        Mock -CommandName Write-Log

        Add-ReportEntry -Entry (New-ReportEntry -Module 'Test' -Item 'x' -Status 'ERROR' -Message 'boom')
        $null = Write-FinalReport -TotalDuration ([TimeSpan]::FromSeconds(1))

        Should -Invoke Write-Log -ParameterFilter {
            $Level -eq 'Error' -and $Message -match 'ERROR\s+x'
        } -Times 1
    }

    It 'adds remediation steps for known auth failures' {
        Mock -CommandName Write-Log

        Add-ReportEntry -Entry (New-ReportEntry -Module 'GitHub' -Item 'AUTH' -Status 'ERROR' -Message 'GITHUB_TOKEN is not set and .env file is missing: C:\tmp\.env')
        $null = Write-FinalReport -TotalDuration ([TimeSpan]::FromSeconds(1))

        Should -Invoke Write-Log -ParameterFilter {
            $Level -eq 'Warning' -and $Message -match 'Recommended next steps'
        } -Times 1

        Should -Invoke Write-Log -ParameterFilter {
            $Level -eq 'Warning' -and $Message -match 'Create \.env from \.env\.example and set GITHUB_TOKEN'
        } -Times 1
    }
}

Describe 'Write-ModuleDetails' {
    It 'writes one detail table row per item with status and message' {
        Mock -CommandName Write-Log

        $entries = @(
            (New-ReportEntry -Module 'GitHub Sync' -Item 'repo-one' -Status 'ADDED')
            (New-ReportEntry -Module 'GitHub Sync' -Item 'repo-two' -Status 'ERROR' -Message 'clone failed')
            (New-ReportEntry -Module 'GitHub Sync' -Item 'repo-three' -Status 'ORPHAN' -Message 'local only')
        )

        Write-ModuleDetails -ModuleName 'GitHub Sync' -Entries $entries

        Should -Invoke Write-Log -ParameterFilter {
            $Level -eq 'Info' -and $Message -eq 'Module details: GitHub Sync'
        } -Times 1

        Should -Invoke Write-Log -ParameterFilter {
            $Level -eq 'Info' -and $Message -match '^\s+NAME\s+STATUS\s+ERROR/MESSAGE$'
        } -Times 1

        Should -Invoke Write-Log -ParameterFilter {
            $Level -eq 'Error' -and $Message -match 'repo-two\s+ERROR\s+clone failed'
        } -Times 1

        Should -Invoke Write-Log -ParameterFilter {
            $Level -eq 'Info' -and $Message -match 'repo-three\s+ORPHAN\s+local only'
        } -Times 1
    }
}

Describe 'Write-ExecutionDetails' {
    It 'writes one detail table row per non-NONE entry including module and message columns' {
        Mock -CommandName Write-Log

        $entries = @(
            (New-ReportEntry -Module 'GitHub' -Item 'repo-one' -Status 'NONE')
            (New-ReportEntry -Module 'DevOps' -Item 'repo-two' -Status 'ERROR' -Message 'pull failed')
        )

        Write-ExecutionDetails -Entries $entries

        Should -Invoke Write-Log -ParameterFilter {
            $Level -eq 'Info' -and $Message -eq 'Execution details:'
        } -Times 1

        Should -Invoke Write-Log -ParameterFilter {
            $Level -eq 'Info' -and $Message -match '^\s+MODULE\s+NAME\s+STATUS\s+ERROR/MESSAGE$'
        } -Times 1

        Should -Invoke Write-Log -ParameterFilter {
            $Level -eq 'Error' -and $Message -match 'DevOps\s+repo-two\s+ERROR\s+pull failed'
        } -Times 1

        Should -Invoke Write-Log -ParameterFilter {
            $Message -match 'repo-one\s+NONE'
        } -Times 0
    }
}

AfterAll {
    $testRoot = Join-Path $env:TEMP 'dev-bootstrap-tests-report'
    if (Test-Path $testRoot) {
        Remove-Item -Path $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
