Set-StrictMode -Version 2.0

$script:ToolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

function Get-ToolkitRoot {
    return $script:ToolkitRoot
}

function Import-ToolkitEnvironment {
    [CmdletBinding()]
    param([string]$EnvPath)

    if ([string]::IsNullOrWhiteSpace($EnvPath)) {
        $EnvPath = Join-Path $script:ToolkitRoot ".env"
    }
    elseif (-not [System.IO.Path]::IsPathRooted($EnvPath)) {
        $EnvPath = Join-Path $script:ToolkitRoot $EnvPath
    }

    $EnvPath = [System.IO.Path]::GetFullPath($EnvPath)
    if (-not (Test-Path -LiteralPath $EnvPath -PathType Leaf)) {
        throw ".env not found. Copy templates\.env.example to .env and configure it."
    }

    $allowedNames = @("TE2_EXE_PATH", "DSCMD_EXE_PATH", "EVIDENCE_ROOT")
    foreach ($line in Get-Content -LiteralPath $EnvPath) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
            continue
        }

        $separator = $trimmed.IndexOf("=")
        if ($separator -lt 1) {
            throw "Invalid .env entry. Expected NAME=value."
        }

        $name = $trimmed.Substring(0, $separator).Trim()
        $value = $trimmed.Substring($separator + 1).Trim()
        if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw "Invalid environment variable name in .env."
        }
        if ($allowedNames -notcontains $name) {
            throw "Unsupported .env entry: $name. Only local tool and evidence paths are allowed."
        }

        if ($value.Length -ge 2) {
            $first = $value.Substring(0, 1)
            $last = $value.Substring($value.Length - 1, 1)
            if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }

        $value = [System.Environment]::ExpandEnvironmentVariables($value)
        [System.Environment]::SetEnvironmentVariable($name, $value, "Process")
    }
}

function Resolve-ToolkitInputPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        $Path = Join-Path $script:ToolkitRoot $Path
    }

    return [System.IO.Path]::GetFullPath($Path)
}

function Resolve-ToolkitOutputPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        throw "Output paths must be absolute and outside the repository."
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = $script:ToolkitRoot.TrimEnd([char[]]@('\', '/'))
    $prefix = $root + [System.IO.Path]::DirectorySeparatorChar

    if ($fullPath.Equals($root, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Output path must be outside the repository: $fullPath"
    }

    return $fullPath
}

function Get-ConfiguredEvidenceRoot {
    if ([string]::IsNullOrWhiteSpace($env:EVIDENCE_ROOT)) {
        throw "EVIDENCE_ROOT is missing from .env."
    }

    return Resolve-ToolkitOutputPath -Path $env:EVIDENCE_ROOT
}

function Assert-ExecutableFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$VariableName,
        [string]$ExpectedFileName
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$VariableName is missing from .env."
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$VariableName does not point to an executable file."
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedFileName) -and
        -not [System.IO.Path]::GetFileName($Path).Equals(
            $ExpectedFileName,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw "$VariableName must point to $ExpectedFileName."
    }
}

function Assert-ToolkitExecutionFilesClean {
    $gitCommand = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $gitCommand) {
        throw "Git is required to verify the toolkit execution files."
    }

    $statusOutput = @(
        & $gitCommand.Source `
            -C $script:ToolkitRoot `
            status `
            --porcelain `
            --untracked-files=all `
            -- `
            powershell `
            te2/readonly `
            dax/queries/connection_test.dax 2>&1
    )
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to verify the toolkit execution files with Git."
    }
    if ($statusOutput.Count -gt 0) {
        throw "Toolkit execution files differ from the checked-out commit. Restore or commit reviewed changes before running."
    }
}

function Assert-MinimumFileVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][version]$MinimumVersion,
        [Parameter(Mandatory = $true)][string]$ProductName
    )

    $installedVersion = [version](Get-ExecutableFileVersion -Path $Path -ProductName $ProductName)
    if ($installedVersion -lt $MinimumVersion) {
        throw "$ProductName $MinimumVersion or later is required."
    }
}

function Get-ExecutableFileVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ProductName
    )

    $versionText = (Get-Item -LiteralPath $Path).VersionInfo.FileVersion
    $match = [regex]::Match($versionText, '\d+(?:\.\d+){1,3}')
    if (-not $match.Success) {
        throw "Unable to verify the $ProductName version."
    }

    return $match.Value
}

function Get-ToolkitCommit {
    $gitCommand = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $gitCommand) {
        throw "Git is required to record the toolkit commit."
    }

    $commit = (& $gitCommand.Source -C $script:ToolkitRoot rev-parse HEAD 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-fA-F]{40}$') {
        throw "Unable to record the toolkit commit."
    }

    return $commit.ToLowerInvariant()
}

function Quote-NativeArgument {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value.Contains('"')) {
        throw "A native command argument contains an unsupported quote character."
    }

    return '"' + $Value + '"'
}

function Remove-StaleFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Remove-Item -LiteralPath $Path -Force
    }
}

function Assert-NonEmptyFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Expected output was not created: $Path"
    }

    $item = Get-Item -LiteralPath $Path
    if ($item.Length -le 0) {
        throw "Expected output is empty: $Path"
    }
}

function Get-SafeArtifactName {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Value)

    $safe = [regex]::Replace($Value, '[^A-Za-z0-9._-]+', '_').Trim([char[]]@('_', '.'))
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return "model"
    }

    return $safe
}
