#Requires -Version 7.0
# Copyright (c) 2026 POMINI Long Rolling Mills. Licensed under the MIT License.
<#
.SYNOPSIS
    Application installation module.
.DESCRIPTION
    Installs required and optional applications in an idempotent way.
    Windows: winget.
    Linux: apt/dnf/yum/zypper.
    Module-required apps: managed automatically from enabled modules.
    Optional system apps: selected through config booleans.
#>

function Invoke-AppInstaller {
    <#
    .SYNOPSIS
        Installs required and selected applications for the current platform.
    .PARAMETER Config
        Resolved dev-bootstrap configuration hashtable.
    .PARAMETER ProjectRoot
        Repository root path used to resolve catalogs and resources.
    .PARAMETER Force
        Enables forced reinstall/upgrade behavior where supported.
    .OUTPUTS
        System.Collections.Generic.List[hashtable]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [string]$ProjectRoot,
        [switch]$Force
    )

    $moduleConfig = $Config.modules.appInstaller
    $results = [System.Collections.Generic.List[hashtable]]::new()
    $platform = Get-OSPlatform
    $catalog = Read-AppInstallerCatalog -ProjectRoot $ProjectRoot

    Write-Log -Level Info -Message "AppInstaller platform: $platform"

    if ($platform -eq 'macOS') {
        Write-Log -Level Warning -Message 'macOS is not currently supported by AppInstaller. Skipping.'
        foreach ($app in (Get-EffectiveAppList -Config $Config -Catalog $catalog)) {
            $results.Add((New-ReportEntry -Module 'AppInstaller' -Item $app.name -Status 'SKIPPED' -Message 'Unsupported platform: macOS'))
        }
        return $results
    }

    $packageManager = if ($platform -eq 'Windows') { Get-WindowsPackageManager } else { Get-LinuxPackageManager }
    if (-not $packageManager) {
        Write-Log -Level Error -Message "No supported package manager detected on $platform."
        foreach ($app in (Get-EffectiveAppList -Config $Config -Catalog $catalog)) {
            $results.Add((New-ReportEntry -Module 'AppInstaller' -Item $app.name -Status 'ERROR' -Message 'Package manager not available'))
        }
        return $results
    }

    if ($platform -eq 'Windows') {
        $packageManager = Get-PreferredWindowsPackageManager -Current $packageManager
        if ($packageManager.Name -eq 'winget') {
            Invoke-WingetGlobalRefresh
        }
    }

    $effectiveApps = Get-EffectiveAppList -Config $Config -Catalog $catalog
    $missingSelectedApps = Get-MissingSelectedNonRequiredAppKeys -AppInstallerConfig $moduleConfig -Catalog $catalog

    foreach ($missingKey in $missingSelectedApps) {
        $message = "Requested app '$missingKey' is no longer available in the catalog."
        Write-Log -Level Warning -Message $message
        $results.Add((New-ReportEntry -Module 'AppInstaller' -Item $missingKey -Status 'SKIPPED' -Message $message))
    }

    $forceInstall = $Force.IsPresent -or $moduleConfig.force -or $Config.general.force
    $currentGroup = ''

    foreach ($app in $effectiveApps) {
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $groupName = Get-AppInstallGroupName -App $app
            if ($groupName -ne $currentGroup) {
                $currentGroup = $groupName
                Write-Log -Level Info -Message ''
                Write-Log -Level Info -Message "Starting app group install: $groupName"
            }

            if (-not (Test-AppSupportedOnPlatform -App $app -Platform $platform)) {
                $timer.Stop()
                $results.Add((New-ReportEntry -Module 'AppInstaller' -Item $app.name -Status 'SKIPPED' -Message "Unsupported for platform: $platform" -Duration $timer.Elapsed))
                continue
            }

            Write-Log -Level Info -Message "Processing application: $($app.name)"
            $result = if ($platform -eq 'Windows') {
                Install-WindowsApp -App $app -PackageManager $packageManager -Force:$forceInstall
            }
            else {
                Install-LinuxApp -App $app -PackageManager $packageManager -Force:$forceInstall
            }

            $timer.Stop()
            $entry = New-ReportEntry -Module 'AppInstaller' -Item $app.name -Status $result.Status -Message $result.Message -Duration $timer.Elapsed
            $results.Add($entry)
            Write-AppInstallerEntryLog -Entry $entry
        }
        catch {
            $timer.Stop()
            Write-Log -Level Error -Message "Application install failed for '$($app.name)': $_"
            $entry = New-ReportEntry -Module 'AppInstaller' -Item $app.name -Status 'ERROR' -Message "$_" -Duration $timer.Elapsed
            $results.Add($entry)
            Write-AppInstallerEntryLog -Entry $entry
        }
    }

    return $results
}

function Read-AppInstallerCatalog {
    [CmdletBinding()]
    param([string]$ProjectRoot)

    $candidateRoots = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $candidateRoots.Add($ProjectRoot)
    }

    $defaultProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    if (-not $candidateRoots.Contains($defaultProjectRoot)) {
        $candidateRoots.Add($defaultProjectRoot)
    }

    $catalogPath = $null
    foreach ($root in $candidateRoots) {
        $candidate = Join-Path $root 'config' 'appinstaller.catalog.json'
        if (Test-Path -LiteralPath $candidate) {
            $catalogPath = $candidate
            break
        }
    }

    if (-not $catalogPath) {
        throw 'AppInstaller catalog not found. Expected config/appinstaller.catalog.json.'
    }

    try {
        $raw = Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8
        $catalog = $raw | ConvertFrom-Json -AsHashtable -Depth 30
    }
    catch {
        throw "Invalid AppInstaller catalog JSON at '$catalogPath': $_"
    }

    if (-not $catalog.ContainsKey('apps') -or @($catalog.apps).Count -eq 0) {
        throw "AppInstaller catalog '$catalogPath' must define a non-empty 'apps' array."
    }

    if (-not $catalog.ContainsKey('requiredByModule')) {
        throw "AppInstaller catalog '$catalogPath' must define 'requiredByModule'."
    }

    return $catalog
}

