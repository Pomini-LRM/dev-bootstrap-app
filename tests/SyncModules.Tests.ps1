#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0' }

BeforeAll {
    if ([string]::IsNullOrWhiteSpace($env:TEMP)) {
        $env:TEMP = [System.IO.Path]::GetTempPath()
    }

    $script:projectRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:projectRoot 'src' 'common' 'Logger.ps1')
    . (Join-Path $script:projectRoot 'src' 'common' 'Filters.ps1')
    . (Join-Path $script:projectRoot 'src' 'common' 'Platform.ps1')
    . (Join-Path $script:projectRoot 'src' 'common' 'Utilities.ps1')
    . (Join-Path $script:projectRoot 'src' 'common' 'Report.ps1')
    . (Join-Path $script:projectRoot 'src' 'modules' 'Sync-GitHubRepos.ps1')
    . (Join-Path $script:projectRoot 'src' 'modules' 'Sync-DevOpsRepos.ps1')
    . (Join-Path $script:projectRoot 'src' 'modules' 'Sync-AcrImages.ps1')

    $testLogDir = Join-Path $env:TEMP 'dev-bootstrap-tests-sync-modules' 'log'
    Initialize-Logger -LogDirectory $testLogDir -Level 'Error' -Silent | Out-Null

    $script:originalGitHubToken = [System.Environment]::GetEnvironmentVariable('GITHUB_TOKEN', 'Process')
    $script:originalDevOpsPat = [System.Environment]::GetEnvironmentVariable('AZURE_DEVOPS_PAT', 'Process')
    $script:originalTenantId = [System.Environment]::GetEnvironmentVariable('AZURE_TENANT_ID', 'Process')
}

Describe 'Module auth guards' {
    It 'returns AUTH error when GitHub token is missing' {
        [System.Environment]::SetEnvironmentVariable('GITHUB_TOKEN', $null, 'Process')

        $config = @{ modules = @{ github = @{ path = 'D:\\GitHub'; usersInclude = @('*'); usersExclude = @(); organizationsInclude = @('*'); organizationsExclude = @(); setFolderIcon = $false; retryCount = 1; retryDelaySeconds = 0 } } }
        $results = Invoke-GitHubSync -Config $config -ProjectRoot $script:projectRoot

        $entries = @($results)
        $entries.Count | Should -Be 1
        $entries[0].Item | Should -Be 'AUTH'
        $entries[0].Status | Should -Be 'ERROR'
    }

    It 'returns AUTH error when DevOps PAT is missing' {
        [System.Environment]::SetEnvironmentVariable('AZURE_DEVOPS_PAT', $null, 'Process')

        $config = @{ modules = @{ devops = @{ path = 'D:\\DevOps'; projectsInclude = @('*'); projectsExclude = @(); includeWikis = $false; setFolderIcon = $false; retryCount = 1; retryDelaySeconds = 0 } } }
        $results = Invoke-DevOpsSync -Config $config -ProjectRoot $script:projectRoot

        $entries = @($results)
        $entries.Count | Should -Be 1
        $entries[0].Item | Should -Be 'AUTH'
        $entries[0].Status | Should -Be 'ERROR'
    }

    It 'returns prereq errors when az and docker are unavailable' {
        Mock -CommandName Test-CommandExists -MockWith { return $false }

        $config = @{ modules = @{ acr = @{ registries = @('myregistry'); imagesInclude = @('*'); imagesExclude = @(); retryCount = 1; retryDelaySeconds = 0 } } }
        $results = Invoke-AcrSync -Config $config -ProjectRoot $script:projectRoot

        $statuses = @($results | ForEach-Object { $_.Status })
        $statuses | Should -Contain 'ERROR'
        @($results).Count | Should -Be 2
    }
}

