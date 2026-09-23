#Requires -Version 7.0
# Copyright (c) 2026 POMINI Long Rolling Mills. Licensed under the MIT License.
<#
.SYNOPSIS
    Azure DevOps repository synchronization module.
.DESCRIPTION
    Syncs repositories for one organization configured in AZURE_DEVOPS_ORGS.
    Optional include/exclude project filters limit project scope.
    Optional includeWikis setting includes hidden Git repositories that back project wikis.

    Target path layout:
            <path>/<project>/<repo>
#>

function Invoke-DevOpsSync {
    <#
    .SYNOPSIS
        Synchronizes Azure DevOps repositories for the configured organization.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [switch]$Force
    )

    $moduleConfig = $Config.modules.devops
    $results = [System.Collections.Generic.List[hashtable]]::new()

    $pat = Get-SecureEnvVariable -Name 'AZURE_DEVOPS_PAT'
    if (-not $pat) {
        $envFilePath = Join-Path $ProjectRoot '.env'
        $envPatState = Get-EnvFileVariableState -Path $envFilePath -Name 'AZURE_DEVOPS_PAT'
        $message = switch ($envPatState) {
            'MissingFile' { "AZURE_DEVOPS_PAT is not set and .env file is missing: $envFilePath" }
            'DefinedEmpty' { 'AZURE_DEVOPS_PAT is defined in .env but empty.' }
            'NotDefined' { 'AZURE_DEVOPS_PAT is not set in .env or environment variables.' }
            default { 'AZURE_DEVOPS_PAT is not set in process/user/machine environment.' }
        }

        $results.Add((New-ReportEntry -Module 'DevOps' -Item 'AUTH' -Status 'ERROR' -Message $message))
        return $results
    }

    if (-not (Test-CommandExists -CommandName 'git')) {
        $results.Add((New-ReportEntry -Module 'DevOps' -Item 'PREREQ' -Status 'ERROR' -Message 'git is not installed'))
        return $results
    }

    $organizations = @(Resolve-DevOpsOrganizations -ModuleConfig $moduleConfig)
    if (@($organizations).Count -eq 0) {
        $results.Add((New-ReportEntry -Module 'DevOps' -Item 'CONFIG' -Status 'ERROR' -Message 'No Azure DevOps organization resolved from AZURE_DEVOPS_ORGS. Configure exactly one organization name.'))
        return $results
    }

    if (@($organizations).Count -gt 1) {
        $results.Add((New-ReportEntry -Module 'DevOps' -Item 'CONFIG' -Status 'ERROR' -Message "AZURE_DEVOPS_ORGS supports exactly one organization. Current value resolves to: $($organizations -join ', ')."))
        return $results
    }

    $organization = [string]$organizations[0]

    $targetRoot = Resolve-ConfiguredPath -Path $moduleConfig.path
    if (-not (Test-Path -LiteralPath $targetRoot)) {
        New-Item -Path $targetRoot -ItemType Directory -Force | Out-Null
    }

    Write-DevOpsFilterAmbiguityWarnings -EntityLabel 'DevOps projects' -IncludeTokens @($moduleConfig.projectsInclude) -ExcludeTokens @($moduleConfig.projectsExclude)

    $authHeader = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
    $headers = @{ Authorization = "Basic $authHeader"; 'Content-Type' = 'application/json' }

    $retryCount = if ($moduleConfig.retryCount) { [int]$moduleConfig.retryCount } else { 3 }
    $retryDelay = if ($moduleConfig.retryDelaySeconds) { [int]$moduleConfig.retryDelaySeconds } else { 5 }

    $expected = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $knownRemote = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $workItems = [System.Collections.Generic.List[object]]::new()
    $seenWorkItems = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    $projects = @(Get-DevOpsProjects -Organization $organization -Headers $headers -RetryCount $retryCount -RetryDelaySeconds $retryDelay)
    foreach ($project in $projects) {
        $projectName = [string]$project.name
        $syncProject = Test-DevOpsIncludeExcludeMatch -Name $projectName -IncludeTokens @($moduleConfig.projectsInclude) -ExcludeTokens @($moduleConfig.projectsExclude)

        $repos = @(Get-DevOpsRepos -Organization $organization -Project $projectName -Headers $headers -RetryCount $retryCount -RetryDelaySeconds $retryDelay -IncludeHidden:([bool]$moduleConfig.includeWikis))
        foreach ($repo in $repos) {
            $repoName = [string]$repo.name
            $relative = "$projectName/$repoName"
            $knownRemote.Add($relative) | Out-Null

            if ($seenWorkItems.Add($relative)) {
                $workItems.Add([PSCustomObject]@{
                        Label = "$projectName - $repoName"
                        Relative = $relative
                        DestinationPath = (Join-Path (Join-Path $targetRoot $projectName) $repoName)
                        CloneUrl = ([string]$repo.remoteUrl)
                        ShouldSync = $syncProject
                    })
            }
        }

    }

    $totalItems = $workItems.Count
    $itemIndex = 0
    foreach ($item in $workItems) {
        $itemIndex++
        Write-Log -Level Info -Message "Repository [$itemIndex/$totalItems]: $($item.Label)"

        if (-not $item.ShouldSync) {
            $entry = New-ReportEntry -Module 'DevOps' -Item $item.Relative -Status 'SKIPPED' -Message 'Filtered by project include/exclude rules.'
            $results.Add($entry)
            Write-DevOpsRepoEntryLog -Entry $entry
            continue
        }

        $itemTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $expected.Add($item.Relative) | Out-Null
        try {
            $cloneUrl = ConvertTo-DevOpsRemoteUrl -RemoteUrl $item.CloneUrl
            $gitResult = Invoke-GitCloneOrPull -CloneUrl $cloneUrl -DestinationPath $item.DestinationPath -DevOpsPat $pat
            $itemTimer.Stop()
            $entry = New-ReportEntry -Module 'DevOps' -Item $item.Relative -Status $gitResult.Status -Message $gitResult.Message -Duration $itemTimer.Elapsed
            $results.Add($entry)
            Write-DevOpsRepoEntryLog -Entry $entry
        }
        catch {
            $itemTimer.Stop()
            $entry = New-ReportEntry -Module 'DevOps' -Item $item.Relative -Status 'ERROR' -Message "$_" -Duration $itemTimer.Elapsed
            $results.Add($entry)
            Write-DevOpsRepoEntryLog -Entry $entry
        }
    }

    Add-DevOpsOrphanEntries -TargetRoot $targetRoot -Expected $expected -KnownRemote $knownRemote -Results $results

    if ($moduleConfig.setFolderIcon) {
        if (Test-IsWindows) {
            Set-WindowsFolderIcon -FolderPath $targetRoot -IconFile 'devops.ico' -ProjectRoot $ProjectRoot
        }
        else {
            Write-Log -Level Warning -Message 'Folder icon option is Windows-only. Ignoring on this platform.'
        }
    }

    return $results
}