function Get-EffectiveAppList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$Catalog
    )

    $appInstaller = $Config.modules.appInstaller
    $sourceApps = @($Catalog.apps)
    $requiredMap = $Catalog.requiredByModule

    $enabledModuleNames = @($Config.modules.Keys | Where-Object { $_ -ne 'appInstaller' -and $Config.modules[$_].enabled })
    $requiredKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    if ($requiredMap.ContainsKey('general')) {
        foreach ($key in @($requiredMap.general)) {
            if (-not [string]::IsNullOrWhiteSpace($key)) {
                $requiredKeys.Add($key) | Out-Null
            }
        }
    }
    else {
        # Backward-compatibility fallback for older catalogs.
        $requiredKeys.Add('powershell7') | Out-Null
    }

    foreach ($moduleName in $enabledModuleNames) {
        if ($requiredMap.ContainsKey($moduleName)) {
            foreach ($key in @($requiredMap[$moduleName])) {
                if (-not [string]::IsNullOrWhiteSpace($key)) {
                    $requiredKeys.Add($key) | Out-Null
                }
            }
        }
    }

    $selectedNonRequiredKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($key in Get-SelectedNonRequiredAppKeys -AppInstallerConfig $appInstaller) {
        $selectedNonRequiredKeys.Add($key) | Out-Null
    }

    $allByKey = @{}
    foreach ($app in $sourceApps) {
        if ($app.key) {
            $allByKey[$app.key] = $app
        }
    }

    # Ensure required apps are always present.
    foreach ($requiredKey in $requiredKeys) {
        if (-not $allByKey.ContainsKey($requiredKey)) {
            throw "Required application key '$requiredKey' is not defined in appinstaller catalog."
        }
    }

    $selectedKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $requiredKeys) {
        $selectedKeys.Add($key) | Out-Null
    }
    foreach ($key in $selectedNonRequiredKeys) {
        $selectedKeys.Add($key) | Out-Null
    }

    $ordered = [System.Collections.Generic.List[hashtable]]::new()

    # Preserve catalog order for deterministic output.
    foreach ($app in $sourceApps) {
        $key = if ($app.key) { $app.key } else { $app.name }
        if ($selectedKeys.Contains($key)) {
            $ordered.Add($app)
        }
    }

    return $ordered
}

function Get-SelectedNonRequiredAppKeys {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$AppInstallerConfig)

    $keys = [System.Collections.Generic.List[string]]::new()

    if ($AppInstallerConfig.ContainsKey('recommendedApps') -and $null -ne $AppInstallerConfig.recommendedApps) {
        foreach ($key in $AppInstallerConfig.recommendedApps.Keys) {
            if ([bool]$AppInstallerConfig.recommendedApps[$key]) {
                $keys.Add([string]$key)
            }
        }
    }

    if ($AppInstallerConfig.ContainsKey('optionalApps') -and $null -ne $AppInstallerConfig.optionalApps) {
        foreach ($key in $AppInstallerConfig.optionalApps.Keys) {
            if ([bool]$AppInstallerConfig.optionalApps[$key]) {
                $keys.Add([string]$key)
            }
        }
    }

    return @($keys | Sort-Object -Unique)
}

function Get-MissingSelectedNonRequiredAppKeys {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$AppInstallerConfig,
        [Parameter(Mandatory)][hashtable]$Catalog
    )

    $catalogKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($app in @($Catalog.apps)) {
        if ($app.key) {
            $catalogKeys.Add([string]$app.key) | Out-Null
        }
    }

    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($key in Get-SelectedNonRequiredAppKeys -AppInstallerConfig $AppInstallerConfig) {
        if (-not $catalogKeys.Contains([string]$key)) {
            $missing.Add([string]$key)
        }
    }

    return @($missing | Sort-Object -Unique)
}

function Test-AppSupportedOnPlatform {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$App,
        [Parameter(Mandatory)][string]$Platform
    )

    if (-not $App.ContainsKey('supportedPlatforms') -or $null -eq $App.supportedPlatforms -or @($App.supportedPlatforms).Count -eq 0) {
        return $true
    }

    return $Platform -in @($App.supportedPlatforms)
}

function Get-AppInstallGroupName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$App)

    $category = [string]$App.category
    if ([string]::IsNullOrWhiteSpace($category)) {
        return 'optional'
    }

    switch ($category.ToLowerInvariant()) {
        'required' { return 'required' }
        'recommended' { return 'recommended' }
        'optional' { return 'optional' }
        default { return 'optional' }
    }
}

function Install-WindowsApp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$App,
        [Parameter(Mandatory)][hashtable]$PackageManager,
        [switch]$Force
    )

    if ($PackageManager.Name -eq 'winget') {
        return (Install-ViaWinget -App $App -Force:$Force)
    }

    return @{ Status = 'ERROR'; Message = "Unsupported package manager: $($PackageManager.Name)" }
}

function Invoke-PostInstallHooks {
    <#
    .SYNOPSIS
        Executes post-installation hooks for specific applications.

    .DESCRIPTION
        After successful installation of certain applications, run platform-specific configuration tasks:
        - VSCode: Add context menu entries to Windows registry
        - git, nvm, docker, etc.: Refresh environment variables from system registry

    .PARAMETER App
        The application hashtable from the catalog.

    .PARAMETER Status
        Installation status (INSTALLED, DEFERRED, etc.). Hooks only run on INSTALLED.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$App,
        [string]$Status = 'INSTALLED'
    )

    if ($Status -ne 'INSTALLED' -and $Status -ne 'UPDATED') {
        return
    }

    $appKey = [string]$App.key

    # Apps that modify PATH or environment variables: refresh system environment
    $pathModifyingApps = @('git', 'nvmWindows', 'python31012', 'python3123', 'python3', 'pythonLatest', 'docker', 'azure-cli', 'powershell7')
    if ($appKey -in $pathModifyingApps) {
        Write-Log -Level Debug -Message "Syncing environment variables after installing '$($App.name)'..."
        Sync-EnvironmentVariablesFromSystem
    }

    # VSCode: add context menu entries
    if ($appKey -eq 'vscode') {
        Write-Log -Level Debug -Message "Adding VSCode context menu entries..."
        Add-VSCodeContextMenu
    }
}

function Install-WindowsApp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$App,
        [Parameter(Mandatory)][hashtable]$PackageManager,
        [switch]$Force
    )

    if ($PackageManager.Name -eq 'winget') {
        return (Install-ViaWinget -App $App -Force:$Force)
    }

    return @{ Status = 'ERROR'; Message = "Unsupported package manager: $($PackageManager.Name)" }
}

