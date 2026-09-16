#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0' }

BeforeAll {
    if ([string]::IsNullOrWhiteSpace($env:TEMP)) {
        $env:TEMP = [System.IO.Path]::GetTempPath()
    }

    $projectRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $projectRoot 'src' 'common' 'Logger.ps1')
    . (Join-Path $projectRoot 'src' 'common' 'Config.ps1')
    . (Join-Path $projectRoot 'src' 'common' 'Platform.ps1')
    . (Join-Path $projectRoot 'src' 'common' 'Report.ps1')
    . (Join-Path $projectRoot 'src' 'common' 'Utilities.ps1')
    . (Join-Path $projectRoot 'src' 'modules' 'Install-Apps.ps1')

    $testLogDir = Join-Path $env:TEMP 'dev-bootstrap-tests-appinstaller' 'log'
    Initialize-Logger -LogDirectory $testLogDir -Level 'Error' -Silent | Out-Null
}

Describe 'Get-EffectiveAppList' {
    It 'includes required apps for enabled modules' {
        $config = Get-DefaultConfig
        $catalog = Read-AppInstallerCatalog -ProjectRoot $projectRoot
        $config.modules.github.enabled = $true
        $config.modules.acr.enabled = $true
        $config.modules.appInstaller.recommendedApps.vscode = $false

        $apps = Get-EffectiveAppList -Config $config -Catalog $catalog
        $keys = @($apps | ForEach-Object { $_.key })

        $keys | Should -Contain 'git'
        $keys | Should -Contain 'azure-cli'
        $keys | Should -Contain 'docker'
    }

    It 'includes selected optional apps' {
        $config = Get-DefaultConfig
        $catalog = Read-AppInstallerCatalog -ProjectRoot $projectRoot
        $config.modules.appInstaller.recommendedApps.vscode = $true

        $apps = Get-EffectiveAppList -Config $config -Catalog $catalog
        $keys = @($apps | ForEach-Object { $_.key })

        $keys | Should -Contain 'vscode'
    }

    It 'always includes powershell7 as required baseline app' {
        $config = Get-DefaultConfig
        $catalog = Read-AppInstallerCatalog -ProjectRoot $projectRoot

        $config.modules.github.enabled = $false
        $config.modules.devops.enabled = $false
        $config.modules.acr.enabled = $false

        $apps = Get-EffectiveAppList -Config $config -Catalog $catalog
        $keys = @($apps | ForEach-Object { $_.key })

        $keys | Should -Contain 'powershell7'
    }

    It 'includes all apps from requiredByModule.general mapping' {
        $config = Get-DefaultConfig
        $catalog = Read-AppInstallerCatalog -ProjectRoot $projectRoot

        $apps = Get-EffectiveAppList -Config $config -Catalog $catalog
        $keys = @($apps | ForEach-Object { $_.key })

        foreach ($key in @($catalog.requiredByModule.general)) {
            $keys | Should -Contain $key
        }
    }

    It 'handles optional apps not present in catalog without throwing' {
        $config = Get-DefaultConfig
        $catalog = Read-AppInstallerCatalog -ProjectRoot $projectRoot
        $config.modules.appInstaller.optionalApps.legacyRemovedApp = $true

        { Get-EffectiveAppList -Config $config -Catalog $catalog } | Should -Not -Throw
        $missing = Get-MissingSelectedNonRequiredAppKeys -AppInstallerConfig $config.modules.appInstaller -Catalog $catalog

        $missing | Should -Contain 'legacyRemovedApp'
    }

    It 'keeps catalog apps sorted alphabetically within each category' {
        $catalog = Read-AppInstallerCatalog -ProjectRoot $projectRoot

        foreach ($category in @('required', 'recommended', 'optional')) {
            $names = @($catalog.apps | Where-Object { $_.category -eq $category } | ForEach-Object { $_.name })
            $sortedNames = @($names | Sort-Object)
            $names | Should -Be $sortedNames
        }
    }

    It 'includes the new optional app entries' {
        $catalog = Read-AppInstallerCatalog -ProjectRoot $projectRoot
        $keys = @($catalog.apps | ForEach-Object { $_.key })

        $keys | Should -Contain 'virtualbox'
        $keys | Should -Contain 'microsoft365Copilot'
        $keys | Should -Contain 'winmerge'
        $keys | Should -Contain 'anydesk'
        $keys | Should -Contain 'deepl'
        $keys | Should -Contain 'syncOutlookGoogleCalendars'
        $keys | Should -Contain 'unigetUi'
    }

    It 'defines a fallback id for UniGetUI' {
        $catalog = Read-AppInstallerCatalog -ProjectRoot $projectRoot
        $uniGet = @($catalog.apps | Where-Object { $_.key -eq 'unigetUi' })[0]

        $uniGet.wingetId | Should -Be 'MartiCliment.UniGetUI'
        $uniGet.wingetFallbackId | Should -Be 'MartiCliment.UniGetUI.Pre-Release'
    }
}

