#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0' }

BeforeAll {
    if ([string]::IsNullOrWhiteSpace($env:TEMP)) {
        $env:TEMP = [System.IO.Path]::GetTempPath()
    }

    $projectRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $projectRoot 'src' 'common' 'Logger.ps1')
    . (Join-Path $projectRoot 'src' 'common' 'Platform.ps1')
    . (Join-Path $projectRoot 'src' 'common' 'Utilities.ps1')
    . (Join-Path $projectRoot 'src' 'common' 'Config.ps1')
    . (Join-Path $projectRoot 'src' 'common' 'Report.ps1')
    . (Join-Path $projectRoot 'src' 'modules' 'Invoke-Automation.ps1')

    $testLogDir = Join-Path $env:TEMP 'dev-bootstrap-tests-automation' 'log'
    Initialize-Logger -LogDirectory $testLogDir -Level 'Error' -Silent | Out-Null
}

# ── Catalog parsing and validation ──────────────────────────────────────────

Describe 'Automation catalog' {
    It 'loads automation catalog entries' {
        $catalog = Read-AutomationCatalog -ProjectRoot $projectRoot
        @($catalog.automations).Count | Should -Be 4
        @($catalog.automations | ForEach-Object { $_.key }) | Should -Contain 'addMakePath'
        @($catalog.automations | ForEach-Object { $_.key }) | Should -Contain 'addHelmPath'
        @($catalog.automations | ForEach-Object { $_.key }) | Should -Contain 'setGitHubUser'
        @($catalog.automations | ForEach-Object { $_.key }) | Should -Contain 'desktopLinkForThisApplication'
    }

    It 'each catalog entry has a scriptFile field' {
        $catalog = Read-AutomationCatalog -ProjectRoot $projectRoot
        foreach ($entry in @($catalog.automations)) {
            $entry.scriptFile | Should -Not -BeNullOrEmpty
            $entry.scriptFile | Should -Match '\.ps1$'
        }
    }

    It 'throws when catalog file is missing' {
        { Read-AutomationCatalog -ProjectRoot (Join-Path $env:TEMP 'nonexistent-path') } | Should -Throw '*Automation catalog not found*'
    }

    It 'throws when catalog has empty automations array' {
        $tempDir = Join-Path $env:TEMP 'dev-bootstrap-tests-automation' 'empty-catalog'
        $configDir = Join-Path $tempDir 'config'
        New-Item -Path $configDir -ItemType Directory -Force | Out-Null
        '{"automations": []}' | Set-Content -LiteralPath (Join-Path $configDir 'automation.catalog.json') -Encoding utf8

        { Read-AutomationCatalog -ProjectRoot $tempDir } | Should -Throw '*must define a non-empty*'
    }

    It 'throws when catalog entry is missing scriptFile' {
        $tempDir = Join-Path $env:TEMP 'dev-bootstrap-tests-automation' 'missing-scriptfile'
        $configDir = Join-Path $tempDir 'config'
        New-Item -Path $configDir -ItemType Directory -Force | Out-Null
        '{"automations": [{"key": "test", "name": "Test", "description": "Test entry"}]}' |
            Set-Content -LiteralPath (Join-Path $configDir 'automation.catalog.json') -Encoding utf8

        { Read-AutomationCatalog -ProjectRoot $tempDir } | Should -Throw '*missing required*scriptFile*'
    }

    It 'throws when scriptFile has non-.ps1 extension' {
        $tempDir = Join-Path $env:TEMP 'dev-bootstrap-tests-automation' 'bad-extension'
        $configDir = Join-Path $tempDir 'config'
        New-Item -Path $configDir -ItemType Directory -Force | Out-Null
        '{"automations": [{"key": "test", "name": "Test", "description": "Test", "scriptFile": "test.txt"}]}' |
            Set-Content -LiteralPath (Join-Path $configDir 'automation.catalog.json') -Encoding utf8

        { Read-AutomationCatalog -ProjectRoot $tempDir } | Should -Throw '*.ps1 extension*'
    }
}

# ── Script path resolution ──────────────────────────────────────────────────

Describe 'Script path resolution' {
    It 'all catalog scriptFile entries resolve to existing files' {
        $catalog = Read-AutomationCatalog -ProjectRoot $projectRoot
        $automationRoot = Join-Path $projectRoot 'src' 'automation'

        foreach ($entry in @($catalog.automations)) {
            $scriptPath = Join-Path $automationRoot $entry.scriptFile
            Test-Path -LiteralPath $scriptPath | Should -Be $true -Because "Script '$($entry.scriptFile)' for key '$($entry.key)' should exist"
        }
    }

    It 'launcher self-elevates before running dev-bootstrap' {
        $launcherPath = Join-Path $projectRoot 'dev-bootstrap-launcher.cmd'
        $launcherContent = Get-Content -LiteralPath $launcherPath -Raw

        $launcherContent | Should -Match "Start-Process -FilePath 'pwsh' -Verb RunAs"
        $launcherContent | Should -Match '-PauseBeforeExit'
        $launcherContent | Should -Not -Match '(?im)^pause\s*$'
    }
}