function Install-ViaWinget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$App,
        [switch]$Force
    )

    $appId = $App.wingetId
    if (-not $appId) {
        return @{ Status = 'SKIPPED'; Message = 'wingetId not configured' }
    }

    $wingetSource = Get-WingetSourceForApp -App $App

    $versionInfo = Get-WindowsAppVersionInfo -App $App
    Write-Log -Level Info -Message "  $(Format-VersionCheckLogMessage -VersionInfo $versionInfo)"
    $isInstalled = $versionInfo.IsInstalled

    if ($isInstalled) {
        if (Test-ShouldDeferPowerShellSelfUpgrade -App $App -VersionInfo $versionInfo) {
            $current = [string]$versionInfo.CurrentVersion
            $latest = [string]$versionInfo.LatestVersion
            $queued = Add-DeferredPowerShellUpgradeAction
            $nextStep = if ($queued) {
                'Upgrade deferred and queued. You will be prompted after the main run to start it in a new window.'
            }
            else {
                "Upgrade deferred. Run 'winget upgrade --id Microsoft.PowerShell --exact --accept-source-agreements --accept-package-agreements' after this run."
            }

            $msg = "PowerShell update deferred (running in current pwsh session). Current = $current, Latest = $latest. $nextStep"
            Write-Log -Level Warning -Message "  $msg"
            $deferredVersionInfo = ConvertTo-AlreadyPresentVersionInfo -VersionInfo $versionInfo
            return @{ Status = 'DEFERRED'; Message = $msg; VersionInfo = $deferredVersionInfo }
        }

        $currentVer = [string]$versionInfo.CurrentVersion
        $latestVer = [string]$versionInfo.LatestVersion
        if (-not [string]::IsNullOrWhiteSpace($currentVer) -and -not [string]::IsNullOrWhiteSpace($latestVer) -and -not (Test-ShouldUpgradeInstalledApp -VersionInfo $versionInfo)) {
            $existingVersionInfo = ConvertTo-AlreadyPresentVersionInfo -VersionInfo $versionInfo
            return @{ Status = 'ALREADY_PRESENT'; Message = (Format-WingetVersionMessage -BaseMessage 'Already up to date (winget)' -VersionInfo $existingVersionInfo) }
        }

        Write-ConsoleStatus -Message "  Upgrading $($App.name) via winget (this may take several minutes)..."
        $upgradeResult = Invoke-WingetUpgradeWithRetry -App $App -AppId $appId -WingetSource $wingetSource
        if ($upgradeResult.ExitCode -eq 0) {
            $postVersionInfo = Get-WingetVersionInfo -AppId $appId
            Invoke-PostInstallHooks -App $App -Status 'UPDATED'
            return @{ Status = 'INSTALLED'; Message = (Format-WingetVersionMessage -BaseMessage 'Upgraded via winget' -VersionInfo $postVersionInfo) }
        }

        if (Test-WingetNoUpgradeAvailableOutput -Output $upgradeResult.Output) {
            $existingVersionInfo = ConvertTo-AlreadyPresentVersionInfo -VersionInfo (Get-WindowsAppVersionInfo -App $App)
            return @{ Status = 'ALREADY_PRESENT'; Message = (Format-WingetVersionMessage -BaseMessage 'Already up to date (winget)' -VersionInfo $existingVersionInfo) }
        }

        if (Test-WingetAlreadyInstalledOutput -Output $upgradeResult.Output) {
            $existingVersionInfo = ConvertTo-AlreadyPresentVersionInfo -VersionInfo (Get-WindowsAppVersionInfo -App $App)
            return @{ Status = 'ALREADY_PRESENT'; Message = (Format-WingetVersionMessage -BaseMessage 'Already installed (winget)' -VersionInfo $existingVersionInfo) }
        }

        if (Test-WingetLegacyInkscapeConflict -App $App -ExitCode $upgradeResult.ExitCode -Output $upgradeResult.Output) {
            return @{ Status = 'ERROR'; Message = (Get-WingetLegacyInkscapeConflictMessage -VersionInfo $versionInfo) }
        }

        return @{ Status = 'ERROR'; Message = (Get-WingetFailureMessage -Operation 'upgrade' -ExitCode $upgradeResult.ExitCode -Output $upgradeResult.Output -VersionInfo $versionInfo) }
    }

    Write-ConsoleStatus -Message "  Installing $($App.name) via winget (this may take several minutes)..."
    $installResult = Invoke-WingetInstallWithRetry -App $App -AppId $appId -WingetSource $wingetSource
    if ($installResult.ExitCode -eq 0) {
        $postVersionInfo = Get-WingetVersionInfo -AppId $appId
        Invoke-PostInstallHooks -App $App -Status 'INSTALLED'
        return @{ Status = 'INSTALLED'; Message = (Format-WingetVersionMessage -BaseMessage 'Installed via winget' -VersionInfo $postVersionInfo) }
    }

    $fallbackId = Get-WingetFallbackId -App $App
    if (-not [string]::IsNullOrWhiteSpace($fallbackId) -and (Test-WingetPackageNotFoundOutput -ExitCode $installResult.ExitCode -Output $installResult.Output)) {
        Write-Log -Level Warning -Message "Package '$appId' not found in source '$wingetSource'. Retrying with fallback id '$fallbackId'."
        Write-ConsoleStatus -Message "  Installing $($App.name) via winget fallback id (this may take several minutes)..."
        $fallbackResult = Invoke-WingetInstallWithRetry -App $App -AppId $fallbackId -WingetSource $wingetSource
        if ($fallbackResult.ExitCode -eq 0) {
            $postVersionInfo = Get-WingetVersionInfo -AppId $fallbackId
            Invoke-PostInstallHooks -App $App -Status 'INSTALLED'
            return @{ Status = 'INSTALLED'; Message = (Format-WingetVersionMessage -BaseMessage 'Installed via winget (fallback id)' -VersionInfo $postVersionInfo) }
        }

        $installResult = $fallbackResult
        $appId = $fallbackId
    }

    if (Test-WingetAlreadyInstalledOutput -Output $installResult.Output) {
        $existingVersionInfo = ConvertTo-AlreadyPresentVersionInfo -VersionInfo (Get-WindowsAppVersionInfo -App $App)

        Write-ConsoleStatus -Message "  Upgrading $($App.name) via winget (this may take several minutes)..."
        $upgradeResult = Invoke-WingetUpgradeWithRetry -App $App -AppId $appId -WingetSource $wingetSource
        if ($upgradeResult.ExitCode -eq 0) {
            $postVersionInfo = Get-WingetVersionInfo -AppId $appId
            Invoke-PostInstallHooks -App $App -Status 'UPDATED'
            return @{ Status = 'INSTALLED'; Message = (Format-WingetVersionMessage -BaseMessage 'Upgraded via winget' -VersionInfo $postVersionInfo) }
        }

        if (Test-WingetNoUpgradeAvailableOutput -Output $upgradeResult.Output) {
            return @{ Status = 'ALREADY_PRESENT'; Message = (Format-WingetVersionMessage -BaseMessage 'Already up to date (winget)' -VersionInfo $existingVersionInfo) }
        }

        if (-not (Test-WingetAlreadyInstalledOutput -Output $upgradeResult.Output)) {
            if (Test-WingetLegacyInkscapeConflict -App $App -ExitCode $upgradeResult.ExitCode -Output $upgradeResult.Output) {
                return @{ Status = 'ERROR'; Message = (Get-WingetLegacyInkscapeConflictMessage -VersionInfo $existingVersionInfo) }
            }

            return @{ Status = 'ERROR'; Message = (Get-WingetFailureMessage -Operation 'upgrade' -ExitCode $upgradeResult.ExitCode -Output $upgradeResult.Output -VersionInfo $existingVersionInfo) }
        }

        return @{ Status = 'ALREADY_PRESENT'; Message = (Format-WingetVersionMessage -BaseMessage 'Already installed (winget)' -VersionInfo $existingVersionInfo) }
    }

    if (Test-WingetLegacyInkscapeConflict -App $App -ExitCode $installResult.ExitCode -Output $installResult.Output) {
        return @{ Status = 'ERROR'; Message = (Get-WingetLegacyInkscapeConflictMessage -VersionInfo $versionInfo) }
    }

    return @{ Status = 'ERROR'; Message = (Get-WingetFailureMessage -Operation 'install' -ExitCode $installResult.ExitCode -Output $installResult.Output -VersionInfo $versionInfo) }
}

