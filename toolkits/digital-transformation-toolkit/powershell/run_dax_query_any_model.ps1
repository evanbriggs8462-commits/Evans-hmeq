[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$QueryFile,
    [Parameter(Mandatory = $true)][string]$Server,
    [string]$Database,
    [string]$OutputCsv,
    [string]$EnvPath
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")
Import-ToolkitEnvironment -EnvPath $EnvPath
Assert-ToolkitExecutionFilesClean

$queryFullPath = Resolve-ToolkitInputPath -Path $QueryFile
if (-not (Test-Path -LiteralPath $queryFullPath -PathType Leaf)) {
    throw "DAX query file not found."
}

$queryText = Get-Content -LiteralPath $queryFullPath -Raw
if ($queryText -match '@@[A-Z0-9_]+@@') {
    throw "DAX query contains unresolved template tokens."
}
$queryHashBefore = (Get-FileHash -LiteralPath $queryFullPath -Algorithm SHA256).Hash
$connectionTestPath = [System.IO.Path]::GetFullPath(
    (Join-Path (Get-ToolkitRoot) "dax\queries\connection_test.dax")
)
$isConnectionTest = $queryFullPath.Equals(
    $connectionTestPath,
    [System.StringComparison]::OrdinalIgnoreCase
)
$toolkitRoot = (Get-ToolkitRoot).TrimEnd([char[]]@('\', '/'))
$toolkitPrefix = $toolkitRoot + [System.IO.Path]::DirectorySeparatorChar
$queryIsInsideToolkit = $queryFullPath.Equals(
    $toolkitRoot,
    [System.StringComparison]::OrdinalIgnoreCase
) -or $queryFullPath.StartsWith(
    $toolkitPrefix,
    [System.StringComparison]::OrdinalIgnoreCase
)
if (-not $isConnectionTest -and $queryIsInsideToolkit) {
    throw "Non-test DAX queries must be reviewed copies outside the repository, normally under EVIDENCE_ROOT."
}

$isDesktopConnection = $Server -match '(?i)\.(pbix|pbip)$' -or $Server -match '(?i)^localhost:\d+$'
if ($Server -match '(?i)\.(pbix|pbip)$' -and $Server -match '[\\/]') {
    throw "For Power BI Desktop, Server must be the filename without its path."
}
if (-not $isDesktopConnection -and [string]::IsNullOrWhiteSpace($Database)) {
    throw "Database is required for every connection except Power BI Desktop."
}

if ([string]::IsNullOrWhiteSpace($OutputCsv)) {
    $evidenceRoot = Get-ConfiguredEvidenceRoot
    $outputName = "dax_query_{0}.csv" -f (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss_fff")
    $OutputCsv = Join-Path $evidenceRoot $outputName
}

$outputFullPath = Resolve-ToolkitOutputPath -Path $OutputCsv
if ([System.IO.Path]::GetExtension($outputFullPath) -ne ".csv") {
    throw "OutputCsv must use a .csv extension."
}

$outputDirectory = Split-Path -Parent $outputFullPath
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
Remove-StaleFile -Path $outputFullPath

$manifestPath = [System.IO.Path]::ChangeExtension($outputFullPath, ".manifest.json")
Remove-StaleFile -Path $manifestPath

Assert-ExecutableFile `
    -Path $env:DSCMD_EXE_PATH `
    -VariableName "DSCMD_EXE_PATH" `
    -ExpectedFileName "dscmd.exe"
Assert-MinimumFileVersion `
    -Path $env:DSCMD_EXE_PATH `
    -MinimumVersion ([version]"3.3.0") `
    -ProductName "DAX Studio"
$daxStudioVersion = Get-ExecutableFileVersion `
    -Path $env:DSCMD_EXE_PATH `
    -ProductName "DAX Studio"
# -f passes a query file. -q would treat the path itself as inline DAX.
$arguments = @("csv", $outputFullPath, "-s", $Server)
if (-not [string]::IsNullOrWhiteSpace($Database)) {
    $arguments += @("-d", $Database)
}
$arguments += @("-f", $queryFullPath)

$toolOutput = & $env:DSCMD_EXE_PATH @arguments 2>&1 | Out-String
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    throw "dscmd failed with exit code $exitCode. $($toolOutput.Trim())"
}

Assert-NonEmptyFile -Path $outputFullPath
$listSeparator = [System.Globalization.CultureInfo]::CurrentUICulture.TextInfo.ListSeparator
if ([string]::IsNullOrWhiteSpace($listSeparator) -or $listSeparator.Length -ne 1) {
    throw "The current Windows list separator is not supported for CSV validation."
}
$delimiter = [char]$listSeparator
try {
    $rows = @(Import-Csv -LiteralPath $outputFullPath -Delimiter $delimiter)
    $rowCount = $rows.Count
}
catch {
    throw "DAX output CSV validation failed: $($_.Exception.Message)"
}

if ($isConnectionTest) {
    if ($rows.Count -ne 1) {
        throw "DAX connection test returned an unexpected row count."
    }
    $connectionProperty = $rows[0].PSObject.Properties |
        Where-Object { $_.Name.Trim([char[]]@('[', ']')) -eq "ToolkitConnection" } |
        Select-Object -First 1
    if ($null -eq $connectionProperty -or $connectionProperty.Value -ne "OK") {
        throw "DAX connection test did not return ToolkitConnection=OK."
    }
}

$queryHashAfter = (Get-FileHash -LiteralPath $queryFullPath -Algorithm SHA256).Hash
if ($queryHashAfter -ne $queryHashBefore) {
    throw "The DAX query file changed during execution. Discard the output and rerun after review."
}

$item = Get-Item -LiteralPath $outputFullPath
$hash = Get-FileHash -LiteralPath $outputFullPath -Algorithm SHA256
$connection = if ([string]::IsNullOrWhiteSpace($Database)) {
    [ordered]@{ server = $Server }
}
else {
    [ordered]@{ server = $Server; database = $Database }
}

$manifest = [ordered]@{
    schemaVersion = 1
    status = "succeeded"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    toolkitCommit = Get-ToolkitCommit
    tool = [ordered]@{
        name = "DAX Studio dscmd"
        version = $daxStudioVersion
    }
    connection = $connection
    query = [ordered]@{
        path = $queryFullPath
        sha256 = $queryHashBefore
    }
    validation = [ordered]@{
        connectionTest = if ($isConnectionTest) { "passed" } else { "not-applicable" }
    }
    output = [ordered]@{
        name = [System.IO.Path]::GetFileName($outputFullPath)
        delimiter = $listSeparator
        rowCount = $rowCount
        bytes = $item.Length
        sha256 = $hash.Hash
    }
}

$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Assert-NonEmptyFile -Path $manifestPath
$verifiedManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($verifiedManifest.status -ne "succeeded" -or
    $verifiedManifest.query.sha256 -ne $queryHashBefore -or
    $verifiedManifest.output.sha256 -ne $hash.Hash) {
    throw "DAX manifest validation failed."
}

Write-Host "DAX export complete: $outputFullPath"
Write-Host "Rows: $rowCount"
Write-Output $manifestPath