# ── Execution: happy path with mock script ──────────────────────────────────

Describe 'Invoke-Automation happy path' {
    It 'executes a mock automation script successfully' {
        $tempDir = Join-Path $env:TEMP 'dev-bootstrap-tests-automation' 'happy-path'
        $configDir = Join-Path $tempDir 'config'
        $automationDir = Join-Path $tempDir 'src' 'automation'
        New-Item -Path $configDir -ItemType Directory -Force | Out-Null
        New-Item -Path $automationDir -ItemType Directory -Force | Out-Null

        # Create catalog
        $catalog = @{
            automations = @(
                @{ key = 'mockScript'; name = 'Mock Script'; description = 'Test script'; scriptFile = 'Mock-Script.ps1' }
            )
        }
        $catalog | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $configDir 'automation.catalog.json') -Encoding utf8

        # Create mock script
        $mockScript = @'
param(
    [Parameter(Mandatory)][hashtable]$ModuleConfig,
    [Parameter(Mandatory)][string]$ProjectRoot
)
return @{ Status = 'UPDATED'; Message = 'Mock script executed successfully.' }
'@
        $mockScript | Set-Content -LiteralPath (Join-Path $automationDir 'Mock-Script.ps1') -Encoding utf8

        # Build config
        $config = Get-DefaultConfig
        $config.modules.automation.enabled = $true
        $config.modules.automation.catalog = @{ mockScript = $true }

        $results = @(Invoke-Automation -Config $config -ProjectRoot $tempDir)
        $results.Count | Should -Be 1
        $results[0].Status | Should -Be 'UPDATED'
        $results[0].Message | Should -Be 'Mock script executed successfully.'
    }

    It 'returns skipped when no automation item is enabled' {
        $config = Get-DefaultConfig
        $config.modules.automation.enabled = $true
        foreach ($key in @($config.modules.automation.catalog.Keys)) {
            $config.modules.automation.catalog[$key] = $false
        }

        $results = @(Invoke-Automation -Config $config -ProjectRoot $projectRoot)
        $results.Count | Should -Be 1
        $results[0].Status | Should -Be 'SKIPPED'
    }
}

# ── Error handling ──────────────────────────────────────────────────────────

Describe 'Invoke-Automation error handling' {
    It 'returns ERROR when script file is missing' {
        $tempDir = Join-Path $env:TEMP 'dev-bootstrap-tests-automation' 'missing-script'
        $configDir = Join-Path $tempDir 'config'
        $automationDir = Join-Path $tempDir 'src' 'automation'
        New-Item -Path $configDir -ItemType Directory -Force | Out-Null
        New-Item -Path $automationDir -ItemType Directory -Force | Out-Null

        $catalog = @{
            automations = @(
                @{ key = 'missing'; name = 'Missing Script'; description = 'Test'; scriptFile = 'Does-Not-Exist.ps1' }
            )
        }
        $catalog | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $configDir 'automation.catalog.json') -Encoding utf8

        $config = Get-DefaultConfig
        $config.modules.automation.enabled = $true
        $config.modules.automation.catalog = @{ missing = $true }

        $results = @(Invoke-Automation -Config $config -ProjectRoot $tempDir)
        $results.Count | Should -Be 1
        $results[0].Status | Should -Be 'ERROR'
        $results[0].Message | Should -Match 'not found'
    }

    It 'returns ERROR when scriptFile has wrong extension' {
        $tempDir = Join-Path $env:TEMP 'dev-bootstrap-tests-automation' 'wrong-ext'
        $configDir = Join-Path $tempDir 'config'
        $automationDir = Join-Path $tempDir 'src' 'automation'
        New-Item -Path $configDir -ItemType Directory -Force | Out-Null
        New-Item -Path $automationDir -ItemType Directory -Force | Out-Null

        # Manually write a catalog with bad extension (bypass Read-AutomationCatalog validation)
        $catalogJson = '{"automations": [{"key": "badext", "name": "Bad Ext", "description": "Test", "scriptFile": "bad.ps1"}]}'
        $catalogJson | Set-Content -LiteralPath (Join-Path $configDir 'automation.catalog.json') -Encoding utf8

        # Now patch the catalog in memory to circumvent the catalog validation
        # We test the runner directly by creating a catalog entry with wrong extension
        $config = Get-DefaultConfig
        $config.modules.automation.enabled = $true
        $config.modules.automation.catalog = @{ badext = $true }

        # Overwrite catalog with .txt extension (this won't pass Read-AutomationCatalog so we mock it)
        Mock Read-AutomationCatalog {
            return @{
                automations = @(
                    @{ key = 'badext'; name = 'Bad Ext'; description = 'Test'; scriptFile = 'script.txt' }
                )
            }
        }

        $results = @(Invoke-Automation -Config $config -ProjectRoot $tempDir)
        $results.Count | Should -Be 1
        $results[0].Status | Should -Be 'ERROR'
        $results[0].Message | Should -Match '.ps1 extension'
    }

    It 'returns ERROR when script exits with non-zero code' {
        $tempDir = Join-Path $env:TEMP 'dev-bootstrap-tests-automation' 'exit-code'
        $configDir = Join-Path $tempDir 'config'
        $automationDir = Join-Path $tempDir 'src' 'automation'
        New-Item -Path $configDir -ItemType Directory -Force | Out-Null
        New-Item -Path $automationDir -ItemType Directory -Force | Out-Null

        $catalog = @{
            automations = @(
                @{ key = 'failScript'; name = 'Fail Script'; description = 'Test'; scriptFile = 'Fail-Script.ps1' }
            )
        }
        $catalog | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $configDir 'automation.catalog.json') -Encoding utf8

        # Script that sets a non-zero exit code and still returns a payload.
        $failScript = @'