Describe 'Invoke-AppInstaller' {
    It 'returns report entries' {
        $config = Get-DefaultConfig
        $results = @(Invoke-AppInstaller -Config $config -ProjectRoot $projectRoot)
        $results.Count | Should -BeGreaterThan 0
        $results[0].Status | Should -BeIn @('INSTALLED', 'ALREADY_PRESENT', 'DEFERRED', 'SKIPPED', 'ERROR')
    }
}

Describe 'Convert-WingetListLineToVersionInfo' {
    It 'parses current and latest when available column exists' {
        $line = 'Visual Studio Code          Microsoft.VisualStudioCode     1.90.2      1.91.0      winget'
        $info = Convert-WingetListLineToVersionInfo -Line $line -AppId 'Microsoft.VisualStudioCode'

        $info.IsInstalled | Should -BeTrue
        $info.CurrentVersion | Should -Be '1.90.2'
        $info.LatestVersion | Should -Be '1.91.0'
    }

    It 'parses current version when available column is missing' {
        $line = 'Git                          Git.Git                        2.49.0      winget'
        $info = Convert-WingetListLineToVersionInfo -Line $line -AppId 'Git.Git'

        $info.IsInstalled | Should -BeTrue
        $info.CurrentVersion | Should -Be '2.49.0'
        $info.LatestVersion | Should -Be ''
    }

    It 'parses version when columns are separated by single spaces' {
        $line = 'Notepad++ (64-bit x64) Notepad++.Notepad++ 8.9.2 winget'
        $info = Convert-WingetListLineToVersionInfo -Line $line -AppId 'Notepad++.Notepad++'

        $info.IsInstalled | Should -BeTrue
        $info.CurrentVersion | Should -Be '8.9.2'
        $info.LatestVersion | Should -Be ''
    }

    It 'parses version when line contains ANSI sequences' {
        $line = "`e[32mNotepad++ (64-bit x64) Notepad++.Notepad++ 8.9.2    winget`e[0m"
        $info = Convert-WingetListLineToVersionInfo -Line $line -AppId 'Notepad++.Notepad++'

        $info.IsInstalled | Should -BeTrue
        $info.CurrentVersion | Should -Be '8.9.2'
        $info.LatestVersion | Should -Be ''
    }

    It 'ignores header-like lines' {
        $line = 'Name                           Id                              Version      Available    Source'
        $info = Convert-WingetListLineToVersionInfo -Line $line -AppId 'Git.Git'

        $info.IsInstalled | Should -BeFalse
    }
}

