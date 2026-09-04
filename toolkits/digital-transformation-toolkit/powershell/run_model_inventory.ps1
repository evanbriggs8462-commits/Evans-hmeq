[CmdletBinding(DefaultParameterSetName = "Desktop")]
param(
    [Parameter(Mandatory = $true, ParameterSetName = "Desktop")][string]$PbixName,
    [Parameter(Mandatory = $true, ParameterSetName = "Service")][string]$ModelServer,
    [Parameter(Mandatory = $true, ParameterSetName = "Service")][string]$ModelName,
    [string]$OutDir,
    [string]$EnvPath
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")
Import-ToolkitEnvironment -EnvPath $EnvPath

if ($PSCmdlet.ParameterSetName -eq "Desktop" -and
    ($PbixName -notmatch '(?i)\.pbix$' -or $PbixName -match '[\\/]')) {
    throw "PbixName must be the filename shown in Power BI Desktop, including .pbix and excluding its path."
}

if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $evidenceRoot = Get-ConfiguredEvidenceRoot
    $connectionName = if ($PSCmdlet.ParameterSetName -eq "Desktop") {
        [System.IO.Path]::GetFileNameWithoutExtension($PbixName)
    }
    else {
        $ModelName
    }
    $safeName = Get-SafeArtifactName -Value $connectionName
    $runName = "inventory_{0}_{1}" -f $safeName, (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss_fff")
    $OutDir = Join-Path $evidenceRoot $runName
}

$outputFullPath = Resolve-ToolkitOutputPath -Path $OutDir
New-Item -ItemType Directory -Path $outputFullPath -Force | Out-Null

$expectedArtifacts = @(
    [pscustomobject]@{ Name = "tables.csv"; Header = '"Table","ObjectType","IsHidden","Description"' },
    [pscustomobject]@{ Name = "measures.csv"; Header = '"Table","Measure","DisplayFolder","FormatString","IsHidden","Description","Expression"' },
    [pscustomobject]@{ Name = "columns.csv"; Header = '"Table","Column","ColumnType","DataType","IsHidden","DisplayFolder","SortByColumn","Description","Expression"' },
    [pscustomobject]@{ Name = "relationships.csv"; Header = '"FromTable","FromColumn","ToTable","ToColumn","IsActive","CrossFilteringBehavior"' },
    [pscustomobject]@{ Name = "partitions.csv"; Header = '"Table","Partition","Mode","SourceType","Expression"' },
    [pscustomobject]@{ Name = "expressions.csv"; Header = '"Expression","Kind","Description","Definition"' }
)

$manifestPath = Join-Path $outputFullPath "inventory_manifest.json"
foreach ($artifact in $expectedArtifacts) {
    Remove-StaleFile -Path (Join-Path $outputFullPath $artifact.Name)
}
Remove-StaleFile -Path $manifestPath

$invokeParameters = @{
    ScriptPath = Join-Path (Get-ToolkitRoot) "te2\readonly\export_model_inventory.csx"
    OutputDirectory = $outputFullPath
    EnvPath = $EnvPath
}
$exporterPath = $invokeParameters.ScriptPath
$exporterHashBefore = (Get-FileHash -LiteralPath $exporterPath -Algorithm SHA256).Hash
if ($PSCmdlet.ParameterSetName -eq "Desktop") {
    $invokeParameters.PbixName = $PbixName
}
else {
    $invokeParameters.ModelServer = $ModelServer
    $invokeParameters.ModelName = $ModelName
}

& (Join-Path $PSScriptRoot "invoke_te2_readonly.ps1") @invokeParameters

$te2Version = Get-ExecutableFileVersion `
    -Path $env:TE2_EXE_PATH `
    -ProductName "Tabular Editor 2"
$exporterHashAfter = (Get-FileHash -LiteralPath $exporterPath -Algorithm SHA256).Hash
if ($exporterHashAfter -ne $exporterHashBefore) {
    throw "The Tabular Editor exporter changed during execution. Discard the output and rerun after review."
}

$artifacts = New-Object System.Collections.Generic.List[object]
foreach ($expected in $expectedArtifacts) {
    $path = Join-Path $outputFullPath $expected.Name
    Assert-NonEmptyFile -Path $path

    $header = Get-Content -LiteralPath $path -TotalCount 1
    if ($header -ne $expected.Header) {
        throw "Unexpected CSV header in $($expected.Name)."
    }

    try {
        $rowCount = @(Import-Csv -LiteralPath $path).Count
    }
    catch {
        throw "CSV validation failed for $($expected.Name): $($_.Exception.Message)"
    }

    $item = Get-Item -LiteralPath $path
    $hash = Get-FileHash -LiteralPath $path -Algorithm SHA256
    $artifacts.Add([pscustomobject]@{
        name = $expected.Name
        rowCount = $rowCount
        bytes = $item.Length
        sha256 = $hash.Hash
    }) | Out-Null
}

$connection = if ($PSCmdlet.ParameterSetName -eq "Desktop") {
    [ordered]@{
        type = "power-bi-desktop"
        pbixName = $PbixName
    }
}
else {
    [ordered]@{
        type = "xmla"
        server = $ModelServer
        model = $ModelName
    }
}

$manifest = [ordered]@{
    schemaVersion = 1
    status = "succeeded"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    toolkitCommit = Get-ToolkitCommit
    tool = [ordered]@{
        name = "Tabular Editor 2"
        version = $te2Version
    }
    exporter = [ordered]@{
        path = "te2/readonly/export_model_inventory.csx"
        sha256 = $exporterHashBefore
    }
    connection = $connection
    artifacts = @($artifacts)
}

$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Assert-NonEmptyFile -Path $manifestPath
$verifiedManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($verifiedManifest.status -ne "succeeded" -or
    $verifiedManifest.exporter.sha256 -ne $exporterHashBefore -or
    @($verifiedManifest.artifacts).Count -ne 6) {
    throw "Inventory manifest validation failed."
}

Write-Host "Inventory complete: $outputFullPath"
foreach ($artifact in $artifacts) {
    Write-Host ("- {0}: {1} rows" -f $artifact.name, $artifact.rowCount)
}
Write-Output $manifestPath
