#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0' }

BeforeAll {
    if ([string]::IsNullOrWhiteSpace($env:TEMP)) {
        $env:TEMP = [System.IO.Path]::GetTempPath()
    }

    $projectRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $projectRoot 'src' 'common' 'Logger.ps1')
    . (Join-Path $projectRoot 'src' 'common' 'Config.ps1')
    . (Join-Path $projectRoot 'src' 'common' 'Utilities.ps1')
    . (Join-Path $projectRoot 'src' 'orchestrator' 'Invoke-DevBootstrap.ps1')

    $testLogDir = Join-Path $env:TEMP 'dev-bootstrap-tests-orchestrator' 'log'
    Initialize-Logger -LogDirectory $testLogDir -Level 'Error' -Silent | Out-Null
}

Describe 'Configured module summary' {
    It 'returns the defined module list with enabled states' {
        $config = Get-DefaultConfig
        $config.modules.automation.enabled = $true

        $definitions = @(Get-ConfiguredModuleDefinitions -Config $config -ProjectRoot $projectRoot)

        $definitions.Count | Should -Be 5
        $definitions[0].Name | Should -Be 'appInstaller'
        $definitions[0].Enabled | Should -BeTrue
        $definitions[1].Name | Should -Be 'automation'
        $definitions[1].Enabled | Should -BeTrue
    }

    It 'selects the requested enabled module by number' {
        $config = Get-DefaultConfig
        $config.modules.automation.enabled = $true
        $config.modules.github.enabled = $true

        $definitions = @(Get-ConfiguredModuleDefinitions -Config $config -ProjectRoot $projectRoot)

        Mock -CommandName Read-HostSafe -MockWith { '2' }
        Mock -CommandName Write-Log -MockWith { }

        $selectedRunMode = Select-RunModeFromEnabledModules -ModuleDefinitions $definitions -ProjectRoot $projectRoot

        $selectedRunMode | Should -Be 'automation'
    }

    It 'returns empty when exit is selected' {
        $config = Get-DefaultConfig
        $config.modules.automation.enabled = $true

        $definitions = @(Get-ConfiguredModuleDefinitions -Config $config -ProjectRoot $projectRoot)

        Mock -CommandName Read-HostSafe -MockWith { '0' }
        Mock -CommandName Write-Log -MockWith { }

        $selectedRunMode = Select-RunModeFromEnabledModules -ModuleDefinitions $definitions -ProjectRoot $projectRoot

        $selectedRunMode | Should -Be ''
    }

    It 'logs a summary of configured modules' {
        $config = Get-DefaultConfig
        $config.modules.github.enabled = $true

        $definitions = @(Get-ConfiguredModuleDefinitions -Config $config -ProjectRoot $projectRoot)

        Mock -CommandName Write-Log -MockWith { }

        Write-ConfiguredModuleSummary -ModuleDefinitions $definitions

        Should -Invoke Write-Log -Times 1 -ParameterFilter { $Message -eq 'Configured modules:' }
        Should -Invoke Write-Log -Times 1 -ParameterFilter { $Message -eq 'Modules scheduled for this run: App Installer, GitHub Sync' }
    }
}

AfterAll {
    $testRoot = Join-Path $env:TEMP 'dev-bootstrap-tests-orchestrator'
    if (Test-Path $testRoot) {
        Remove-Item -Path $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