Describe 'Winget diagnostics helpers' {
    It 'converts negative exit code to hex HRESULT-like format' {
        (Convert-WingetExitCodeToHex -ExitCode -1978335189) | Should -Be '0x8A15002B'
        (Convert-WingetExitCodeToHex -ExitCode -1978334975) | Should -Be '0x8A150101'
    }

    It 'returns known hints for mapped winget codes' {
        (Get-WingetKnownErrorHint -HexCode '0x8A15002B') | Should -Match 'source/agreement issue'
        (Get-WingetKnownErrorHint -HexCode '0x8A150101') | Should -Match 'metadata/source conflict'
        (Get-WingetKnownErrorHint -HexCode '0x8A150014') | Should -Match 'Package not found in the selected source'
    }

    It 'builds failure message with version summary and hex code' {
        $versionInfo = @{
            IsInstalled = $true
            CurrentVersion = '2.49.0'
            LatestVersion = '2.50.0'
        }

        $message = Get-WingetFailureMessage -Operation 'install' -ExitCode -1978335189 -Output @('A detailed winget error') -VersionInfo $versionInfo
        $message | Should -Match '0x8A15002B'
        $message | Should -Match 'Current: 2.49.0, Latest: 2.50.0'
    }

    It 'uses current as latest fallback when installed and latest is unknown' {
        $summary = Get-WingetVersionSummary -VersionInfo @{
            IsInstalled = $true
            CurrentVersion = '1.111.0'
            LatestVersion = ''
        }

        $summary | Should -Be 'Current: 1.111.0, Latest: 1.111.0'
    }

    It 'extracts first meaningful output line skipping separators' {
        $line = Get-FirstMeaningfulOutputLine -Output @('', '-', '-----', '\\', '/', 'Name Id Version', 'Real error line')
        $line | Should -Be 'Real error line'
    }

    It 'detects already-installed messages from winget output' {
        (Test-WingetAlreadyInstalledOutput -Output @('E'' stato trovato un pacchetto esistente gia installato.')) | Should -BeTrue
        (Test-WingetAlreadyInstalledOutput -Output @('Package already installed.')) | Should -BeTrue
        (Test-WingetAlreadyInstalledOutput -Output @('Generic error')) | Should -BeFalse
    }

    It 'normalizes already-present info when install was detected by output only' {
        $normalized = ConvertTo-AlreadyPresentVersionInfo -VersionInfo @{
            IsInstalled = $false
            CurrentVersion = ''
            LatestVersion = ''
        }

        $normalized.IsInstalled | Should -BeTrue
        $normalized.CurrentVersion | Should -Be 'unknown'
    }

    It 'detects app-in-use output in Italian/English' {
        (Test-WingetAppInUseOutput -Output @('L''applicazione e attualmente in esecuzione.')) | Should -BeTrue
        (Test-WingetAppInUseOutput -Output @('Application is currently running.')) | Should -BeTrue
        (Test-WingetAppInUseOutput -Output @('Unrelated message')) | Should -BeFalse
    }

    It 'requires both current and latest to trigger auto-upgrade decision' {
        (Test-ShouldUpgradeInstalledApp -VersionInfo @{ IsInstalled = $true; CurrentVersion = '8.9.1'; LatestVersion = '8.9.2' }) | Should -BeTrue
        (Test-ShouldUpgradeInstalledApp -VersionInfo @{ IsInstalled = $true; CurrentVersion = '8.9.2'; LatestVersion = '8.9.2' }) | Should -BeFalse
        (Test-ShouldUpgradeInstalledApp -VersionInfo @{ IsInstalled = $true; CurrentVersion = '8.9.2'; LatestVersion = '' }) | Should -BeFalse
    }

    It 'does not treat older latest metadata as upgrade candidate' {
        (Test-ShouldUpgradeInstalledApp -VersionInfo @{ IsInstalled = $true; CurrentVersion = '1.28.220.0'; LatestVersion = '1.27.470.0' }) | Should -BeFalse
    }

    It 'normalizes displayed latest when current is newer than source metadata' {
        $summary = Get-WingetVersionSummary -VersionInfo @{
            IsInstalled = $true
            CurrentVersion = '1.28.220.0'
            LatestVersion = '1.27.470.0'
        }

        $summary | Should -Be 'Current: 1.28.220.0, Latest: 1.28.220.0'
    }

    It 'detects no-upgrade-available output from winget' {
        (Test-WingetNoUpgradeAvailableOutput -Output @('No applicable upgrade found.')) | Should -BeTrue
        (Test-WingetNoUpgradeAvailableOutput -Output @('Non sono disponibili aggiornamenti.')) | Should -BeTrue
        (Test-WingetNoUpgradeAvailableOutput -Output @('Non sono stati trovati aggiornamenti disponibili.')) | Should -BeTrue
        (Test-WingetNoUpgradeAvailableOutput -Output @('Non sono disponibili versioni più recenti del pacchetto dalle origini configurate.')) | Should -BeTrue
        (Test-WingetNoUpgradeAvailableOutput -Output @('Non sono disponibili versioni pi├╣ recenti del pacchetto dalle origini configurate.')) | Should -BeTrue
        (Test-WingetNoUpgradeAvailableOutput -Output @('Upgrade started')) | Should -BeFalse
    }
}

Describe 'Get-WingetLatestAvailableVersion' {
    It 'parses localized Versione line' {
        $v = Get-WingetLatestVersionFromShowOutput -Output @(
            'Titolo: Git',
            'Versione: 2.50.1'
        )
        $v | Should -Be '2.50.1'
    }
}

Describe 'Get-WingetInstallArguments' {
    It 'adds override arguments when configured' {
        $wingetArgs = Get-WingetInstallArguments -App @{
            wingetInstallOverride = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /MERGETASKS=!runcode,addcontextmenufiles,addcontextmenufolders,associatewithfiles'
        } -AppId 'Microsoft.VisualStudioCode' -WingetSource 'winget'

        $wingetArgs | Should -Contain '--override'
        $wingetArgs | Should -Contain '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /MERGETASKS=!runcode,addcontextmenufiles,addcontextmenufolders,associatewithfiles'
    }

    It 'keeps the base winget install arguments when override is absent' {
        $wingetArgs = Get-WingetInstallArguments -App @{} -AppId 'Git.Git' -WingetSource 'winget'

        $wingetArgs | Should -Not -Contain '--override'
        $wingetArgs | Should -Contain 'install'
        $wingetArgs | Should -Contain 'Git.Git'
    }

    It 'uses the provided source for install arguments' {
        $wingetArgs = Get-WingetInstallArguments -App @{} -AppId '9WZDNCRD29V9' -WingetSource 'msstore'

        $sourceIndex = [Array]::IndexOf($wingetArgs, '--source')
        $sourceIndex | Should -BeGreaterThan -1
        $wingetArgs[$sourceIndex + 1] | Should -Be 'msstore'
    }
}

