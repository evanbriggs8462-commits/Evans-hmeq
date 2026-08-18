[CmdletBinding()]
param(
    [switch]$InventoryOnly,
    [string]$EnvPath
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$checks = New-Object System.Collections.Generic.List[object]

function Add-Check {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Action
    )

    $checks.Add([pscustomobject]@{
        Check = $Name
        Status = $Status
        Action = $Action
    }) | Out-Null
}

if ($PSVersionTable.PSVersion -ge [version]"5.1") {
    Add-Check -Name "PowerShell 5.1+" -Status "PASS" -Action ""
}
else {
    Add-Check -Name "PowerShell 5.1+" -Status "FAIL" -Action "PowerShell 5.1 or later is required."
}

try {
    $syntaxErrors = New-Object System.Collections.Generic.List[string]
    foreach ($scriptFile in Get-ChildItem -LiteralPath $PSScriptRoot -Filter "*.ps1" -File) {
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $scriptFile.FullName,
            [ref]$tokens,
            [ref]$parseErrors
        ) | Out-Null
        foreach ($parseError in @($parseErrors)) {
            $syntaxErrors.Add(("{0}: {1}" -f $scriptFile.Name, $parseError.Message)) | Out-Null
        }
    }

    if ($syntaxErrors.Count -gt 0) {
        throw ($syntaxErrors -join "; ")
    }
    Add-Check -Name "PowerShell syntax" -Status "PASS" -Action ""
}
catch {
    Add-Check -Name "PowerShell syntax" -Status "FAIL" -Action $_.Exception.Message
}

try {
    Assert-ToolkitExecutionFilesClean
    Add-Check -Name "Reviewed execution files" -Status "PASS" -Action ""
}
catch {
    Add-Check -Name "Reviewed execution files" -Status "FAIL" -Action $_.Exception.Message
}

try {
    Import-ToolkitEnvironment -EnvPath $EnvPath
    Add-Check -Name ".env" -Status "PASS" -Action ""
}
catch {
    Add-Check -Name ".env" -Status "FAIL" -Action $_.Exception.Message
}

if (($checks | Where-Object { $_.Check -eq ".env" }).Status -eq "PASS") {
    try {
        Assert-ExecutableFile `
            -Path $env:TE2_EXE_PATH `
            -VariableName "TE2_EXE_PATH" `
            -ExpectedFileName "TabularEditor.exe"
        Assert-MinimumFileVersion `
            -Path $env:TE2_EXE_PATH `
            -MinimumVersion ([version]"2.28.0") `
            -ProductName "Tabular Editor 2"
        Add-Check -Name "Tabular Editor 2" -Status "PASS" -Action ""
    }
    catch {
        Add-Check -Name "Tabular Editor 2" -Status "FAIL" -Action $_.Exception.Message
    }

    if ($InventoryOnly) {
        Add-Check -Name "DAX Studio dscmd" -Status "SKIP" -Action "Inventory-only preflight"
    }
    else {
        try {
            Assert-ExecutableFile `
                -Path $env:DSCMD_EXE_PATH `
                -VariableName "DSCMD_EXE_PATH" `
                -ExpectedFileName "dscmd.exe"
            Assert-MinimumFileVersion `
                -Path $env:DSCMD_EXE_PATH `
                -MinimumVersion ([version]"3.3.0") `
                -ProductName "DAX Studio"
            Add-Check -Name "DAX Studio dscmd" -Status "PASS" -Action ""
        }
        catch {
            Add-Check -Name "DAX Studio dscmd" -Status "FAIL" -Action $_.Exception.Message
        }
    }

    try {
        $evidenceRoot = Get-ConfiguredEvidenceRoot
        New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
        $probe = Join-Path $evidenceRoot ("toolkit_write_test_{0}.tmp" -f [guid]::NewGuid().ToString("N"))
        try {
            [System.IO.File]::WriteAllText($probe, "ok")
        }
        finally {
            if (Test-Path -LiteralPath $probe -PathType Leaf) {
                Remove-Item -LiteralPath $probe -Force
            }
        }
        Add-Check -Name "Evidence folder" -Status "PASS" -Action ""
    }
    catch {
        Add-Check -Name "Evidence folder" -Status "FAIL" -Action $_.Exception.Message
    }
}

foreach ($check in $checks) {
    if ([string]::IsNullOrWhiteSpace($check.Action)) {
        Write-Host ("[{0}] {1}" -f $check.Status, $check.Check)
    }
    else {
        Write-Host ("[{0}] {1}: {2}" -f $check.Status, $check.Check, $check.Action)
    }
}

if (@($checks | Where-Object { $_.Status -eq "FAIL" }).Count -gt 0) {
    throw "Toolkit preflight failed. Fix every FAIL result and rerun."
}

Write-Host "Toolkit preflight passed."