Describe 'ACR diagnostics helpers' {
    It 'detects failure details in az output text' {
        (Test-AzOutputIndicatesFailure -Output @('ERROR: The resource was not found')) | Should -BeTrue
        (Test-AzOutputIndicatesFailure -Output @('Forbidden: access denied')) | Should -BeTrue
        (Test-AzOutputIndicatesFailure -Output @('Could not resolve host name')) | Should -BeTrue
    }

    It 'does not flag healthy az output' {
        (Test-AzOutputIndicatesFailure -Output @('plrm-vscode')) | Should -BeFalse
        (Test-AzOutputIndicatesFailure -Output @('')) | Should -BeFalse
    }

    It 'detects private IPv4 addresses' {
        (Test-AcrIpAddressPrivate -Address ([System.Net.IPAddress]::Parse('10.1.0.6'))) | Should -BeTrue
        (Test-AcrIpAddressPrivate -Address ([System.Net.IPAddress]::Parse('192.168.1.10'))) | Should -BeTrue
        (Test-AcrIpAddressPrivate -Address ([System.Net.IPAddress]::Parse('8.8.8.8'))) | Should -BeFalse
    }
}

Describe 'GitHub repo deduplication' {
    It 'deduplicates repos by full_name across multiple API sources' {
        $mockHeaders = @{ Authorization = 'Bearer fake-token'; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }

        Mock -CommandName Invoke-WebRequest -MockWith {
            $uriStr = [string]$Uri

            if ($uriStr -match '/user/repos') {
                $body = @(
                    @{ full_name = 'owner/private-repo'; name = 'private-repo'; owner = @{ login = 'owner'; type = 'User' }; clone_url = 'https://github.com/owner/private-repo.git' }
                    @{ full_name = 'owner/public-repo'; name = 'public-repo'; owner = @{ login = 'owner'; type = 'User' }; clone_url = 'https://github.com/owner/public-repo.git' }
                ) | ConvertTo-Json -Depth 5
                return @{ Content = $body; Headers = @{ 'X-GitHub-Request-Id' = 'test-1' } }
            }

            if ($uriStr -match '/users/owner/repos') {
                $body = @(
                    @{ full_name = 'owner/public-repo'; name = 'public-repo'; owner = @{ login = 'owner'; type = 'User' }; clone_url = 'https://github.com/owner/public-repo.git' }
                    @{ full_name = 'owner/extra-public'; name = 'extra-public'; owner = @{ login = 'owner'; type = 'User' }; clone_url = 'https://github.com/owner/extra-public.git' }
                ) | ConvertTo-Json -Depth 5
                return @{ Content = $body; Headers = @{ 'X-GitHub-Request-Id' = 'test-2' } }
            }

            if ($uriStr -match '/user/orgs') {
                return @{ Content = '[]'; Headers = @{ 'X-GitHub-Request-Id' = 'test-3' } }
            }

            return @{ Content = '[]'; Headers = @{} }
        }

        $repos = Get-AllVisibleGitHubRepos -Headers $mockHeaders -RetryCount 1 -RetryDelaySeconds 0 -AuthenticatedUser 'owner'

        @($repos).Count | Should -Be 3
        @($repos | ForEach-Object { $_.full_name }) | Should -Contain 'owner/private-repo'
        @($repos | ForEach-Object { $_.full_name }) | Should -Contain 'owner/public-repo'
        @($repos | ForEach-Object { $_.full_name }) | Should -Contain 'owner/extra-public'
    }

    It 'includes org public repos via supplementary fetch' {
        $mockHeaders = @{ Authorization = 'Bearer fake-token'; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }

        Mock -CommandName Invoke-WebRequest -MockWith {
            $uriStr = [string]$Uri

            if ($uriStr -match '/user/repos') {
                $body = @(
                    @{ full_name = 'my-org/internal-repo'; name = 'internal-repo'; owner = @{ login = 'my-org'; type = 'Organization' }; clone_url = 'https://github.com/my-org/internal-repo.git' }
                ) | ConvertTo-Json -Depth 5
                return @{ Content = $body; Headers = @{ 'X-GitHub-Request-Id' = 'test-1' } }
            }

            if ($uriStr -match '/users/testuser/repos') {
                return @{ Content = '[]'; Headers = @{ 'X-GitHub-Request-Id' = 'test-2' } }
            }

            if ($uriStr -match '/user/orgs') {
                $body = @(
                    @{ login = 'my-org' }
                ) | ConvertTo-Json -Depth 5
                return @{ Content = $body; Headers = @{ 'X-GitHub-Request-Id' = 'test-3' } }
            }

            if ($uriStr -match '/orgs/my-org/repos') {
                $body = @(
                    @{ full_name = 'my-org/internal-repo'; name = 'internal-repo'; owner = @{ login = 'my-org'; type = 'Organization' }; clone_url = 'https://github.com/my-org/internal-repo.git' }
                    @{ full_name = 'my-org/public-lib'; name = 'public-lib'; owner = @{ login = 'my-org'; type = 'Organization' }; clone_url = 'https://github.com/my-org/public-lib.git' }
                ) | ConvertTo-Json -Depth 5
                return @{ Content = $body; Headers = @{ 'X-GitHub-Request-Id' = 'test-4' } }
            }

            return @{ Content = '[]'; Headers = @{} }
        }

        $repos = Get-AllVisibleGitHubRepos -Headers $mockHeaders -RetryCount 1 -RetryDelaySeconds 0 -AuthenticatedUser 'testuser'

        @($repos).Count | Should -Be 2
        @($repos | ForEach-Object { $_.full_name }) | Should -Contain 'my-org/internal-repo'
        @($repos | ForEach-Object { $_.full_name }) | Should -Contain 'my-org/public-lib'
    }
}

