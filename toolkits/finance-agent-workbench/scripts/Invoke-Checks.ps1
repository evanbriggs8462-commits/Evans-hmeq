#requires -Version 5.1

[CmdletBinding()]
param(
    [switch] $SkipPython,
    [switch] $SkipPowerShell
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:IsInvokeChecksDotSourced = ($MyInvocation.InvocationName -eq '.')

function Get-SafePropertyValue {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    if ($null -eq $InputObject) {
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Get-FirstNumericProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $InputObject,

        [Parameter(Mandatory = $true)]
        [string[]] $Names
    )

    foreach ($name in $Names) {
        $property = $InputObject.PSObject.Properties[$name]
        if ($null -eq $property -or $null -eq $property.Value) {
            continue
        }
        try {
            return [pscustomobject]@{
                Found = $true
                Name  = $name
                Value = [int64] $property.Value
            }
        }
        catch {
            continue
        }
    }

    return [pscustomobject]@{
        Found = $false
        Name  = $null
        Value = $null
    }
}

function Get-SafeCollectionCount {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) {
        return [int64] 0
    }
    if ($Value -is [string]) {
        return [int64] 1
    }
    if ($Value -is [System.Collections.ICollection]) {
        return [int64] $Value.Count
    }
    return [int64] (@($Value).Count)
}

function Get-PesterContainerFailureSignals {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $PesterResult
    )

    $failureSignals = [int64] 0
    $errorRecords = [int64] 0
    $containers = @(Get-SafePropertyValue -InputObject $PesterResult -Name 'Containers')
    foreach ($container in $containers) {
        if ($null -eq $container) {
            continue
        }
        $containerResult = Get-SafePropertyValue -InputObject $container -Name 'Result'
        if ($null -ne $containerResult -and
            [string]::Equals($containerResult.ToString(), 'Failed',
                [System.StringComparison]::OrdinalIgnoreCase)) {
            $failureSignals++
        }

        $containerErrors = Get-SafePropertyValue -InputObject $container -Name 'ErrorRecord'
        $errorRecords += Get-SafeCollectionCount -Value $containerErrors
    }

    return [pscustomobject]@{
        FailureSignals = $failureSignals
        ErrorRecords   = $errorRecords
    }
}

function Test-PesterRunResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $PesterResult
    )

    $reasons = New-Object System.Collections.Generic.List[string]

    $runResultValue = Get-SafePropertyValue -InputObject $PesterResult -Name 'Result'
    $runResultText = $null
    if ($null -ne $runResultValue) {
        $runResultText = $runResultValue.ToString()
    }
    if (-not [string]::Equals($runResultText, 'Passed',
        [System.StringComparison]::OrdinalIgnoreCase)) {
        [void] $reasons.Add('Pester Result was not Passed.')
    }

    $total = Get-FirstNumericProperty -InputObject $PesterResult `
        -Names @('TotalCount', 'DiscoveredCount')
    $passed = Get-FirstNumericProperty -InputObject $PesterResult `
        -Names @('PassedCount')
    $failed = Get-FirstNumericProperty -InputObject $PesterResult `
        -Names @('FailedCount')
    $skipped = Get-FirstNumericProperty -InputObject $PesterResult `
        -Names @('SkippedCount')
    $notRun = Get-FirstNumericProperty -InputObject $PesterResult `
        -Names @('NotRunCount')
    $executed = Get-FirstNumericProperty -InputObject $PesterResult `
        -Names @('ExecutedCount')

    $testsValue = Get-SafePropertyValue -InputObject $PesterResult -Name 'Tests'
    $testsCount = Get-SafeCollectionCount -Value $testsValue
    $discoveredCount = $null
    $discoveredCountSource = $null
    if ($total.Found) {
        $discoveredCount = [int64] $total.Value
        $discoveredCountSource = $total.Name
    }
    elseif ($null -ne $testsValue) {
        $discoveredCount = [int64] $testsCount
        $discoveredCountSource = 'Tests.Count'
    }

    $executedCount = $null
    $executedCountSource = $null
    if ($executed.Found) {
        $executedCount = [int64] $executed.Value
        $executedCountSource = $executed.Name
    }
    elseif ($passed.Found -and $failed.Found) {
        # Skipped and NotRun tests do not prove that a test body executed.
        $executedCount = ([int64] $passed.Value + [int64] $failed.Value)
        $executedCountSource = 'PassedCount+FailedCount'
    }
    elseif ($null -ne $testsValue) {
        $executedFromTests = [int64] 0
        foreach ($test in @($testsValue)) {
            $testExecuted = Get-SafePropertyValue -InputObject $test -Name 'Executed'
            if ($null -ne $testExecuted -and [bool] $testExecuted) {
                $executedFromTests++
            }
        }
        $executedCount = $executedFromTests
        $executedCountSource = 'Tests.Executed'
    }
    elseif ($total.Found -and $skipped.Found -and $notRun.Found) {
        $executedCount = [Math]::Max(
            [int64] 0,
            ([int64] $total.Value - [int64] $skipped.Value - [int64] $notRun.Value)
        )
        $executedCountSource = 'TotalCount-SkippedCount-NotRunCount'
    }

    $failedContainers = Get-FirstNumericProperty -InputObject $PesterResult `
        -Names @('FailedContainersCount', 'FailedContainerCount')
    $failedBlocks = Get-FirstNumericProperty -InputObject $PesterResult `
        -Names @('FailedBlocksCount', 'FailedBlockCount')
    $failedContainersCollection = Get-SafePropertyValue `
        -InputObject $PesterResult -Name 'FailedContainers'
    $failedBlocksCollection = Get-SafePropertyValue `
        -InputObject $PesterResult -Name 'FailedBlocks'
    $failedContainerCount = Get-SafeCollectionCount -Value $failedContainersCollection
    $failedBlockCount = Get-SafeCollectionCount -Value $failedBlocksCollection
    if ($failedContainers.Found) {
        $failedContainerCount = [Math]::Max(
            [int64] $failedContainerCount,
            [int64] $failedContainers.Value
        )
    }
    if ($failedBlocks.Found) {
        $failedBlockCount = [Math]::Max(
            [int64] $failedBlockCount,
            [int64] $failedBlocks.Value
        )
    }
    $containerSignals = Get-PesterContainerFailureSignals -PesterResult $PesterResult

    if (-not $failed.Found) {
        [void] $reasons.Add('Pester FailedCount evidence was unavailable.')
    }
    elseif ([int64] $failed.Value -gt 0) {
        [void] $reasons.Add('One or more Pester tests failed.')
    }
    if ($failedContainerCount -gt 0 -or
        $containerSignals.FailureSignals -gt 0 -or
        $containerSignals.ErrorRecords -gt 0) {
        [void] $reasons.Add('Pester reported a discovery or container failure.')
    }
    if ($failedBlockCount -gt 0) {
        [void] $reasons.Add('Pester reported a block setup or teardown failure.')
    }
    if ($null -eq $discoveredCount -or $discoveredCount -le 0) {
        [void] $reasons.Add('Pester discovered zero tests or supplied no discovery count.')
    }
    if ($null -eq $executedCount -or $executedCount -le 0) {
        [void] $reasons.Add('Pester executed zero tests or supplied no execution evidence.')
    }

    $evidence = [ordered]@{
        run_result               = $runResultText
        discovered_count         = $discoveredCount
        discovered_count_source  = $discoveredCountSource
        executed_count           = $executedCount
        executed_count_source    = $executedCountSource
        passed_count             = if ($passed.Found) { $passed.Value } else { $null }
        failed_count             = if ($failed.Found) { $failed.Value } else { $null }
        skipped_count            = if ($skipped.Found) { $skipped.Value } else { $null }
        not_run_count            = if ($notRun.Found) { $notRun.Value } else { $null }
        failed_containers_count  = $failedContainerCount
        failed_blocks_count      = $failedBlockCount
        container_failure_signals = $containerSignals.FailureSignals
        container_error_records  = $containerSignals.ErrorRecords
    }

    return [pscustomobject]@{
        Passed   = ($reasons.Count -eq 0)
        Reasons  = @($reasons.ToArray())
        Evidence = [pscustomobject] $evidence
    }
}

