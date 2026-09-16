#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0' }

BeforeAll {
    if ([string]::IsNullOrWhiteSpace($env:TEMP)) {
        $env:TEMP = [System.IO.Path]::GetTempPath()
    }

    $projectRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $projectRoot 'src' 'common' 'Logger.ps1')
    . (Join-Path $projectRoot 'src' 'common' 'Filters.ps1')
    . (Join-Path $projectRoot 'src' 'common' 'Utilities.ps1')
    . (Join-Path $projectRoot 'src' 'modules' 'Sync-GitHubRepos.ps1')
    . (Join-Path $projectRoot 'src' 'modules' 'Sync-DevOpsRepos.ps1')
    . (Join-Path $projectRoot 'src' 'modules' 'Sync-AcrImages.ps1')

    $testLogDir = Join-Path $env:TEMP 'dev-bootstrap-tests-filters' 'log'
    Initialize-Logger -LogDirectory $testLogDir -Level 'Error' -Silent | Out-Null

    $script:originalDevOpsOrgs = [System.Environment]::GetEnvironmentVariable('AZURE_DEVOPS_ORGS', 'Process')
}

Describe 'GitHub include/exclude filters' {
    It 'includes all user repositories with wildcard include' {
        Test-IncludeExcludeMatch -Name 'exampleUser' -IncludeTokens @('*') -ExcludeTokens @() | Should -BeTrue
    }

    It 'excludes a user when present in exclude list' {
        Test-IncludeExcludeMatch -Name 'exampleUser' -IncludeTokens @('*') -ExcludeTokens @('exampleUser') | Should -BeFalse
    }

    It 'includes only explicitly listed users without wildcard' {
        Test-IncludeExcludeMatch -Name 'exampleUser' -IncludeTokens @('exampleUser') -ExcludeTokens @() | Should -BeTrue
        Test-IncludeExcludeMatch -Name 'other' -IncludeTokens @('exampleUser') -ExcludeTokens @() | Should -BeFalse
    }

    It 'gives precedence to exclude in ambiguous include/exclude overlap' {
        Test-IncludeExcludeMatch -Name 'exampleUser' -IncludeTokens @('*', 'exampleUser') -ExcludeTokens @('exampleUser') | Should -BeFalse
    }

    It 'applies user and organization filters by owner type' {
        $userRepo = [pscustomobject]@{
            owner = [pscustomobject]@{ login = 'exampleUser'; type = 'User' }
        }
        $orgRepo = [pscustomobject]@{
            owner = [pscustomobject]@{ login = 'my-org'; type = 'Organization' }
        }

        $config = @{
            usersInclude = @('*')
            usersExclude = @('exampleUser')
            organizationsInclude = @('my-org')
            organizationsExclude = @()
        }

        (Test-GitHubRepoIncluded -Repo $userRepo -Config $config) | Should -BeFalse
        (Test-GitHubRepoIncluded -Repo $orgRepo -Config $config) | Should -BeTrue
    }
}

Describe 'DevOps include/exclude filters' {
    It 'includes all projects with wildcard include' {
        Test-DevOpsIncludeExcludeMatch -Name 'platform' -IncludeTokens @('*') -ExcludeTokens @() | Should -BeTrue
    }

    It 'excludes project when listed in exclude' {
        Test-DevOpsIncludeExcludeMatch -Name 'platform' -IncludeTokens @('*') -ExcludeTokens @('platform') | Should -BeFalse
    }

    It 'filters to explicitly listed projects' {
        Test-DevOpsIncludeExcludeMatch -Name 'platform' -IncludeTokens @('platform') -ExcludeTokens @() | Should -BeTrue
        Test-DevOpsIncludeExcludeMatch -Name 'legacy' -IncludeTokens @('platform') -ExcludeTokens @() | Should -BeFalse
    }
}

Describe 'ACR include/exclude filters' {
    It 'includes all images with wildcard include' {
        Test-AcrIncludeExcludeMatch -Name 'platform-api' -IncludeTokens @('*') -ExcludeTokens @() | Should -BeTrue
    }

    It 'excludes image when listed in exclude' {
        Test-AcrIncludeExcludeMatch -Name 'platform-api' -IncludeTokens @('*') -ExcludeTokens @('platform-api') | Should -BeFalse
    }

    It 'filters to explicitly listed images' {
        Test-AcrIncludeExcludeMatch -Name 'platform-api' -IncludeTokens @('platform-api') -ExcludeTokens @() | Should -BeTrue
        Test-AcrIncludeExcludeMatch -Name 'legacy-api' -IncludeTokens @('platform-api') -ExcludeTokens @() | Should -BeFalse
    }
}

Describe 'DevOps organization resolution' {
    It 'parses organizations from AZURE_DEVOPS_ORGS' {
        [System.Environment]::SetEnvironmentVariable('AZURE_DEVOPS_ORGS', 'org-one, org-two', 'Process')
        $orgs = Resolve-DevOpsOrganizations -ModuleConfig @{}
        $orgs | Should -Be @('org-one', 'org-two')
    }

    It 'returns empty list when AZURE_DEVOPS_ORGS is missing' {
        [System.Environment]::SetEnvironmentVariable('AZURE_DEVOPS_ORGS', $null, 'Process')
        $orgs = Resolve-DevOpsOrganizations -ModuleConfig @{}
        $orgs.Count | Should -Be 0
    }
}

AfterAll {
    [System.Environment]::SetEnvironmentVariable('AZURE_DEVOPS_ORGS', $script:originalDevOpsOrgs, 'Process')

    $testRoot = Join-Path $env:TEMP 'dev-bootstrap-tests-filters'
    if (Test-Path $testRoot) {
        Remove-Item -Path $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
