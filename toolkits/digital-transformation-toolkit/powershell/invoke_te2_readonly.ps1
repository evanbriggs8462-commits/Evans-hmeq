[CmdletBinding(DefaultParameterSetName = "Desktop")]
param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [Parameter(Mandatory = $true, ParameterSetName = "Desktop")][string]$PbixName,
    [Parameter(Mandatory = $true, ParameterSetName = "Service")][string]$ModelServer,
    [Parameter(Mandatory = $true, ParameterSetName = "Service")][string]$ModelName,
    [string]$EnvPath
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")
Import-ToolkitEnvironment -EnvPath $EnvPath

$scriptFullPath = Resolve-ToolkitInputPath -Path $ScriptPath
$allowedScript = [System.IO.Path]::GetFullPath(
    (Join-Path (Get-ToolkitRoot) "te2\readonly\export_model_inventory.csx")
)

if (-not $scriptFullPath.Equals($allowedScript, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "The TE2 wrapper only permits te2\readonly\export_model_inventory.csx."
}
if (-not (Test-Path -LiteralPath $scriptFullPath -PathType Leaf)) {
    throw "TE2 script not found."
}

Assert-ToolkitExecutionFilesClean

$outputFullPath = Resolve-ToolkitOutputPath -Path $OutputDirectory
New-Item -ItemType Directory -Path $outputFullPath -Force | Out-Null

Assert-ExecutableFile `
    -Path $env:TE2_EXE_PATH `
    -VariableName "TE2_EXE_PATH" `
    -ExpectedFileName "TabularEditor.exe"
Assert-MinimumFileVersion `
    -Path $env:TE2_EXE_PATH `
    -MinimumVersion ([version]"2.28.0") `
    -ProductName "Tabular Editor 2"
$te2 = $env:TE2_EXE_PATH

# TE2 syntax is: TabularEditor (server database | -L name) -S script.
# Do not add deployment, build, processing, or BPA switches here.
$nativeArguments = New-Object System.Collections.Generic.List[string]
if ($PSCmdlet.ParameterSetName -eq "Desktop") {
    if ($PbixName -notmatch '(?i)\.pbix$' -or $PbixName -match '[\\/]') {
        throw "PbixName must be the filename shown in Power BI Desktop, including .pbix and excluding its path."
    }
    $nativeArguments.Add("-L")
    $nativeArguments.Add((Quote-NativeArgument -Value $PbixName))
}
else {
    $nativeArguments.Add((Quote-NativeArgument -Value $ModelServer))
    $nativeArguments.Add((Quote-NativeArgument -Value $ModelName))
}
$nativeArguments.Add("-S")
$nativeArguments.Add((Quote-NativeArgument -Value $scriptFullPath))

$previousOutputDirectory = [System.Environment]::GetEnvironmentVariable("TE2_OUTPUT_DIR", "Process")
[System.Environment]::SetEnvironmentVariable("TE2_OUTPUT_DIR", $outputFullPath, "Process")

try {
    $process = Start-Process `
        -FilePath $te2 `
        -ArgumentList ($nativeArguments -join " ") `
        -WorkingDirectory (Get-ToolkitRoot) `
        -NoNewWindow `
        -Wait `
        -PassThru

    if ($process.ExitCode -ne 0) {
        throw "Tabular Editor exited with code $($process.ExitCode)."
    }
}
finally {
    [System.Environment]::SetEnvironmentVariable(
        "TE2_OUTPUT_DIR",
        $previousOutputDirectory,
        "Process"
    )
}