if (-not $script:IsInvokeChecksDotSourced) {
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $failures = New-Object System.Collections.Generic.List[string]
    $pesterEvidence = $null

    Push-Location -LiteralPath $repositoryRoot
    try {
        if (-not $SkipPython) {
            $python = Get-Command python -ErrorAction SilentlyContinue
            if ($null -eq $python) {
                [void] $failures.Add('Python executable was not found.')
            }
            else {
                & $python.Source -m pytest
                $pythonExitCode = $LASTEXITCODE
                if ($pythonExitCode -ne 0) {
                    [void] $failures.Add("pytest exited with code $pythonExitCode.")
                }
            }
        }

        if (-not $SkipPowerShell) {
            $pester = Get-Module -ListAvailable -Name Pester |
                Where-Object { $_.Version.Major -ge 5 } |
                Sort-Object Version -Descending |
                Select-Object -First 1

            if ($null -eq $pester) {
                $pesterEvidence = [pscustomobject]@{ available = $false }
                [void] $failures.Add('Pester 5 or later is not installed; PowerShell tests were not run.')
            }
            else {
                try {
                    Import-Module $pester.Path -Force
                    $pesterResult = Invoke-Pester `
                        -Path (Join-Path $repositoryRoot 'tests/powershell') `
                        -PassThru
                    $pesterAssessment = Test-PesterRunResult -PesterResult $pesterResult
                    $pesterEvidence = $pesterAssessment.Evidence
                    if (-not $pesterAssessment.Passed) {
                        $pesterReasonText = $pesterAssessment.Reasons -join ' '
                        [void] $failures.Add("Pester validation was rejected: $pesterReasonText")
                    }
                }
                catch {
                    $pesterEvidence = [pscustomobject]@{
                        invocation_error_type = $_.Exception.GetType().FullName
                    }
                    [void] $failures.Add('Pester invocation terminated before a valid run result was returned.')
                }
            }
        }
    }
    finally {
        Pop-Location
    }

    $receipt = [ordered]@{
        ok = ($failures.Count -eq 0)
        stage = 'repository_validation'
        failure_count = $failures.Count
        pester = $pesterEvidence
    }
    [Console]::Out.WriteLine(($receipt | ConvertTo-Json -Depth 6 -Compress))

    if ($failures.Count -gt 0) {
        foreach ($failure in $failures) {
            [Console]::Error.WriteLine($failure)
        }
        exit 1
    }
    exit 0
}