Describe 'ACR result coherence' {
    It 'attempts pull for explicitly configured images when registry probe fails' {
        [System.Environment]::SetEnvironmentVariable('AZURE_TENANT_ID', '51835014-d218-4754-b420-16de4790eedf', 'Process')

        Mock -CommandName Test-CommandExists -MockWith { $true }
        Mock -CommandName Get-AcrRegistryNetworkState -MockWith {
            @{ IsReachable = $true; LoginServer = 'acrpominishareddev.azurecr.io'; Addresses = @('10.1.0.6'); HasPrivateAddress = $true; Message = 'ok' }
        }
        Mock -CommandName docker -MockWith {
            $global:LASTEXITCODE = 0
            return 'Docker is running'
        }
        Mock -CommandName az -MockWith {
            $joined = ($args -join ' ').ToLowerInvariant()
            $global:LASTEXITCODE = 0

            if ($joined -match '^account show') {
                return '{"tenantId":"51835014-d218-4754-b420-16de4790eedf"}'
            }

            if ($joined -match '^acr check-health') {
                return 'ERROR: challenge endpoint failed'
            }

            if ($joined -match '^acr repository list') {
                return 'ERROR: registry not reachable'
            }

            return ''
        }

        $config = @{ modules = @{ acr = @{ registries = @('acrpominishareddev'); imagesInclude = @('img-a', 'img-b', 'img-c'); imagesExclude = @(); retryCount = 1; retryDelaySeconds = 0 } } }
        $results = @(Invoke-AcrSync -Config $config -ProjectRoot $script:projectRoot)

        # Probe fails but images are explicit: login and pull are attempted, not skipped
        $results.Count | Should -Be 3
        (@($results | Where-Object { $_.Status -eq 'SKIPPED' })).Count | Should -Be 0
        (@($results | Where-Object { $_.Status -in @('ADDED', 'UPDATED', 'NONE') })).Count | Should -Be 3
    }

    It 'skips images when registry probe fails and imagesInclude uses wildcard' {
        [System.Environment]::SetEnvironmentVariable('AZURE_TENANT_ID', '51835014-d218-4754-b420-16de4790eedf', 'Process')

        Mock -CommandName Test-CommandExists -MockWith { $true }
        Mock -CommandName Get-AcrRegistryNetworkState -MockWith {
            @{ IsReachable = $true; LoginServer = 'acrpominishareddev.azurecr.io'; Addresses = @('10.1.0.6'); HasPrivateAddress = $true; Message = 'ok' }
        }
        Mock -CommandName docker -MockWith { $global:LASTEXITCODE = 0; return 'Docker is running' }
        Mock -CommandName az -MockWith {
            $joined = ($args -join ' ').ToLowerInvariant()
            $global:LASTEXITCODE = 0

            if ($joined -match '^account show') {
                return '{"tenantId":"51835014-d218-4754-b420-16de4790eedf"}'
            }

            if ($joined -match '^acr check-health') {
                return 'ERROR: challenge endpoint failed'
            }

            if ($joined -match '^acr repository list') {
                return 'ERROR: registry not reachable'
            }

            return ''
        }

        $config = @{ modules = @{ acr = @{ registries = @('acrpominishareddev'); imagesInclude = @('*'); imagesExclude = @(); retryCount = 1; retryDelaySeconds = 0 } } }
        $results = @(Invoke-AcrSync -Config $config -ProjectRoot $script:projectRoot)

        # Wildcard mode: no work items can be resolved when probe fails
        (@($results | Where-Object { $_.Status -eq 'ERROR' })).Count | Should -Be 0
    }

    It 'fails fast when the ACR login server is not reachable on port 443' {
        [System.Environment]::SetEnvironmentVariable('AZURE_TENANT_ID', '51835014-d218-4754-b420-16de4790eedf', 'Process')
        $script:azInvocationCount = 0

        Mock -CommandName Test-CommandExists -MockWith { $true }
        Mock -CommandName Get-AcrRegistryNetworkState -MockWith {
            @{
                IsReachable = $false
                LoginServer = 'acrpominishareddev.azurecr.io'
                Addresses = @('10.1.0.6')
                HasPrivateAddress = $true
                Message = "ACR login server 'acrpominishareddev.azurecr.io' is not reachable on TCP 443 (resolved IPs: 10.1.0.6). DNS resolves to a private address. Ensure VPN, private endpoint routing, and firewall rules allow TCP 443 to the registry login server."
            }
        }
        Mock -CommandName docker -MockWith { $global:LASTEXITCODE = 0; return 'Docker is running' }
        Mock -CommandName az -MockWith {
            $script:azInvocationCount++
            $joined = ($args -join ' ').ToLowerInvariant()
            $global:LASTEXITCODE = 0

            if ($joined -match '^account show') {
                return '{"tenantId":"51835014-d218-4754-b420-16de4790eedf"}'
            }

            return ''
        }

        $config = @{ modules = @{ acr = @{ registries = @('acrpominishareddev'); imagesInclude = @('img-a', 'img-b', 'img-c'); imagesExclude = @(); retryCount = 1; retryDelaySeconds = 0 } } }
        $results = @(Invoke-AcrSync -Config $config -ProjectRoot $script:projectRoot)

        (@($results | Where-Object { $_.Status -eq 'ERROR' })).Count | Should -Be 1
        (@($results | Where-Object { $_.Status -eq 'SKIPPED' })).Count | Should -Be 3
        $script:azInvocationCount | Should -Be 2
    }

    It 'reauthenticates when access token probe requires MFA interaction' {
        [System.Environment]::SetEnvironmentVariable('AZURE_TENANT_ID', '51835014-d218-4754-b420-16de4790eedf', 'Process')

        $script:tokenProbeRequested = $false
        $script:loginPerformed = $false
        $script:logoutPerformed = $false

        Mock -CommandName Test-CommandExists -MockWith { $true }
        Mock -CommandName Get-AcrRegistryNetworkState -MockWith {
            @{ IsReachable = $true; LoginServer = 'acrpominishareddev.azurecr.io'; Addresses = @('10.1.0.6'); HasPrivateAddress = $true; Message = 'ok' }
        }
        Mock -CommandName docker -MockWith {
            $joined = ($args -join ' ').ToLowerInvariant()
            $global:LASTEXITCODE = 0

            if ($joined -match '^info') {
                return 'Docker is running'
            }

            if ($joined -match '^pull ') {
                return 'Downloaded newer image'
            }

            return ''
        }
        Mock -CommandName az -MockWith {
            $joined = ($args -join ' ').ToLowerInvariant()
            $global:LASTEXITCODE = 0

            if ($joined -match '^account show') {
                return '{"tenantId":"51835014-d218-4754-b420-16de4790eedf"}'
            }

            if ($joined -match '^account get-access-token') {
                $script:tokenProbeRequested = $true
                $global:LASTEXITCODE = 1
                return 'ERROR: AADSTS50076: Status_InteractionRequired invalid_grant. Run the command below to authenticate interactively.'
            }

            if ($joined -match '^logout') {
                $script:logoutPerformed = $true
                return ''
            }

            if ($joined -match '^login --tenant') {
                $script:loginPerformed = $true
                return '[{"tenantId":"51835014-d218-4754-b420-16de4790eedf"}]'
            }

            if ($joined -match '^acr check-health') {
                return 'Challenge endpoint https://acrpominishareddev.azurecr.io/v2/ : OK`nFetch access token successfully for acrpominishareddev.azurecr.io : OK'
            }

            if ($joined -match '^acr repository list') {
                return 'plrm-vscode'
            }

            if ($joined -match '^acr repository show-tags') {
                return 'latest'
            }

            if ($joined -match '^acr login --name') {
                return 'Login Succeeded'
            }

            return ''
        }

        $config = @{ modules = @{ acr = @{ registries = @('acrpominishareddev'); imagesInclude = @('plrm-vscode'); imagesExclude = @(); retryCount = 1; retryDelaySeconds = 0 } } }
        $results = @(Invoke-AcrSync -Config $config -ProjectRoot $script:projectRoot)

        (@($results | Where-Object { $_.Status -eq 'ERROR' })).Count | Should -Be 0
        (@($results | Where-Object { $_.Status -in @('ADDED', 'UPDATED', 'NONE') })).Count | Should -Be 1
        $script:tokenProbeRequested | Should -BeTrue
        $script:logoutPerformed | Should -BeTrue
        $script:loginPerformed | Should -BeTrue
    }

    It 'falls back to the most recent manifest tag when latest is missing for mediaformat' {
        [System.Environment]::SetEnvironmentVariable('AZURE_TENANT_ID', '51835014-d218-4754-b420-16de4790eedf', 'Process')

        $script:acrPulledImages = [System.Collections.Generic.List[string]]::new()
        $manifestRows = @(
            [PSCustomObject]@{ tag = '20260420.1'; lastUpdateTime = '2026-04-20T10:00:00Z'; createdTime = '2026-04-20T10:00:00Z'; includeTagsProperty = $true }
            [PSCustomObject]@{ tag = '20260427.1'; lastUpdateTime = '2026-04-27T06:14:42.262942Z'; createdTime = '2026-04-27T06:14:42.262942Z'; includeTagsProperty = $true }
            [PSCustomObject]@{ tag = '20260301.5'; lastUpdateTime = '2026-03-01T12:00:00Z'; createdTime = '2026-03-01T12:00:00Z'; includeTagsProperty = $true }
            [PSCustomObject]@{ tag = ''; lastUpdateTime = '2026-05-01T00:00:00Z'; createdTime = '2026-05-01T00:00:00Z'; includeTagsProperty = $false }
        )

        $manifestRowsWithOrdering = @($manifestRows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.tag) } | ForEach-Object {
                $effectiveTimestampText = [string]$_.lastUpdateTime
                if ([string]::IsNullOrWhiteSpace($effectiveTimestampText)) {
                    $effectiveTimestampText = [string]$_.createdTime
                }

                [PSCustomObject]@{
                    tag = [string]$_.tag
                    effectiveTimestamp = [DateTimeOffset]::Parse(
                        $effectiveTimestampText,
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
                    )
                }
            })

        $expectedFallbackRow = @($manifestRowsWithOrdering | Sort-Object -Property @{ Expression = { $_.effectiveTimestamp }; Descending = $true } | Select-Object -First 1)[0]
        $expectedFallbackTag = [string]$expectedFallbackRow.tag
        $expectedFallbackTimestampCore = @($manifestRowsWithOrdering | Where-Object { $_.tag -eq $expectedFallbackTag } | Select-Object -First 1)[0].effectiveTimestamp.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffff', [System.Globalization.CultureInfo]::InvariantCulture)

        Mock -CommandName Test-CommandExists -MockWith { $true }
        Mock -CommandName Get-AcrRegistryNetworkState -MockWith {
            @{ IsReachable = $true; LoginServer = 'acrpominishareddev.azurecr.io'; Addresses = @('10.1.0.6'); HasPrivateAddress = $true; Message = 'ok' }
        }
        Mock -CommandName docker -MockWith {
            $joined = ($args -join ' ')

            if ($joined -match '^info') {
                $global:LASTEXITCODE = 0
                return 'Docker is running'
            }

            if ($joined -match '^pull\s+(?<image>.+)$') {
                $image = [string]$Matches['image']
                $script:acrPulledImages.Add($image)

                if ($image -eq 'acrpominishareddev.azurecr.io/mediaformat') {
                    $global:LASTEXITCODE = 1
                    return 'Error response from daemon: manifest for acrpominishareddev.azurecr.io/mediaformat:latest not found: manifest unknown'
                }

                if ($image -eq "acrpominishareddev.azurecr.io/mediaformat:$expectedFallbackTag") {
                    $global:LASTEXITCODE = 0
                    return 'Downloaded newer image'
                }
            }

            $global:LASTEXITCODE = 0
            return ''
        }
        Mock -CommandName az -MockWith {
            $joined = ($args -join ' ').ToLowerInvariant()
            $global:LASTEXITCODE = 0

            if ($joined -match '^account show') {
                return '{"tenantId":"51835014-d218-4754-b420-16de4790eedf"}'
            }

            if ($joined -match '^acr check-health') {
                return 'Challenge endpoint https://acrpominishareddev.azurecr.io/v2/ : OK`nFetch access token successfully for acrpominishareddev.azurecr.io : OK'
            }

            if ($joined -match '^acr repository list') {
                return 'mediaformat'
            }

            if ($joined -match '^acr repository show-tags') {
                return '20260427.1'
            }

            if ($joined -match '^acr login --name') {
                return 'Login Succeeded'
            }

            if ($joined -match '^acr manifest list-metadata') {
                return @(
                    $manifestRows | ForEach-Object {
                        $manifestObject = @{
                            Registry = 'acrpominishareddev'
                            Repository = 'mediaformat'
                            createdTime = $_.createdTime
                            lastUpdateTime = $_.lastUpdateTime
                        }

                        if ($_.includeTagsProperty) {
                            $manifestObject.tags = @($_.tag)
                        }

                        $manifestObject
                    }
                ) | ConvertTo-Json -Depth 6
            }

            return ''
        }

        $config = @{ modules = @{ acr = @{ registries = @('acrpominishareddev'); imagesInclude = @('mediaformat'); imagesExclude = @(); retryCount = 1; retryDelaySeconds = 0 } } }
        $results = @(Invoke-AcrSync -Config $config -ProjectRoot $script:projectRoot)
        $successEntries = @($results | Where-Object { $_.Status -in @('ADDED', 'UPDATED', 'NONE') })

        (@($results | Where-Object { $_.Status -eq 'ERROR' })).Count | Should -Be 0
        $successEntries.Count | Should -Be 1
        $script:acrPulledImages | Should -Contain 'acrpominishareddev.azurecr.io/mediaformat'
        $script:acrPulledImages | Should -Contain "acrpominishareddev.azurecr.io/mediaformat:$expectedFallbackTag"
        $successEntries[0].Message | Should -Match ([regex]::Escape("Fallback tag selected: '$expectedFallbackTag'"))
        $successEntries[0].Message | Should -Match "last update: $([regex]::Escape($expectedFallbackTimestampCore))(?:Z|\+00:00)"
        $successEntries[0].Message | Should -Match 'source: lastUpdateTime'
    }
}

AfterAll {
    [System.Environment]::SetEnvironmentVariable('GITHUB_TOKEN', $script:originalGitHubToken, 'Process')
    [System.Environment]::SetEnvironmentVariable('AZURE_DEVOPS_PAT', $script:originalDevOpsPat, 'Process')
    [System.Environment]::SetEnvironmentVariable('AZURE_TENANT_ID', $script:originalTenantId, 'Process')

    $testRoot = Join-Path $env:TEMP 'dev-bootstrap-tests-sync-modules'
    if (Test-Path $testRoot) {
        Remove-Item -Path $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