function Resolve-DevOpsOrganizations {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$ModuleConfig)

    $fromPlural = Get-SecureEnvVariable -Name 'AZURE_DEVOPS_ORGS'
    if ($fromPlural) {
        $resolved = [System.Collections.Generic.List[string]]::new()
        foreach ($raw in @($fromPlural.Split(','))) {
            $token = [string]$raw
            $token = $token.Trim()

            if ([string]::IsNullOrWhiteSpace($token)) {
                continue
            }

            if ($token.StartsWith('#')) {
                continue
            }

            $hashIndex = $token.IndexOf('#')
            if ($hashIndex -ge 0) {
                $token = $token.Substring(0, $hashIndex).Trim()
            }

            if (-not [string]::IsNullOrWhiteSpace($token)) {
                $resolved.Add($token)
            }
        }

        return , @($resolved | Select-Object -Unique)
    }

    return , @()
}

function ConvertTo-DevOpsRemoteUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RemoteUrl
    )

    if ([string]::IsNullOrWhiteSpace($RemoteUrl)) {
        return $RemoteUrl
    }

    # Keep remotes clean: strip any user-info if present.
    if ($RemoteUrl -match '^https://') {
        return ($RemoteUrl -replace '^https://[^@/]+@', 'https://')
    }

    return $RemoteUrl
}

function Test-DevOpsIncludeExcludeMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [object[]]$IncludeTokens = @('*'),
        [object[]]$ExcludeTokens = @()
    )

    return (Test-IncludeExcludeMatch -Name $Name -IncludeTokens $IncludeTokens -ExcludeTokens $ExcludeTokens)
}

