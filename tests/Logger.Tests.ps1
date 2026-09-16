#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0' }

BeforeAll {
    if ([string]::IsNullOrWhiteSpace($env:TEMP)) {
        $env:TEMP = [System.IO.Path]::GetTempPath()
    }

    $projectRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $projectRoot 'src' 'common' 'Logger.ps1')
}

Describe 'Initialize-Logger' {
    It 'creates a log file with the expected naming format' {
        $dir = Join-Path $env:TEMP "dev-bootstrap-logtest-$(Get-Random)"
        try {
            $logPath = Initialize-Logger -LogDirectory $dir -Level 'Info' -Silent
            [System.IO.Path]::GetFileName($logPath) | Should -Match '^\d{8}_\d{6}_log\.log$'
        }
        finally {
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Write-Log and sanitization' {
    It 'writes messages to file' {
        $dir = Join-Path $env:TEMP "dev-bootstrap-logtest-$(Get-Random)"
        try {
            $logPath = Initialize-Logger -LogDirectory $dir -Level 'Debug' -Silent
            Write-Log -Level Info -Message 'hello world'
            (Get-Content -LiteralPath $logPath -Raw) | Should -Match 'hello world'
        }
        finally {
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'redacts secrets from output' {
        $text = ConvertTo-SanitizedString -Text 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz token=12345'
        $text | Should -Match 'REDACTED'
        $text | Should -Not -Match 'abcdefghijklmnopqrstuvwxyz'
    }
}