function Get-WingetSourceForApp {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$App)

    if (-not $App.ContainsKey('wingetSource') -or $null -eq $App.wingetSource) {
        return 'winget'
    }

    $source = [string]$App.wingetSource
    if ([string]::IsNullOrWhiteSpace($source)) {
        return 'winget'
    }

    return $source.Trim().ToLowerInvariant()
}

function Add-DeferredPowerShellUpgradeAction {
    [CmdletBinding()]
    param()

    if (-not (Test-DeferredPowerShellUpgradeEnvironment)) {
        return $false
    }

    $upgradeCommand = 'winget upgrade --id Microsoft.PowerShell --exact --accept-source-agreements --accept-package-agreements'
    return (Add-DeferredAction -Key 'upgrade-powershell7' -Title 'PowerShell 7 upgrade' -Command $upgradeCommand)
}

function Test-DeferredPowerShellUpgradeEnvironment {
    [CmdletBinding()]
    param()

    if (-not (Test-IsWindows)) {
        return $false
    }

    if (-not [System.Environment]::UserInteractive) {
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$env:CI)) {
        return $false
    }

    $callStack = @(Get-PSCallStack | ForEach-Object { [string]$_.Command })
    if ($callStack -contains 'Invoke-Pester') {
        return $false
    }

    return $true
}

function Test-ShouldDeferPowerShellSelfUpgrade {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$App,
        [Parameter(Mandatory)][hashtable]$VersionInfo
    )

    # Upgrading Microsoft.PowerShell from the same running pwsh session can terminate the host process.
    if (-not ($IsWindows)) {
        return $false
    }

    $appKey = [string]$App.key
    $wingetId = [string]$App.wingetId
    if ($appKey -ne 'powershell7' -and $wingetId -ne 'Microsoft.PowerShell') {
        return $false
    }

    if (-not $VersionInfo.IsInstalled) {
        return $false
    }

    $current = [string]$VersionInfo.CurrentVersion
    $latest = [string]$VersionInfo.LatestVersion

    if ([string]::IsNullOrWhiteSpace($current) -or [string]::IsNullOrWhiteSpace($latest)) {
        return $false
    }

    # Defer only when a genuinely newer version is available. When the installed
    # build is the same as or newer than the source metadata, no upgrade is needed.
    return (Test-ShouldUpgradeInstalledApp -VersionInfo $VersionInfo)
}

function Get-WingetFallbackId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$App)

    if ($App.ContainsKey('wingetFallbackId') -and -not [string]::IsNullOrWhiteSpace([string]$App.wingetFallbackId)) {
        return [string]$App.wingetFallbackId
    }

    return ''
}

function Test-WingetPackageNotFoundOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][object[]]$Output
    )

    $hexCode = (Convert-WingetExitCodeToHex -ExitCode $ExitCode).ToUpperInvariant()
    if ($hexCode -eq '0X8A150014') {
        return $true
    }

    $text = (@($Output) -join "`n").ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $false
    }

    return (
        $text -match 'no package found matching' -or
        $text -match 'nessun pacchetto trovato'
    )
}

function Invoke-WingetGlobalRefresh {
    [CmdletBinding()]
    param()

    Write-Log -Level Info -Message 'Refreshing winget package sources...'
    $sourceOutput = & winget source update 2>&1
    $sourceExit = $LASTEXITCODE
    foreach ($line in @($sourceOutput)) {
        $text = ConvertTo-NormalizedWingetOutput -Text ([string]$line)
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            # Raw winget output follows the OS display language; keep it at Debug level only.
            Write-Log -Level Debug -Message "  [source update] $text"
        }
    }
    Write-Log -Level Info -Message "Winget package sources refreshed (exit code $sourceExit)."

    Write-Log -Level Info -Message 'Checking for available winget upgrades...'
    $upgradeOutput = & winget upgrade --accept-source-agreements --disable-interactivity 2>&1
    $upgradeExit = $LASTEXITCODE
    foreach ($line in @($upgradeOutput)) {
        $text = ConvertTo-NormalizedWingetOutput -Text ([string]$line)
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            # Raw winget output follows the OS display language; keep it at Debug level only.
            Write-Log -Level Debug -Message "  [upgrade] $text"
        }
    }
    Write-Log -Level Info -Message "Winget upgrade check completed (exit code $upgradeExit)."
}

function Get-WingetInstallArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$App,
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][string]$WingetSource
    )

    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @(
            'install',
            '--id', $AppId,
            '--exact',
            '--source', $WingetSource,
            '--accept-source-agreements',
            '--accept-package-agreements',
            '--disable-interactivity',
            '--silent')) {
        $arguments.Add($argument)
    }

    $override = ''
    if ($App.ContainsKey('wingetInstallOverride') -and $null -ne $App.wingetInstallOverride) {
        $override = [string]$App.wingetInstallOverride
    }

    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $arguments.Add('--override')
        $arguments.Add($override)
    }

    return @($arguments)
}

function Invoke-WingetInstallWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$App,
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][string]$WingetSource
    )

    $wingetArguments = Get-WingetInstallArguments -App $App -AppId $AppId -WingetSource $WingetSource
    $output = & winget @wingetArguments 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0 -and (Test-WingetAppInUseOutput -Output $output)) {
        $closed = Stop-AppProcessesForInstall -App $App
        if ($closed) {
            Write-Log -Level Warning -Message "Detected running process for '$($App.name)'. Retrying winget install after stopping app."
            $output = & winget @wingetArguments 2>&1
            $exitCode = $LASTEXITCODE
        }
    }

    return @{ ExitCode = $exitCode; Output = @($output) }
}