Describe 'Get-WingetSourceForApp' {
    It 'defaults to winget when source is not configured' {
        (Get-WingetSourceForApp -App @{ wingetId = 'Git.Git' }) | Should -Be 'winget'
    }

    It 'uses normalized configured source when provided' {
        (Get-WingetSourceForApp -App @{ wingetId = '9WZDNCRD29V9'; wingetSource = ' MSStore ' }) | Should -Be 'msstore'
    }
}

Describe 'Winget fallback handling' {
    It 'returns the configured fallback id when present' {
        (Get-WingetFallbackId -App @{ wingetFallbackId = 'MartiCliment.UniGetUI.Pre-Release' }) | Should -Be 'MartiCliment.UniGetUI.Pre-Release'
    }

    It 'returns empty string when no fallback id is configured' {
        (Get-WingetFallbackId -App @{ wingetId = 'Git.Git' }) | Should -Be ''
    }

    It 'detects package-not-found by exit code 0x8A150014' {
        (Test-WingetPackageNotFoundOutput -ExitCode -1978335212 -Output @('')) | Should -BeTrue
    }

    It 'detects package-not-found from localized output text' {
        (Test-WingetPackageNotFoundOutput -ExitCode 1 -Output @('Nessun pacchetto trovato con criteri di input corrispondenti.')) | Should -BeTrue
        (Test-WingetPackageNotFoundOutput -ExitCode 1 -Output @('No package found matching input criteria.')) | Should -BeTrue
    }

    It 'does not flag unrelated failures as package-not-found' {
        (Test-WingetPackageNotFoundOutput -ExitCode 1 -Output @('Some other winget error')) | Should -BeFalse
    }
}

Describe 'PowerShell self-upgrade defer decision' {
    It 'does not defer when installed build is newer than source latest' -Skip:(-not $IsWindows) {
        $versionInfo = @{ IsInstalled = $true; CurrentVersion = '7.6.3.0'; LatestVersion = '7.6.2.0' }
        (Test-ShouldDeferPowerShellSelfUpgrade -App @{ key = 'powershell7'; wingetId = 'Microsoft.PowerShell' } -VersionInfo $versionInfo) | Should -BeFalse
    }

    It 'defers when a genuinely newer version is available' -Skip:(-not $IsWindows) {
        $versionInfo = @{ IsInstalled = $true; CurrentVersion = '7.6.2.0'; LatestVersion = '7.6.3.0' }
        (Test-ShouldDeferPowerShellSelfUpgrade -App @{ key = 'powershell7'; wingetId = 'Microsoft.PowerShell' } -VersionInfo $versionInfo) | Should -BeTrue
    }
}

Describe 'Get-CommandVersionInfo' {
    It 'supports powershell7 through pwsh --version output' {
        Mock -CommandName Test-CommandExists -ParameterFilter { $CommandName -eq 'pwsh' } -MockWith { $true }
        Mock -CommandName pwsh -MockWith { 'PowerShell 7.5.4' }

        $info = Get-CommandVersionInfo -App @{ key = 'powershell7' }
        $info.IsInstalled | Should -BeTrue
        $info.CurrentVersion | Should -Be '7.5.4'
    }
}

Describe 'PowerShell deferred upgrade queue' {
    It 'registers deferred action when environment allows it' {
        Mock -CommandName Test-DeferredPowerShellUpgradeEnvironment -MockWith { $true }
        Mock -CommandName Add-DeferredAction -MockWith { $true }

        $started = Add-DeferredPowerShellUpgradeAction

        $started | Should -BeTrue
        Should -Invoke Test-DeferredPowerShellUpgradeEnvironment -Times 1 -Exactly
        Should -Invoke Add-DeferredAction -Times 1 -Exactly
    }
}

AfterAll {
    $testRoot = Join-Path $env:TEMP 'dev-bootstrap-tests-appinstaller'
    if (Test-Path $testRoot) {
        Remove-Item -Path $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