function Get-DevOpsNormalizedFilterTokens {
    [CmdletBinding()]
    param([object[]]$Tokens)

    return @(Get-NormalizedFilterTokenSet -Tokens $Tokens)
}

function Write-DevOpsFilterAmbiguityWarnings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EntityLabel,
        [object[]]$IncludeTokens,
        [object[]]$ExcludeTokens
    )

    Write-FilterAmbiguityWarning -EntityLabel $EntityLabel -IncludeTokens $IncludeTokens -ExcludeTokens $ExcludeTokens
}

function Get-DevOpsProjects {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][hashtable]$Headers,
        [int]$RetryCount,
        [int]$RetryDelaySeconds
    )

    $url = "https://dev.azure.com/$Organization/_apis/projects?api-version=7.0&`$top=1000"
    $response = Invoke-WithRetry -MaxRetries $RetryCount -BaseDelaySeconds $RetryDelaySeconds -OperationName "DevOps projects ($Organization)" -ScriptBlock {
        Invoke-RestMethod -Uri $url -Headers $Headers -Method GET
    }

    return @($response.value)
}

function Get-DevOpsRepos {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][hashtable]$Headers,
        [int]$RetryCount,
        [int]$RetryDelaySeconds,
        [switch]$IncludeHidden
    )

    $url = "https://dev.azure.com/$Organization/$Project/_apis/git/repositories?api-version=7.0"
    if ($IncludeHidden) {
        $url = "$url&includeHidden=true"
    }

    $response = Invoke-WithRetry -MaxRetries $RetryCount -BaseDelaySeconds $RetryDelaySeconds -OperationName "DevOps repos ($Organization/$Project)" -ScriptBlock {
        Invoke-RestMethod -Uri $url -Headers $Headers -Method GET
    }

    return @($response.value | Where-Object { -not $_.isDisabled })
}

function Add-DevOpsOrphanEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][System.Collections.Generic.HashSet[string]]$Expected,
        [Parameter(Mandatory)][System.Collections.Generic.HashSet[string]]$KnownRemote,
        [Parameter(Mandatory)][System.Collections.Generic.List[hashtable]]$Results
    )

    if (-not (Test-Path -LiteralPath $TargetRoot)) {
        return
    }

    $projectDirs = Get-ChildItem -LiteralPath $TargetRoot -Directory -ErrorAction SilentlyContinue
    foreach ($projectDir in $projectDirs) {
        $repoDirs = Get-ChildItem -LiteralPath $projectDir.FullName -Directory -ErrorAction SilentlyContinue
        foreach ($repoDir in $repoDirs) {
            $relative = "$($projectDir.Name)/$($repoDir.Name)"
            if ($KnownRemote.Contains($relative)) {
                continue
            }

            if (-not $Expected.Contains($relative)) {
                Write-Log -Level Info -Message "Repository [local-only]: $relative"
                $entry = New-ReportEntry -Module 'DevOps' -Item $relative -Status 'ORPHAN' -Message 'Local repository does not exist remotely on Azure DevOps.'
                $Results.Add($entry)
                Write-DevOpsRepoEntryLog -Entry $entry
            }
        }
    }
}

function Write-DevOpsRepoEntryLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Entry)

    $level = if ($Entry.Status -eq 'ERROR') { 'Error' } else { 'Info' }
    $durationText = if ($Entry.Duration -gt [TimeSpan]::Zero) { " ($($Entry.Duration.ToString('hh\:mm\:ss')))" } else { '' }
    $actionText = if ([string]::IsNullOrWhiteSpace([string]$Entry.Message)) { Get-DevOpsActionFromStatus -Status ([string]$Entry.Status) } else { [string]$Entry.Message }

    Write-Log -Level $level -Message "  Action: $actionText"
    Write-Log -Level $level -Message "  Status: $($Entry.Status)$durationText"
}

function Get-DevOpsActionFromStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Status)

    switch ($Status.ToUpperInvariant()) {
        'ADDED' { return 'Repository cloned.' }
        'UPDATED' { return 'Repository updated.' }
        'NONE' { return 'Repository already up to date.' }
        'SKIPPED' { return 'Repository skipped.' }
        'ORPHAN' { return 'Local-only repository found.' }
        'ERROR' { return 'Repository sync failed.' }
        default { return 'Repository sync completed.' }
    }
}