function Invoke-WingetUpgradeWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$App,
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][string]$WingetSource
    )

    $output = & winget upgrade --id $AppId --exact --source $WingetSource --accept-source-agreements --accept-package-agreements --disable-interactivity --silent 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0 -and (Test-WingetAppInUseOutput -Output $output)) {
        $closed = Stop-AppProcessesForInstall -App $App
        if ($closed) {
            Write-Log -Level Warning -Message "Detected running process for '$($App.name)'. Retrying winget upgrade after stopping app."
            $output = & winget upgrade --id $AppId --exact --source $WingetSource --accept-source-agreements --accept-package-agreements --disable-interactivity --silent 2>&1
            $exitCode = $LASTEXITCODE
        }
    }

    return @{ ExitCode = $exitCode; Output = @($output) }
}

function Get-WingetVersionInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AppId)

    $default = @{
        IsInstalled = $false
        CurrentVersion = ''
        LatestVersion = ''
    }

    try {
        $targetedListOutput = & winget list --id $AppId --exact --accept-source-agreements --disable-interactivity 2>&1
        if ($LASTEXITCODE -eq 0) {
            foreach ($line in @($targetedListOutput)) {
                $lineText = [string]$line
                if ([string]::IsNullOrWhiteSpace($lineText)) {
                    continue
                }

                $parsed = Convert-WingetListLineToVersionInfo -Line $lineText -AppId $AppId
                if ($parsed.IsInstalled) {
                    if ([string]::IsNullOrWhiteSpace([string]$parsed.LatestVersion)) {
                        $latestFallback = Get-WingetLatestAvailableVersion -AppId $AppId
                        if (-not [string]::IsNullOrWhiteSpace($latestFallback)) {
                            $parsed.LatestVersion = $latestFallback
                        }
                    }
                    return $parsed
                }
            }
        }

        $listOutput = & winget list --accept-source-agreements --disable-interactivity 2>&1
        if ($LASTEXITCODE -ne 0) {
            $latestFallback = Get-WingetLatestAvailableVersion -AppId $AppId
            if (-not [string]::IsNullOrWhiteSpace($latestFallback)) {
                $default.LatestVersion = $latestFallback
            }
            return $default
        }

        foreach ($line in @($listOutput)) {
            $lineText = [string]$line
            if ([string]::IsNullOrWhiteSpace($lineText)) {
                continue
            }

            $parsed = Convert-WingetListLineToVersionInfo -Line $lineText -AppId $AppId
            if ($parsed.IsInstalled) {
                if ([string]::IsNullOrWhiteSpace([string]$parsed.LatestVersion)) {
                    $latestFallback = Get-WingetLatestAvailableVersion -AppId $AppId
                    if (-not [string]::IsNullOrWhiteSpace($latestFallback)) {
                        $parsed.LatestVersion = $latestFallback
                    }
                }
                return $parsed
            }
        }

        $latestFallback = Get-WingetLatestAvailableVersion -AppId $AppId
        if (-not [string]::IsNullOrWhiteSpace($latestFallback)) {
            $default.LatestVersion = $latestFallback
        }
    }
    catch {
        Write-Log -Level Debug -Message "Unable to read winget version info for '$AppId': $_"
    }

    return $default
}

function Convert-WingetListLineToVersionInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Line,
        [Parameter(Mandatory)][string]$AppId
    )

    $default = @{
        IsInstalled = $false
        CurrentVersion = ''
        LatestVersion = ''
    }

    $cleanLine = ConvertTo-NormalizedWingetOutput -Text $Line

    if ([string]::IsNullOrWhiteSpace($cleanLine) -or $cleanLine -notmatch [regex]::Escape($AppId)) {
        if ($AppId -eq 'Notepad++.Notepad++' -and $cleanLine -match '(?i)notepad\+\+' -and $cleanLine -match '(?i)notepad\+\+.*?([0-9]+\.[0-9]+(?:\.[0-9]+)?)') {
            return @{
                IsInstalled = $true
                CurrentVersion = ([string]$Matches[1]).Trim()
                LatestVersion = ''
            }
        }
        return $default
    }

    $normalized = ($cleanLine -replace '\s{2,}', '|').Trim('|').Trim()
    $parts = @($normalized.Split('|') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if ($parts.Count -lt 2) {
        $escapedAppId = [regex]::Escape($AppId)
        if ($cleanLine -match "(?i)$escapedAppId\s+([0-9][^\s]*)") {
            return @{
                IsInstalled = $true
                CurrentVersion = ([string]$Matches[1]).Trim()
                LatestVersion = ''
            }
        }

        return $default
    }

    if (($parts[0] -match '^(Name|Nome)$') -or ($parts[0] -match '^-+$')) {
        return $default
    }
    $idIndex = [Array]::IndexOf($parts, $AppId)

    if ($idIndex -lt 0 -or ($idIndex + 1) -ge $parts.Count) {
        $escapedAppId = [regex]::Escape($AppId)
        if ($cleanLine -match "(?i)$escapedAppId\s+([0-9][^\s]*)") {
            return @{
                IsInstalled = $true
                CurrentVersion = ([string]$Matches[1]).Trim()
                LatestVersion = ''
            }
        }

        return $default
    }

    $currentVersion = [string]$parts[$idIndex + 1]
    $latestVersion = ''

    if (($idIndex + 3) -lt $parts.Count) {
        $latestVersion = [string]$parts[$idIndex + 2]
    }

    return @{
        IsInstalled = $true
        CurrentVersion = $currentVersion
        LatestVersion = $latestVersion
    }
}

function ConvertTo-NormalizedWingetOutput {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ($null -eq $Text) {
        return ''
    }

    $value = [string]$Text
    # Strip ANSI escape sequences that can appear in winget table output.
    $value = [regex]::Replace($value, "`e\[[0-9;?]*[ -/]*[@-~]", '')
    return $value.Trim()
}