param(
    [Parameter(Mandatory)][hashtable]$ModuleConfig,
    [Parameter(Mandatory)][string]$ProjectRoot
)
    $global:LASTEXITCODE = 9
    return @{ Status = 'UPDATED'; Message = 'This should be overridden by exit-code handling.' }
'@
        $failScript | Set-Content -LiteralPath (Join-Path $automationDir 'Fail-Script.ps1') -Encoding utf8

        $config = Get-DefaultConfig
        $config.modules.automation.enabled = $true
        $config.modules.automation.catalog = @{ failScript = $true }

        $results = @(Invoke-Automation -Config $config -ProjectRoot $tempDir)
        $results.Count | Should -Be 1
        $results[0].Status | Should -Be 'ERROR'
        $results[0].Message | Should -Match 'exit code 9'
    }

    It 'returns SKIPPED when catalog key is unknown' {
        $config = Get-DefaultConfig
        $config.modules.automation.enabled = $true
        $config.modules.automation.catalog = @{ unknownKey = $true }

        $results = @(Invoke-Automation -Config $config -ProjectRoot $projectRoot)
        $results.Count | Should -Be 1
        $results[0].Status | Should -Be 'SKIPPED'
        $results[0].Message | Should -Match 'not found in automation catalog'
    }

    It 'returns ERROR when scriptFile field is empty in catalog entry' {
        $config = Get-DefaultConfig
        $config.modules.automation.enabled = $true
        $config.modules.automation.catalog = @{ emptyScript = $true }

        Mock Read-AutomationCatalog {
            return @{
                automations = @(
                    @{ key = 'emptyScript'; name = 'Empty Script'; description = 'Test'; scriptFile = '' }
                )
            }
        }

        $results = @(Invoke-Automation -Config $config -ProjectRoot $projectRoot)
        $results.Count | Should -Be 1
        $results[0].Status | Should -Be 'ERROR'
        $results[0].Message | Should -Match 'missing required.*scriptFile'
    }
}

# ── Backward compatibility: config migration ────────────────────────────────

Describe 'ConvertTo-AutomationModuleConfig' {
    It 'migrates legacy configurations key to automation' {
        $config = @{
            modules = @{
                configurations = @{
                    enabled = $true
                    catalog = @{ addMakePath = $true }
                    gitHubUser = @{ name = 'Test'; email = 'test@test.com' }
                }
            }
        }

        $migrated = ConvertTo-AutomationModuleConfig -Config $config
        $migrated.modules.ContainsKey('automation') | Should -Be $true
        $migrated.modules.ContainsKey('configurations') | Should -Be $false
        $migrated.modules.automation.enabled | Should -Be $true
        $migrated.modules.automation.catalog.addMakePath | Should -Be $true
    }

    It 'does not migrate when automation key already exists' {
        $config = @{
            modules = @{
                configurations = @{ enabled = $false }
                automation = @{ enabled = $true; catalog = @{ test = $true } }
            }
        }

        $migrated = ConvertTo-AutomationModuleConfig -Config $config
        $migrated.modules.automation.enabled | Should -Be $true
        $migrated.modules.ContainsKey('configurations') | Should -Be $true
    }

    It 'handles config without modules key' {
        $config = @{ general = @{ logDirectory = 'log' } }
        $migrated = ConvertTo-AutomationModuleConfig -Config $config
        $migrated.ContainsKey('modules') | Should -Be $false
    }
}

# ── GitHubUser validation via automation scripts ────────────────────────────

Describe 'Set-ConfigurationGitHubUser script' {
    It 'returns error when gitHubUser values are missing' {
        $scriptPath = Join-Path $projectRoot 'src' 'automation' 'Set-ConfigurationGitHubUser.ps1'
        $moduleConfig = @{
            gitHubUser = @{ name = ''; email = '' }
        }

        $result = & $scriptPath -ModuleConfig $moduleConfig -ProjectRoot $projectRoot
        $result.Status | Should -Be 'ERROR'
    }
}

AfterAll {
    $testRoot = Join-Path $env:TEMP 'dev-bootstrap-tests-automation'
    if (Test-Path $testRoot) {
        Remove-Item -Path $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
