#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0' }

BeforeAll {
    if ([string]::IsNullOrWhiteSpace($env:TEMP)) {
        $env:TEMP = [System.IO.Path]::GetTempPath()
    }

    $projectRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $projectRoot 'src' 'common' 'Logger.ps1')
    . (Join-Path $projectRoot 'src' 'common' 'Platform.ps1')

    $testLogDir = Join-Path $env:TEMP 'dev-bootstrap-tests-platform' 'log'
    Initialize-Logger -LogDirectory $testLogDir -Level 'Error' -Silent | Out-Null
}

Describe 'Platform detection' {
    It 'returns a valid platform name' {
        Get-OSPlatform | Should -BeIn @('Windows', 'Linux', 'macOS', 'Unknown')
    }

    It 'is consistent with PowerShell automatic variables' {
        $platform = Get-OSPlatform
        if ($IsWindows) { $platform | Should -Be 'Windows' }
        elseif ($IsLinux) { $platform | Should -Be 'Linux' }
        elseif ($IsMacOS) { $platform | Should -Be 'macOS' }
    }
}

Describe 'Command and package manager checks' {
    It 'detects pwsh command' {
        Test-CommandExists -CommandName 'pwsh' | Should -BeTrue
    }

    It 'detects missing command' {
        Test-CommandExists -CommandName 'definitely_missing_command_xyz' | Should -BeFalse
    }

    It 'returns Windows package manager metadata on Windows' -Skip:(-not $IsWindows) {
        $manager = Get-WindowsPackageManager
        if ($manager) {
            $manager.Name | Should -Be 'winget'
        }
    }

    It 'returns Linux package manager metadata on Linux' -Skip:(-not $IsLinux) {
        $manager = Get-LinuxPackageManager
        if ($manager) {
            $manager.Name | Should -BeIn @('apt', 'dnf', 'yum', 'zypper')
        }
    }
}

AfterAll {
    $testRoot = Join-Path $env:TEMP 'dev-bootstrap-tests-platform'
    if (Test-Path $testRoot) {
        Remove-Item -Path $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