function Format-WingetVersionMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseMessage,
        [Parameter(Mandatory)][hashtable]$VersionInfo
    )

    if (-not $VersionInfo.IsInstalled) {
        if (-not [string]::IsNullOrWhiteSpace([string]$VersionInfo.LatestVersion)) {
            return "$BaseMessage. Current: not installed, Latest: $([string]$VersionInfo.LatestVersion)"
        }

        return "$BaseMessage. Current: not installed, Latest: unknown"
    }

    $current = if ([string]::IsNullOrWhiteSpace([string]$VersionInfo.CurrentVersion)) { 'unknown' } else { [string]$VersionInfo.CurrentVersion }
    $latest = Get-NormalizedLatestVersionForDisplay -CurrentVersion ([string]$VersionInfo.CurrentVersion) -LatestVersion ([string]$VersionInfo.LatestVersion)
    if ([string]::IsNullOrWhiteSpace($latest)) {
        $latest = $current
    }

    return "$BaseMessage. Current: $current, Latest: $latest"
}

function Get-WingetLatestAvailableVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AppId)

    try {
        $showOutput = & winget show --id $AppId --exact --accept-source-agreements --disable-interactivity 2>&1
        if ($LASTEXITCODE -ne 0) {
            return ''
        }

        return (Get-WingetLatestVersionFromShowOutput -Output $showOutput)
    }
    catch {
        Write-Log -Level Debug -Message "Unable to read winget latest version for '$AppId': $_"
    }

    return ''
}

function Get-WingetLatestVersionFromShowOutput {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Output)

    foreach ($line in @($Output)) {
        $text = [string]$line
        if ($text -match '^\s*(Version|Versione)\s*:\s*(.+)$') {
            return ([string]$Matches[2]).Trim()
        }

        if ($text -match '^\s*(Available|Disponibile)\s*:\s*(.+)$') {
            return ([string]$Matches[2]).Trim()
        }
    }

    return ''
}

function Get-WingetVersionSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$VersionInfo)

    $current = if ($VersionInfo.IsInstalled) {
        if ([string]::IsNullOrWhiteSpace([string]$VersionInfo.CurrentVersion)) { 'unknown' } else { [string]$VersionInfo.CurrentVersion }
    }
    else {
        'not installed'
    }

    $latest = Get-NormalizedLatestVersionForDisplay -CurrentVersion ([string]$VersionInfo.CurrentVersion) -LatestVersion ([string]$VersionInfo.LatestVersion)
    if ([string]::IsNullOrWhiteSpace($latest)) {
        $latest = if ($VersionInfo.IsInstalled -and -not [string]::IsNullOrWhiteSpace([string]$VersionInfo.CurrentVersion)) { [string]$VersionInfo.CurrentVersion } else { 'unknown' }
    }
    return "Current: $current, Latest: $latest"
}

function Get-WingetFailureMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][object[]]$Output,
        [Parameter(Mandatory)][hashtable]$VersionInfo
    )

    $hexCode = Convert-WingetExitCodeToHex -ExitCode $ExitCode
    $hint = Get-WingetKnownErrorHint -HexCode $hexCode
    $firstOutputLine = [string](Get-FirstMeaningfulOutputLine -Output $Output)
    $outputPart = if (-not [string]::IsNullOrWhiteSpace($firstOutputLine)) { " First output line: $firstOutputLine" } else { '' }
    $versionPart = Get-WingetVersionSummary -VersionInfo $VersionInfo

    return "winget $Operation failed with exit code $ExitCode ($hexCode). $versionPart. $hint$outputPart"
}

function Test-WingetLegacyInkscapeConflict {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$App,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][object[]]$Output
    )

    if ([string]$App.key -ne 'inkscape') {
        return $false
    }

    $hexCode = (Convert-WingetExitCodeToHex -ExitCode $ExitCode).ToUpperInvariant()
    $text = (@($Output) -join "`n").ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $false
    }

    return (
        $hexCode -eq '0X8A150049' -and
        ($text -match 'trovato\s+inkscape' -or $text -match 'found\s+inkscape')
    )
}

function Get-WingetLegacyInkscapeConflictMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$VersionInfo)

    $summary = Get-WingetVersionSummary -VersionInfo $VersionInfo
    return "Inkscape legacy installation detected (not managed by winget). $summary. Uninstall the current Inkscape version manually, then run dev-bootstrap again."
}

function Write-AppInstallerEntryLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Entry)

    $level = if ($Entry.Status -eq 'ERROR') { 'Error' } else { 'Info' }
    $durationText = if ($Entry.Duration -gt [TimeSpan]::Zero) { " ($($Entry.Duration.ToString('hh\:mm\:ss')))" } else { '' }
    $actionText = Get-AppInstallerActionText -Message ([string]$Entry.Message)

    Write-Log -Level $level -Message "  Action: $actionText"
    Write-Log -Level $level -Message "  Status: $($Entry.Status)$durationText"
}

function Format-VersionCheckLogMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$VersionInfo)

    $current = if ($VersionInfo.IsInstalled) {
        if ([string]::IsNullOrWhiteSpace([string]$VersionInfo.CurrentVersion)) { 'unknown' } else { [string]$VersionInfo.CurrentVersion }
    }
    else {
        'not installed'
    }

    $latest = Get-NormalizedLatestVersionForDisplay -CurrentVersion ([string]$VersionInfo.CurrentVersion) -LatestVersion ([string]$VersionInfo.LatestVersion)
    if ([string]::IsNullOrWhiteSpace($latest)) {
        $latest = if ($VersionInfo.IsInstalled -and -not [string]::IsNullOrWhiteSpace([string]$VersionInfo.CurrentVersion)) { [string]$VersionInfo.CurrentVersion } else { 'unknown' }
    }

    return "Version check: Current = $current, Latest = $latest"
}

function Get-AppInstallerActionText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return 'Completed.'
    }

    $text = $Message
    $separator = '. Current:'
    $index = $text.IndexOf($separator, [StringComparison]::OrdinalIgnoreCase)
    if ($index -gt 0) {
        $text = $text.Substring(0, $index)
    }

    return $text.Trim()
}

function Convert-WingetExitCodeToHex {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ExitCode)

    $unsigned = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$ExitCode), 0)
    return ('0x{0:X8}' -f $unsigned)
}

function Get-WingetKnownErrorHint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HexCode)

    switch ($HexCode.ToUpperInvariant()) {
        '0X8A15002B' {
            return 'Possible source/agreement issue. Run: winget source reset --force; winget source update; winget list --accept-source-agreements.'
        }
        '0X8A150101' {
            return 'Package metadata/source conflict. Run: winget show --id <packageId> --exact, then retry or install manually once.'
        }
        '0X8A150014' {
            return 'Package not found in the selected source. Verify package ID and source. For Microsoft Store IDs (for example 9WZ*), use --source msstore and ensure Store source/policies are enabled.'
        }
        default {
            return 'Run winget manually for full diagnostics and verify network/proxy/policies.'
        }
    }
}

function Test-WingetAlreadyInstalledOutput {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Output)

    $text = (@($Output) -join "`n").ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $false
    }

    return (
        $text -match 'already installed' -or
        $text -match 'existing package' -or
        $text -match 'pacchetto esistente' -or
        $text -match 'pacchetto installato'
    )
}

function Test-WingetNoUpgradeAvailableOutput {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Output)

    $text = (@($Output) -join "`n").ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $false
    }

    return (
        $text -match 'no applicable upgrade found' -or
        $text -match 'no available upgrade found' -or
        $text -match 'no newer package versions are available from the configured sources' -or
        $text -match 'nessun aggiornamento disponibile' -or
        $text -match 'non sono disponibili aggiornamenti' -or
        $text -match 'non sono stati trovati aggiornamenti disponibili' -or
        $text -match 'non sono disponibili versioni\s+\S+\s+recenti del pacchetto dalle origini configurate' -or
        $text -match 'non sono disponibili versioni piu recenti del pacchetto dalle origini configurate' -or
        $text -match 'non sono disponibili versioni più recenti del pacchetto dalle origini configurate'
    )
}

function Test-WingetAppInUseOutput {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Output)

    $text = (@($Output) -join "`n").ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $false
    }

    return (
        $text -match 'currently running' -or
        $text -match 'application is currently running' -or
        $text -match 'attualmente in esecuzione' -or
        $text -match "uscire dall'applicazione"
    )
}

function Stop-AppProcessesForInstall {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$App)

    $processNames = @()
    if ($App.ContainsKey('windowsProcessNames') -and $null -ne $App.windowsProcessNames) {
        $processNames = @($App.windowsProcessNames)
    }

    if (@($processNames).Count -eq 0 -and $App.key) {
        $processNames = switch ([string]$App.key) {
            'notepadplusplus' { @('notepad++') }
            'vscode' { @('Code') }
            default { @() }
        }
    }

    if (@($processNames).Count -eq 0) {
        return $false
    }

    $stoppedAny = $false
    foreach ($name in @($processNames)) {
        try {
            $targets = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
            foreach ($target in $targets) {
                Stop-Process -Id $target.Id -Force -ErrorAction SilentlyContinue
                $stoppedAny = $true
            }
        }
        catch {
            Write-Log -Level Debug -Message "Unable to stop process '$name' for '$($App.name)': $_"
        }
    }

    return $stoppedAny
}

function Test-ShouldUpgradeInstalledApp {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$VersionInfo)

    if (-not $VersionInfo.IsInstalled) {
        return $false
    }

    $current = [string]$VersionInfo.CurrentVersion
    $latest = [string]$VersionInfo.LatestVersion
    if ([string]::IsNullOrWhiteSpace($current) -or [string]::IsNullOrWhiteSpace($latest)) {
        return $false
    }

    $comparison = Compare-ComparableVersionStrings -Left $current -Right $latest
    if ($null -eq $comparison) {
        return $current -ne $latest
    }

    return $comparison -lt 0
}

function Get-NormalizedLatestVersionForDisplay {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$CurrentVersion,
        [AllowNull()][AllowEmptyString()][string]$LatestVersion
    )

    if ([string]::IsNullOrWhiteSpace($LatestVersion)) {
        return ''
    }

    if ([string]::IsNullOrWhiteSpace($CurrentVersion)) {
        return [string]$LatestVersion
    }

    $comparison = Compare-ComparableVersionStrings -Left $CurrentVersion -Right $LatestVersion
    if ($null -eq $comparison) {
        return [string]$LatestVersion
    }

    if ($comparison -gt 0) {
        # Avoid showing a misleading "Latest" value older than installed version.
        return [string]$CurrentVersion
    }

    return [string]$LatestVersion
}

function Compare-ComparableVersionStrings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )

    $leftParts = @($Left.Split('.') | ForEach-Object { $_.Trim() })
    $rightParts = @($Right.Split('.') | ForEach-Object { $_.Trim() })
    if ($leftParts.Count -eq 0 -or $rightParts.Count -eq 0) {
        return $null
    }

    foreach ($part in @($leftParts + $rightParts)) {
        if ($part -notmatch '^\d+$') {
            return $null
        }
    }

    $max = [Math]::Max($leftParts.Count, $rightParts.Count)
    for ($i = 0; $i -lt $max; $i++) {
        $l = if ($i -lt $leftParts.Count) { [int]$leftParts[$i] } else { 0 }
        $r = if ($i -lt $rightParts.Count) { [int]$rightParts[$i] } else { 0 }

        if ($l -lt $r) { return -1 }
        if ($l -gt $r) { return 1 }
    }

    return 0
}

function ConvertTo-AlreadyPresentVersionInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$VersionInfo)

    if ($VersionInfo.IsInstalled) {
        return $VersionInfo
    }

    return @{
        IsInstalled = $true
        CurrentVersion = if ([string]::IsNullOrWhiteSpace([string]$VersionInfo.CurrentVersion)) { 'unknown' } else { [string]$VersionInfo.CurrentVersion }
        LatestVersion = if ([string]::IsNullOrWhiteSpace([string]$VersionInfo.LatestVersion)) { '' } else { [string]$VersionInfo.LatestVersion }
    }
}

function Get-PreferredWindowsPackageManager {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Current)

    if ($Current.Name -ne 'winget') {
        return $Current
    }

    $health = Test-WingetOperational
    if ($health.IsReady) {
        return $Current
    }

    Write-Log -Level Warning -Message "winget is not operational: $($health.Message)"
    Write-Log -Level Warning -Message 'Continuing with winget despite detected issues.'
    return $Current
}

function Test-WingetOperational {
    [CmdletBinding()]
    param()

    $probe = & winget list --accept-source-agreements --disable-interactivity 2>&1
    if ($LASTEXITCODE -eq 0) {
        return @{ IsReady = $true; Message = 'OK' }
    }

    $update = & winget source update 2>&1
    if ($LASTEXITCODE -eq 0) {
        $probe = & winget list --accept-source-agreements --disable-interactivity 2>&1
        if ($LASTEXITCODE -eq 0) {
            return @{ IsReady = $true; Message = 'Recovered after source update' }
        }
    }

    $reset = & winget source reset --force 2>&1
    $null = & winget source update 2>&1
    $probe = & winget list --accept-source-agreements --disable-interactivity 2>&1
    if ($LASTEXITCODE -eq 0) {
        return @{ IsReady = $true; Message = 'Recovered after source reset' }
    }

    $line = [string](Get-FirstMeaningfulOutputLine -Output ($probe + $update + $reset))
    $detail = if (-not [string]::IsNullOrWhiteSpace($line)) { $line } else { 'No textual output from winget' }
    return @{ IsReady = $false; Message = $detail }
}

function Get-WindowsAppVersionInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$App)

    $default = @{
        IsInstalled = $false
        CurrentVersion = ''
        LatestVersion = ''
    }

    $fromWinget = if ($App.wingetId) { Get-WingetVersionInfo -AppId $App.wingetId } else { $default }
    if ($fromWinget.IsInstalled -or -not [string]::IsNullOrWhiteSpace([string]$fromWinget.LatestVersion)) {
        return $fromWinget
    }

    $fromRegistry = Get-WindowsRegistryAppVersionInfo -App $App
    if ($fromRegistry.IsInstalled) {
        return $fromRegistry
    }

    $fromCommand = Get-CommandVersionInfo -App $App
    if ($fromCommand.IsInstalled) {
        return $fromCommand
    }

    return $default
}

function Get-WindowsRegistryAppVersionInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$App)

    $default = @{
        IsInstalled = $false
        CurrentVersion = ''
        LatestVersion = ''
    }

    if (-not (Test-IsWindows)) {
        return $default
    }

    $key = if ($App.key) { [string]$App.key } else { '' }
    $namePatterns = switch ($key) {
        'vscode' { @('Microsoft Visual Studio Code*', 'Visual Studio Code*') }
        'notepadplusplus' { @('Notepad++*') }
        'nvmWindows' { @('NVM for Windows*') }
        'git' { @('Git*') }
        default { @() }
    }

    if (@($namePatterns).Count -eq 0) {
        return $default
    }

    $uninstallPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($path in $uninstallPaths) {
        try {
            $items = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
            foreach ($item in @($items)) {
                $displayName = [string]$item.DisplayName
                if ([string]::IsNullOrWhiteSpace($displayName)) {
                    continue
                }

                foreach ($pattern in @($namePatterns)) {
                    if ($displayName -like $pattern) {
                        $default.IsInstalled = $true
                        $default.CurrentVersion = [string]$item.DisplayVersion
                        return $default
                    }
                }
            }
        }
        catch {
            Write-Log -Level Debug -Message "Unable to inspect uninstall registry path '$path': $_"
        }
    }

    return $default
}

function Get-CommandVersionInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$App)

    $default = @{
        IsInstalled = $false
        CurrentVersion = ''
        LatestVersion = ''
    }

    $key = if ($App.key) { [string]$App.key } else { '' }
    try {
        switch ($key) {
            'git' {
                if (Test-CommandExists -CommandName 'git') {
                    $out = & git --version 2>&1
                    $line = [string](Get-FirstMeaningfulOutputLine -Output $out)
                    $default.IsInstalled = $true
                    if (-not [string]::IsNullOrWhiteSpace($line) -and $line -match '([0-9]+\.[0-9]+\.[0-9]+)') {
                        $default.CurrentVersion = [string]$Matches[1]
                    }
                }
            }
            'vscode' {
                if (Test-CommandExists -CommandName 'code') {
                    $out = & code --version 2>&1
                    $line = [string](Get-FirstMeaningfulOutputLine -Output $out)
                    $default.IsInstalled = $true
                    if (-not [string]::IsNullOrWhiteSpace($line)) {
                        $default.CurrentVersion = $line
                    }
                }
            }
            'nvmWindows' {
                if (Test-CommandExists -CommandName 'nvm') {
                    $out = & nvm version 2>&1
                    $line = [string](Get-FirstMeaningfulOutputLine -Output $out)
                    $default.IsInstalled = $true
                    if (-not [string]::IsNullOrWhiteSpace($line) -and $line -match '([0-9]+\.[0-9]+\.[0-9]+)') {
                        $default.CurrentVersion = [string]$Matches[1]
                    }
                }
            }
            'powershell7' {
                if (Test-CommandExists -CommandName 'pwsh') {
                    $out = & pwsh --version 2>&1
                    $line = [string](Get-FirstMeaningfulOutputLine -Output $out)
                    $default.IsInstalled = $true
                    if (-not [string]::IsNullOrWhiteSpace($line) -and $line -match '([0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?)') {
                        $default.CurrentVersion = [string]$Matches[1]
                    }
                }
            }
            'winget' {
                if (Test-CommandExists -CommandName 'winget') {
                    $out = & winget --version 2>&1
                    $line = [string](Get-FirstMeaningfulOutputLine -Output $out)
                    $default.IsInstalled = $true
                    if (-not [string]::IsNullOrWhiteSpace($line) -and $line -match '([0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?)') {
                        $default.CurrentVersion = [string]$Matches[1]
                    }
                }
            }
        }
    }
    catch {
        Write-Log -Level Debug -Message "Unable to read command version info for '$key': $_"
    }

    return $default
}

function Get-FirstMeaningfulOutputLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Output)

    foreach ($line in @($Output)) {
        $text = ([string]$line).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        if ($text -match '^[-|]+$') {
            continue
        }

        if ($text -match '^[\\/]+$') {
            continue
        }

        if ($text -match '^(Name|Nome)\s+(Id|ID)\s+') {
            continue
        }

        return $text
    }

    return ''
}

function Install-LinuxApp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$App,
        [Parameter(Mandatory)][hashtable]$PackageManager,
        [switch]$Force
    )

    $packageName = $App.linuxPackage

    if (-not $packageName) {
        return @{ Status = 'SKIPPED'; Message = 'linuxPackage not configured' }
    }

    # Security hardening: avoid shell injection when package name comes from catalog JSON.
    if ([string]$packageName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._:+-]*$') {
        return @{ Status = 'ERROR'; Message = "Invalid Linux package name rejected: $packageName" }
    }

    $installCommand = switch ($PackageManager.Name) {
        'apt' { "sudo apt-get install -y --only-upgrade $packageName || sudo apt-get install -y $packageName" }
        'dnf' { "sudo dnf install -y $packageName" }
        'yum' { "sudo yum install -y $packageName" }
        'zypper' { "sudo zypper install -y $packageName" }
        default { $null }
    }

    if (-not $installCommand) {
        return @{ Status = 'ERROR'; Message = "Unsupported Linux package manager: $($PackageManager.Name)" }
    }

    Write-ConsoleStatus -Message "  Installing $($App.name) via $($PackageManager.Name) (this may take several minutes)..."
    $null = & bash -c $installCommand 2>&1
    if ($LASTEXITCODE -eq 0) {
        return @{ Status = 'INSTALLED'; Message = "Installed via $($PackageManager.Name)" }
    }

    return @{ Status = 'ERROR'; Message = "$($PackageManager.Name) install failed with exit code $LASTEXITCODE" }
}
