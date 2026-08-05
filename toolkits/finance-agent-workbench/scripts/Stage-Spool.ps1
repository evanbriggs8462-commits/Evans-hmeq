#requires -Version 5.1

<#
.SYNOPSIS
Stages one large SAP spool XML file from an approved UNC root to local,
content-addressed storage.

.DESCRIPTION
The source allowlist is read from the process environment variable
SPOOL_ALLOWED_UNC_ROOTS. Separate roots with semicolons. The variable is a
policy input, not a credential; set it in a trusted launcher or machine policy,
not in an agent-generated command.

The script never writes to, renames, moves, or deletes the source. It copies to
a deterministic directory ending in .part, verifies that the source metadata
did not change, hashes the local copy, and atomically promotes the file within
the destination volume. Successful artifacts and receipts are marked read-only.

.EXAMPLE
$env:SPOOL_ALLOWED_UNC_ROOTS = '\\server\approved-share\sap-spool'
.\Stage-Spool.ps1 -SourcePath '\\server\approved-share\sap-spool\2026\ledger.xml' `
    -DestinationRoot 'C:\SpoolStage'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $SourcePath,

    [Parameter(Mandatory = $true, Position = 1)]
    [string] $DestinationRoot,

    [Parameter()]
    [int] $StabilityProbeCount = 3,

    [Parameter()]
    [int] $StabilityProbeSeconds = 5,

    [Parameter()]
    [long] $ReserveBytes = 1073741824,

    [Parameter()]
    [int] $RobocopyRetryCount = 2,

    [Parameter()]
    [int] $RobocopyWaitSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:IsStageSpoolDotSourced = ($MyInvocation.InvocationName -eq '.')

$script:SpoolStageExitCode = @{
    Unexpected         = 1
    Validation         = 2
    SourceUnavailable  = 3
    SourceUnstable     = 4
    InsufficientSpace  = 5
    CopyFailed         = 6
    SourceChanged      = 7
    IntegrityFailed    = 8
    PromotionFailed    = 9
    ReceiptFailed      = 10
    ConcurrentRun      = 11
}

function New-SpoolStageErrorRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $FailureClass,

        [Parameter(Mandatory = $true)]
        [int] $ExitCode,

        [Parameter(Mandatory = $true)]
        [string] $Message,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorCategory] $Category,

        [Parameter()]
        [AllowNull()]
        [object] $TargetObject,

        [Parameter()]
        [AllowNull()]
        [System.Exception] $InnerException
    )

    if ($null -ne $InnerException) {
        $exception = New-Object -TypeName System.InvalidOperationException -ArgumentList @($Message, $InnerException)
    }
    else {
        $exception = New-Object -TypeName System.InvalidOperationException -ArgumentList $Message
    }

    $exception.Data['FailureClass'] = $FailureClass
    $exception.Data['ExitCode'] = $ExitCode

    return (New-Object -TypeName System.Management.Automation.ErrorRecord -ArgumentList @(
        $exception,
        $FailureClass,
        $Category,
        $TargetObject
    ))
}

function Throw-SpoolStageFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $FailureClass,

        [Parameter(Mandatory = $true)]
        [int] $ExitCode,

        [Parameter(Mandatory = $true)]
        [string] $Message,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorCategory] $Category,

        [Parameter()]
        [AllowNull()]
        [object] $TargetObject,

        [Parameter()]
        [AllowNull()]
        [System.Exception] $InnerException
    )

    $record = New-SpoolStageErrorRecord -FailureClass $FailureClass -ExitCode $ExitCode `
        -Message $Message -Category $Category -TargetObject $TargetObject `
        -InnerException $InnerException
    throw $record
}

function Assert-PlainPathText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $Label
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Throw-SpoolStageFailure -FailureClass 'Validation.EmptyPath' `
            -ExitCode $script:SpoolStageExitCode.Validation `
            -Message "$Label cannot be empty." `
            -Category InvalidArgument -TargetObject $Path
    }

    if ($Path -ne $Path.Trim()) {
        Throw-SpoolStageFailure -FailureClass 'Validation.PathWhitespace' `
            -ExitCode $script:SpoolStageExitCode.Validation `
            -Message "$Label must not contain leading or trailing whitespace." `
            -Category InvalidArgument -TargetObject $Path
    }

    if ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($Path)) {
        Throw-SpoolStageFailure -FailureClass 'Validation.WildcardPath' `
            -ExitCode $script:SpoolStageExitCode.Validation `
            -Message "$Label must be a literal path; wildcard characters are not allowed." `
            -Category InvalidArgument -TargetObject $Path
    }

    if ($Path.IndexOf([char]0) -ge 0) {
        Throw-SpoolStageFailure -FailureClass 'Validation.NullCharacter' `
            -ExitCode $script:SpoolStageExitCode.Validation `
            -Message "$Label contains a null character." `
            -Category InvalidArgument -TargetObject $Path
    }
}

function ConvertTo-NormalizedUncPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter()]
        [switch] $IsAllowlistRoot
    )

    Assert-PlainPathText -Path $Path -Label 'UNC path'

    if ($Path.StartsWith('\\?\', [System.StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith('\\.\', [System.StringComparison]::OrdinalIgnoreCase)) {
        Throw-SpoolStageFailure -FailureClass 'Validation.DevicePath' `
            -ExitCode $script:SpoolStageExitCode.Validation `
            -Message 'Device and extended-length path prefixes are not accepted.' `
            -Category InvalidArgument -TargetObject $Path
    }

    if ($Path.IndexOf('/') -ge 0 -or $Path.IndexOf(':') -ge 0) {
        Throw-SpoolStageFailure -FailureClass 'Validation.AmbiguousUncPath' `
            -ExitCode $script:SpoolStageExitCode.Validation `
            -Message 'UNC paths must use backslashes and must not contain alternate data-stream syntax.' `
            -Category InvalidArgument -TargetObject $Path
    }

    if ($Path -notmatch '^\\\\[^\\]+\\[^\\]+') {
        Throw-SpoolStageFailure -FailureClass 'Validation.NotUncPath' `
            -ExitCode $script:SpoolStageExitCode.Validation `
            -Message 'Source paths and allowlist roots must use the form \\server\share\path.' `
            -Category InvalidArgument -TargetObject $Path
    }

    $segments = @($Path.Substring(2) -split '\\')
    if ($segments.Count -lt 2 -or $segments -contains '' -or
        $segments -contains '.' -or $segments -contains '..') {
        Throw-SpoolStageFailure -FailureClass 'Validation.UnsafeUncSegments' `
            -ExitCode $script:SpoolStageExitCode.Validation `
            -Message 'UNC paths must not contain empty, current-directory, or parent-directory segments.' `
            -Category InvalidArgument -TargetObject $Path
    }

    try {
        $normalized = [System.IO.Path]::GetFullPath($Path).TrimEnd([char]'\')
    }
    catch {
        Throw-SpoolStageFailure -FailureClass 'Validation.InvalidUncPath' `
            -ExitCode $script:SpoolStageExitCode.Validation `
            -Message 'The UNC path could not be normalized.' `
            -Category InvalidArgument -TargetObject $Path -InnerException $_.Exception
    }

    if (-not $IsAllowlistRoot -and
        -not [string]::Equals([System.IO.Path]::GetExtension($normalized), '.xml',
            [System.StringComparison]::OrdinalIgnoreCase)) {
        Throw-SpoolStageFailure -FailureClass 'Validation.NotXmlFile' `
            -ExitCode $script:SpoolStageExitCode.Validation `
            -Message 'SourcePath must identify one .xml file.' `
            -Category InvalidArgument -TargetObject $Path
    }

    return $normalized
}

function Get-ConfiguredAllowedSourceRoots {
    [CmdletBinding()]
    param()

    $rawRoots = [System.Environment]::GetEnvironmentVariable(
        'SPOOL_ALLOWED_UNC_ROOTS',
        [System.EnvironmentVariableTarget]::Process
    )

    if ([string]::IsNullOrWhiteSpace($rawRoots)) {
        Throw-SpoolStageFailure -FailureClass 'Policy.AllowlistMissing' `
            -ExitCode $script:SpoolStageExitCode.Validation `
            -Message 'SPOOL_ALLOWED_UNC_ROOTS is not configured in the process environment.' `
            -Category SecurityError -TargetObject 'SPOOL_ALLOWED_UNC_ROOTS'
    }

    $normalizedRoots = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @($rawRoots -split ';')) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        $normalized = ConvertTo-NormalizedUncPath -Path $candidate.Trim() -IsAllowlistRoot
        if (-not $normalizedRoots.Contains($normalized)) {
            [void] $normalizedRoots.Add($normalized)
        }
    }

    if ($normalizedRoots.Count -eq 0) {
        Throw-SpoolStageFailure -FailureClass 'Policy.AllowlistEmpty' `
            -ExitCode $script:SpoolStageExitCode.Validation `
            -Message 'SPOOL_ALLOWED_UNC_ROOTS does not contain a usable UNC root.' `
            -Category SecurityError -TargetObject 'SPOOL_ALLOWED_UNC_ROOTS'
    }

    return @($normalizedRoots.ToArray())
}

function Resolve-ApprovedSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $normalizedSource = ConvertTo-NormalizedUncPath -Path $Path
    $allowedRoots = @(Get-ConfiguredAllowedSourceRoots)
    $matchedRoot = $null

    foreach ($root in $allowedRoots) {
        $prefix = $root + '\'
        if ($normalizedSource.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            if ($null -eq $matchedRoot -or $root.Length -gt $matchedRoot.Length) {
                $matchedRoot = $root
            }
        }
    }

    if ($null -eq $matchedRoot) {
        Throw-SpoolStageFailure -FailureClass 'Policy.SourceOutsideAllowlist' `
            -ExitCode $script:SpoolStageExitCode.Validation `
            -Message 'SourcePath is outside every configured UNC allowlist root.' `
            -Category SecurityError -TargetObject $normalizedSource
    }

    return [pscustomobject]@{
        Path        = $normalizedSource
        AllowedRoot = $matchedRoot
    }
}

function Get-DestinationDriveInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $DriveRoot
    )

    try {
        return (New-Object -TypeName System.IO.DriveInfo -ArgumentList $DriveRoot)
    }
    catch {
        Throw-SpoolStageFailure -FailureClass 'Destination.VolumeInspectionFailed' `
            -ExitCode $script:SpoolStageExitCode.Validation `
            -Message 'The destination volume could not be inspected.' `
            -Category ResourceUnavailable -TargetObject $DriveRoot -InnerException $_.Exception
    }
}

function Assert-DestinationDriveIsReadyAndFixed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $DriveInfo
    )

    try {
        $isReady = [bool] $DriveInfo.IsReady
        $driveType = [System.IO.DriveType] $DriveInfo.DriveType
    }
    catch {
        Throw-SpoolStageFailure -FailureClass 'Destination.VolumeInspectionFailed' `
            -ExitCode $script:SpoolStageExitCode.Validation `
            -Message 'The destination volume readiness and type could not be inspected.' `
            -Category ResourceUnavailable -TargetObject 'destination-volume' `
            -InnerException $_.Exception
    }

    if (-not $isReady) {
        Throw-SpoolStageFailure -FailureClass 'Destination.VolumeNotReady' `
            -ExitCode $script:SpoolStageExitCode.Validation `
            -Message 'The destination volume is not ready.' `
            -Category ResourceUnavailable -TargetObject 'destination-volume'
    }

    if ($driveType -ne [System.IO.DriveType]::Fixed) {
        Throw-SpoolStageFailure -FailureClass 'Destination.NotFixedDrive' `
            -ExitCode $script:SpoolStageExitCode.Validation `
            -Message 'DestinationRoot must resolve to a fixed local volume.' `
            -Category InvalidArgument -TargetObject 'destination-volume'
    }
}

function Assert-DestinationPathHasNoReparseAncestors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $NormalizedPath,

        [Parameter(Mandatory = $true)]
        [string] $DriveRoot
    )

    $candidates = New-Object System.Collections.Generic.List[string]
    [void] $candidates.Add($DriveRoot)
    $relativePath = $NormalizedPath.Substring($DriveRoot.Length).TrimStart([char]'\')
    $currentPath = $DriveRoot
    foreach ($segment in @($relativePath -split '\\')) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            continue
        }
        $currentPath = Join-Path -Path $currentPath -ChildPath $segment
        [void] $candidates.Add($currentPath)
    }

    foreach ($candidate in $candidates) {
        try {
            $exists = Test-Path -LiteralPath $candidate -ErrorAction Stop
        }
        catch {
            Throw-SpoolStageFailure -FailureClass 'Destination.AncestorInspectionFailed' `
                -ExitCode $script:SpoolStageExitCode.Validation `
                -Message 'An existing destination ancestor could not be inspected.' `
                -Category ResourceUnavailable -TargetObject 'destination-ancestor' `
                -InnerException $_.Exception
        }

        if (-not $exists) {
            # A deeper descendant cannot exist when this literal ancestor does not.
            break
        }

        try {
            $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
        }
        catch {
            Throw-SpoolStageFailure -FailureClass 'Destination.AncestorInspectionFailed' `
                -ExitCode $script:SpoolStageExitCode.Validation `
                -Message 'An existing destination ancestor could not be inspected.' `
                -Category ResourceUnavailable -TargetObject 'destination-ancestor' `
                -InnerException $_.Exception
        }

        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Throw-SpoolStageFailure -FailureClass 'Destination.ReparseAncestorNotAllowed' `
                -ExitCode $script:SpoolStageExitCode.Validation `
                -Message 'DestinationRoot must not traverse a junction, symbolic link, mount point, or other reparse point.' `
                -Category SecurityError -TargetObject 'destination-ancestor'
        }

        if (-not $item.PSIsContainer) {
            Throw-SpoolStageFailure -FailureClass 'Destination.AncestorNotDirectory' `
                -ExitCode $script:SpoolStageExitCode.Validation `
                -Message 'An existing destination path component is not a directory.' `
                -Category InvalidType -TargetObject 'destination-ancestor'
        }
    }
}

function Resolve-LocalDestinationRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    Assert-PlainPathText -Path $Path -Label 'DestinationRoot'

    $destinationTail = $Path.Substring([Math]::Min(2, $Path.Length))
    if ($Path.StartsWith('\\') -or $Path.StartsWith('\\?\') -or
        $Path.StartsWith('\\.\') -or $Path.IndexOf('/') -ge 0 -or
        $destinationTail.IndexOf(':') -ge 0 -or
        $Path -notmatch '^[A-Za-z]:\\') {
        Throw-SpoolStageFailure -FailureClass 'Destination.NotLocalDrivePath' `
            -ExitCode $script:SpoolStageExitCode.Validation `
            -Message 'DestinationRoot must be a normal, local drive path such as C:\SpoolStage.' `
            -Category InvalidArgument -TargetObject $Path
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $driveRoot = [System.IO.Path]::GetPathRoot($fullPath)
    }
    catch {
        Throw-SpoolStageFailure -FailureClass 'Destination.InvalidPath' `
            -ExitCode $script:SpoolStageExitCode.Validation `
            -Message 'DestinationRoot could not be normalized.' `
            -Category InvalidArgument -TargetObject $Path -InnerException $_.Exception
    }

    if ([string]::Equals($fullPath.TrimEnd([char]'\'), $driveRoot.TrimEnd([char]'\'),
        [System.StringComparison]::OrdinalIgnoreCase)) {
        Throw-SpoolStageFailure -FailureClass 'Destination.DriveRootNotAllowed' `
            -ExitCode $script:SpoolStageExitCode.Validation `
            -Message 'A drive root is too broad for DestinationRoot; use a dedicated staging directory.' `
            -Category InvalidArgument -TargetObject $Path
    }

    $normalized = $fullPath.TrimEnd([char]'\')
    foreach ($environmentName in @('OneDrive', 'OneDriveCommercial', 'OneDriveConsumer')) {
        $syncRoot = [System.Environment]::GetEnvironmentVariable($environmentName)
        if ([string]::IsNullOrWhiteSpace($syncRoot)) {
            continue
        }

        try {
            $normalizedSyncRoot = [System.IO.Path]::GetFullPath($syncRoot).TrimEnd([char]'\')
        }
        catch {
            continue
        }

        if ([string]::Equals($normalized, $normalizedSyncRoot,
                [System.StringComparison]::OrdinalIgnoreCase) -or
            $normalized.StartsWith($normalizedSyncRoot + '\',
                [System.StringComparison]::OrdinalIgnoreCase)) {
            Throw-SpoolStageFailure -FailureClass 'Destination.SyncRootNotAllowed' `
                -ExitCode $script:SpoolStageExitCode.Validation `
                -Message 'DestinationRoot must not be inside OneDrive or another configured OneDrive sync root.' `
                -Category InvalidArgument -TargetObject $normalized
        }
    }

    try {
        # Validate the volume and every existing path component before creating
        # anything. A path that merely starts with "C:\" is not necessarily
        # local: a mapped volume or ancestor junction can redirect elsewhere.
        $driveInfo = Get-DestinationDriveInfo -DriveRoot $driveRoot
        Assert-DestinationDriveIsReadyAndFixed -DriveInfo $driveInfo
        Assert-DestinationPathHasNoReparseAncestors `
            -NormalizedPath $normalized -DriveRoot $driveRoot

        if (-not (Test-Path -LiteralPath $normalized -PathType Container)) {
            [void] (New-Item -ItemType Directory -Path $normalized -ErrorAction Stop)
        }

        # Recheck after creation to detect a concurrently introduced reparse
        # point before any staging file is opened below the destination.
        Assert-DestinationPathHasNoReparseAncestors `
            -NormalizedPath $normalized -DriveRoot $driveRoot
    }
    catch {
        if ($_.Exception.Data.Contains('FailureClass')) {
            throw
        }

        Throw-SpoolStageFailure -FailureClass 'Destination.Unavailable' `
            -ExitCode $script:SpoolStageExitCode.Validation `
            -Message 'DestinationRoot could not be created or inspected.' `
            -Category ResourceUnavailable -TargetObject $normalized -InnerException $_.Exception
    }

    return [pscustomobject]@{
        Path      = $normalized
        DriveInfo = $driveInfo
    }
}

function Get-SpoolFileSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $LiteralPath
    )

    try {
        $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
    }
    catch {
        Throw-SpoolStageFailure -FailureClass 'Source.Unavailable' `
            -ExitCode $script:SpoolStageExitCode.SourceUnavailable `
            -Message 'The source XML could not be inspected. Verify VPN, DNS, SMB, and Windows-integrated access.' `
            -Category ResourceUnavailable -TargetObject $LiteralPath -InnerException $_.Exception
    }

    if ($item.PSIsContainer) {
        Throw-SpoolStageFailure -FailureClass 'Source.NotAFile' `
            -ExitCode $script:SpoolStageExitCode.SourceUnavailable `
            -Message 'SourcePath identifies a directory, not one XML file.' `
            -Category InvalidType -TargetObject $LiteralPath
    }

    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Throw-SpoolStageFailure -FailureClass 'Source.ReparsePointNotAllowed' `
            -ExitCode $script:SpoolStageExitCode.Validation `
            -Message 'The source file must not be a symbolic link or reparse point.' `
            -Category SecurityError -TargetObject $LiteralPath
    }

    if ([int64] $item.Length -le 0) {
        Throw-SpoolStageFailure -FailureClass 'Source.EmptyFile' `
            -ExitCode $script:SpoolStageExitCode.SourceUnavailable `
            -Message 'The source XML is empty.' `
            -Category InvalidData -TargetObject $LiteralPath
    }

    return [pscustomobject]@{
        Path                  = [string] $item.FullName
        LengthBytes           = [int64] $item.Length
        LastWriteTimeUtc      = $item.LastWriteTimeUtc.ToString('o')
        LastWriteTimeUtcTicks = [int64] $item.LastWriteTimeUtc.Ticks
    }
}

function Test-SpoolSnapshotEqual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Left,

        [Parameter(Mandatory = $true)]
        [object] $Right
    )

    return (([int64] $Left.LengthBytes -eq [int64] $Right.LengthBytes) -and
        ([int64] $Left.LastWriteTimeUtcTicks -eq [int64] $Right.LastWriteTimeUtcTicks))
}

function Assert-SourceStable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $LiteralPath,

        [Parameter(Mandatory = $true)]
        [int] $ProbeCount,

        [Parameter(Mandatory = $true)]
        [int] $ProbeSeconds
    )

    if ($ProbeCount -lt 2 -or $ProbeCount -gt 10 -or
        $ProbeSeconds -lt 1 -or $ProbeSeconds -gt 300) {
        Throw-SpoolStageFailure -FailureClass 'Validation.InvalidStabilityProbe' `
            -ExitCode $script:SpoolStageExitCode.Validation `
            -Message 'StabilityProbeCount must be 2-10 and StabilityProbeSeconds must be 1-300.' `
            -Category InvalidArgument -TargetObject "$ProbeCount/$ProbeSeconds"
    }

    $previous = $null
    for ($probeIndex = 0; $probeIndex -lt $ProbeCount; $probeIndex++) {
        $current = Get-SpoolFileSnapshot -LiteralPath $LiteralPath
        if ($null -ne $previous -and -not (Test-SpoolSnapshotEqual -Left $previous -Right $current)) {
            Throw-SpoolStageFailure -FailureClass 'Source.UnstableDuringProbe' `
                -ExitCode $script:SpoolStageExitCode.SourceUnstable `
                -Message 'Source length or last-write time changed during the stability probes.' `
                -Category InvalidData -TargetObject $LiteralPath
        }

        $previous = $current
        if ($probeIndex -lt ($ProbeCount - 1)) {
            Start-Sleep -Seconds $ProbeSeconds
        }
    }

    return $previous
}

function Get-StringSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        $digest = $algorithm.ComputeHash($bytes)
        return (($digest | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $algorithm.Dispose()
    }
}

function Assert-DestinationCapacity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $DriveInfo,

        [Parameter(Mandatory = $true)]
        [long] $SourceLengthBytes,

        [Parameter(Mandatory = $true)]
        [long] $SafetyReserveBytes,

        [Parameter(Mandatory = $true)]
        [string] $StageFilePath
    )

    if ($SafetyReserveBytes -lt 0 -or $SafetyReserveBytes -gt 1099511627776) {
        Throw-SpoolStageFailure -FailureClass 'Validation.InvalidReserveBytes' `
            -ExitCode $script:SpoolStageExitCode.Validation `
            -Message 'ReserveBytes must be between 0 and 1 TiB.' `
            -Category InvalidArgument -TargetObject $SafetyReserveBytes
    }

    $existingBytes = [int64] 0
    if (Test-Path -LiteralPath $StageFilePath) {
        $existingItem = Get-Item -LiteralPath $StageFilePath -Force -ErrorAction Stop
        if ($existingItem.PSIsContainer) {
            Throw-SpoolStageFailure -FailureClass 'Destination.StagePathIsDirectory' `
                -ExitCode $script:SpoolStageExitCode.Validation `
                -Message 'The expected staging file path is occupied by a directory.' `
                -Category InvalidType -TargetObject $StageFilePath
        }
        $existingBytes = [Math]::Min([int64] $existingItem.Length, $SourceLengthBytes)
    }

    $remainingCopyBytes = [Math]::Max([int64] 0, ($SourceLengthBytes - $existingBytes))
    if ($remainingCopyBytes -gt ([int64]::MaxValue - $SafetyReserveBytes)) {
        Throw-SpoolStageFailure -FailureClass 'Destination.RequiredSpaceOverflow' `
            -ExitCode $script:SpoolStageExitCode.InsufficientSpace `
            -Message 'Required destination capacity exceeds the supported integer range.' `
            -Category LimitsExceeded -TargetObject $StageFilePath
    }

    $requiredFreeBytes = $remainingCopyBytes + $SafetyReserveBytes
    $availableFreeBytes = [int64] $DriveInfo.AvailableFreeSpace
    if ($availableFreeBytes -lt $requiredFreeBytes) {
        Throw-SpoolStageFailure -FailureClass 'Destination.InsufficientSpace' `
            -ExitCode $script:SpoolStageExitCode.InsufficientSpace `
            -Message ("Destination needs at least {0} free bytes but has {1}." -f
                $requiredFreeBytes, $availableFreeBytes) `
            -Category ResourceUnavailable -TargetObject $StageFilePath
    }

    return [pscustomobject]@{
        AvailableFreeBytes = $availableFreeBytes
        RequiredFreeBytes  = $requiredFreeBytes
        ExistingStageBytes = $existingBytes
    }
}

function Get-RobocopyFlags {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int] $ExitCode
    )

    return [pscustomobject]@{
        FilesCopied  = (($ExitCode -band 1) -ne 0)
        ExtraFiles   = (($ExitCode -band 2) -ne 0)
        Mismatches   = (($ExitCode -band 4) -ne 0)
        CopyFailures = (($ExitCode -band 8) -ne 0)
        FatalError   = (($ExitCode -band 16) -ne 0)
    }
}

function Invoke-NativeRobocopy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    $command = Get-Command -Name 'robocopy.exe' -CommandType Application -ErrorAction Stop
    $outputLines = @(& $command.Path @Arguments 2>&1)
    $nativeExitCode = $LASTEXITCODE

    return [pscustomobject]@{
        ExitCode = [int] $nativeExitCode
        Output   = @($outputLines | ForEach-Object { [string] $_ })
    }
}

function Invoke-RobocopyCopy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $SourceDirectory,

        [Parameter(Mandatory = $true)]
        [string] $StageDirectory,

        [Parameter(Mandatory = $true)]
        [string] $LeafName,

        [Parameter(Mandatory = $true)]
        [int] $RetryCount,

        [Parameter(Mandatory = $true)]
        [int] $WaitSeconds
    )

    if ($RetryCount -lt 0 -or $RetryCount -gt 10 -or
        $WaitSeconds -lt 1 -or $WaitSeconds -gt 60) {
        Throw-SpoolStageFailure -FailureClass 'Validation.InvalidRobocopyRetry' `
            -ExitCode $script:SpoolStageExitCode.Validation `
            -Message 'RobocopyRetryCount must be 0-10 and RobocopyWaitSeconds must be 1-60.' `
            -Category InvalidArgument -TargetObject "$RetryCount/$WaitSeconds"
    }

    $robocopyArguments = @(
        $SourceDirectory,
        $StageDirectory,
        $LeafName,
        '/Z',
        '/J',
        "/R:$RetryCount",
        "/W:$WaitSeconds",
        '/COPY:DT',
        '/DCOPY:T',
        '/IS',
        '/XJ',
        '/BYTES',
        '/NP',
        '/NFL',
        '/NDL',
        '/NJH',
        '/NJS'
    )

    try {
        $nativeResult = Invoke-NativeRobocopy -Arguments $robocopyArguments
    }
    catch {
        Throw-SpoolStageFailure -FailureClass 'Copy.RobocopyUnavailable' `
            -ExitCode $script:SpoolStageExitCode.CopyFailed `
            -Message 'robocopy.exe could not be started.' `
            -Category NotInstalled -TargetObject 'robocopy.exe' -InnerException $_.Exception
    }

    $exitCode = [int] $nativeResult.ExitCode
    $flags = Get-RobocopyFlags -ExitCode $exitCode
    if ($exitCode -lt 0 -or $exitCode -ge 8) {
        $tail = (@($nativeResult.Output) | Select-Object -Last 8) -join ' | '
        foreach ($redaction in @(
                [pscustomobject]@{ Value = $SourceDirectory; Replacement = '<source-directory>' },
                [pscustomobject]@{ Value = $StageDirectory; Replacement = '<stage-directory>' },
                [pscustomobject]@{ Value = $LeafName; Replacement = '<source-file>' }
            )) {
            if (-not [string]::IsNullOrEmpty($redaction.Value)) {
                $tail = [System.Text.RegularExpressions.Regex]::Replace(
                    $tail,
                    [System.Text.RegularExpressions.Regex]::Escape($redaction.Value),
                    $redaction.Replacement,
                    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
                )
            }
        }
        if ($tail.Length -gt 2000) {
            $tail = $tail.Substring(0, 2000)
        }

        $message = "Robocopy failed with exit code $exitCode."
        if (-not [string]::IsNullOrWhiteSpace($tail)) {
            $message = $message + ' Output tail: ' + $tail
        }

        Throw-SpoolStageFailure -FailureClass 'Copy.RobocopyFailed' `
            -ExitCode $script:SpoolStageExitCode.CopyFailed `
            -Message $message -Category WriteError -TargetObject $StageDirectory
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Flags    = $flags
    }
}

function Get-LocalSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $LiteralPath
    )

    $hash = Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256 -ErrorAction Stop
    return $hash.Hash.ToLowerInvariant()
}

function Set-ArtifactReadOnly {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $LiteralPath
    )

    $attributes = [System.IO.File]::GetAttributes($LiteralPath)
    [System.IO.File]::SetAttributes(
        $LiteralPath,
        ($attributes -bor [System.IO.FileAttributes]::ReadOnly)
    )
}

function Assert-ContentAddressedArtifactMatches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ArtifactPath,

        [Parameter(Mandatory = $true)]
        [string] $ExpectedSha256,

        [Parameter(Mandatory = $true)]
        [long] $ExpectedLengthBytes
    )

    try {
        $existingItem = Get-Item -LiteralPath $ArtifactPath -Force -ErrorAction Stop
        if ($existingItem.PSIsContainer) {
            Throw-SpoolStageFailure -FailureClass 'Promotion.ContentAddressCollision' `
                -ExitCode $script:SpoolStageExitCode.PromotionFailed `
                -Message 'The content-addressed artifact path is occupied by a directory.' `
                -Category InvalidData -TargetObject $ArtifactPath
        }
        if (($existingItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Throw-SpoolStageFailure -FailureClass 'Promotion.ReparseArtifactNotAllowed' `
                -ExitCode $script:SpoolStageExitCode.PromotionFailed `
                -Message 'An existing content-addressed artifact must not be a reparse point.' `
                -Category SecurityError -TargetObject $ArtifactPath
        }
        $existingHash = Get-LocalSha256 -LiteralPath $ArtifactPath
    }
    catch {
        if ($_.Exception.Data.Contains('FailureClass')) {
            throw
        }
        Throw-SpoolStageFailure -FailureClass 'Promotion.ExistingArtifactInspectionFailed' `
            -ExitCode $script:SpoolStageExitCode.PromotionFailed `
            -Message 'An existing content-addressed artifact could not be verified.' `
            -Category ReadError -TargetObject $ArtifactPath -InnerException $_.Exception
    }

    if ([int64] $existingItem.Length -ne $ExpectedLengthBytes -or
        -not [string]::Equals($existingHash, $ExpectedSha256,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        Throw-SpoolStageFailure -FailureClass 'Promotion.ContentAddressCollision' `
            -ExitCode $script:SpoolStageExitCode.PromotionFailed `
            -Message 'An existing content-addressed artifact does not match its path.' `
            -Category InvalidData -TargetObject $ArtifactPath
    }
}

function Publish-StagedArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StageFilePath,

        [Parameter(Mandatory = $true)]
        [string] $DestinationRootPath,

        [Parameter(Mandatory = $true)]
        [string] $Sha256,

        [Parameter(Mandatory = $true)]
        [long] $LengthBytes
    )

    $objectDirectory = Join-Path -Path $DestinationRootPath -ChildPath (
        'objects\' + $Sha256.Substring(0, 2)
    )
    $objectDriveRoot = [System.IO.Path]::GetPathRoot($objectDirectory)
    Assert-DestinationPathHasNoReparseAncestors `
        -NormalizedPath $objectDirectory -DriveRoot $objectDriveRoot
    [void] (New-Item -ItemType Directory -Path $objectDirectory -Force -ErrorAction Stop)
    Assert-DestinationPathHasNoReparseAncestors `
        -NormalizedPath $objectDirectory -DriveRoot $objectDriveRoot
    $artifactPath = Join-Path -Path $objectDirectory -ChildPath ($Sha256 + '.xml')
    $reused = $false

    try {
        if (Test-Path -LiteralPath $artifactPath -PathType Leaf) {
            Assert-ContentAddressedArtifactMatches -ArtifactPath $artifactPath `
                -ExpectedSha256 $Sha256 -ExpectedLengthBytes $LengthBytes
            Remove-Item -LiteralPath $StageFilePath -Force -ErrorAction Stop
            $reused = $true
        }
        else {
            # Stage and artifact are under the same fixed-volume root; Move-Item is
            # therefore a same-volume rename and does not expose a partial final file.
            try {
                Move-Item -LiteralPath $StageFilePath -Destination $artifactPath -ErrorAction Stop
            }
            catch {
                $renameException = $_.Exception
                if (Test-Path -LiteralPath $artifactPath -PathType Leaf) {
                    # Another process may have won the harmless content-addressed
                    # rename race. Accept only the exact expected bytes; never force
                    # an overwrite merely because the destination appeared.
                    Assert-ContentAddressedArtifactMatches -ArtifactPath $artifactPath `
                        -ExpectedSha256 $Sha256 -ExpectedLengthBytes $LengthBytes
                    if (Test-Path -LiteralPath $StageFilePath -PathType Leaf) {
                        Remove-Item -LiteralPath $StageFilePath -Force -ErrorAction Stop
                    }
                    $reused = $true
                }
                else {
                    throw $renameException
                }
            }
        }

        Set-ArtifactReadOnly -LiteralPath $artifactPath
    }
    catch {
        if ($_.Exception.Data.Contains('FailureClass')) {
            throw
        }

        Throw-SpoolStageFailure -FailureClass 'Promotion.AtomicRenameFailed' `
            -ExitCode $script:SpoolStageExitCode.PromotionFailed `
            -Message 'The verified staging file could not be atomically promoted.' `
            -Category WriteError -TargetObject $artifactPath -InnerException $_.Exception
    }

    return [pscustomobject]@{
        ArtifactPath = $artifactPath
        Reused       = $reused
        ReadOnly     = $true
    }
}

function Write-JsonReceiptAtomically {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Receipt,

        [Parameter(Mandatory = $true)]
        [string] $ReceiptPath
    )

    $receiptDirectory = Split-Path -Path $ReceiptPath -Parent
    $receiptDriveRoot = [System.IO.Path]::GetPathRoot($receiptDirectory)
    Assert-DestinationPathHasNoReparseAncestors `
        -NormalizedPath $receiptDirectory -DriveRoot $receiptDriveRoot
    [void] (New-Item -ItemType Directory -Path $receiptDirectory -Force -ErrorAction Stop)
    Assert-DestinationPathHasNoReparseAncestors `
        -NormalizedPath $receiptDirectory -DriveRoot $receiptDriveRoot
    $temporaryPath = $ReceiptPath + '.tmp-' + [System.Guid]::NewGuid().ToString('N')
    $utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false

    try {
        $json = $Receipt | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($temporaryPath, $json, $utf8NoBom)
        Move-Item -LiteralPath $temporaryPath -Destination $ReceiptPath -ErrorAction Stop
        Set-ArtifactReadOnly -LiteralPath $ReceiptPath
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-SpoolStaging {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $SourcePath,

        [Parameter(Mandatory = $true)]
        [string] $DestinationRoot,

        [Parameter()]
        [int] $StabilityProbeCount = 3,

        [Parameter()]
        [int] $StabilityProbeSeconds = 5,

        [Parameter()]
        [long] $ReserveBytes = 1073741824,

        [Parameter()]
        [int] $RobocopyRetryCount = 2,

        [Parameter()]
        [int] $RobocopyWaitSeconds = 5
    )

    $startedUtc = [System.DateTime]::UtcNow
    $runId = [System.Guid]::NewGuid().ToString('N')
    $lockStream = $null
    $lockPath = $null

    $approvedSource = Resolve-ApprovedSource -Path $SourcePath
    $stableSnapshot = Assert-SourceStable -LiteralPath $approvedSource.Path `
        -ProbeCount $StabilityProbeCount -ProbeSeconds $StabilityProbeSeconds

    $destination = Resolve-LocalDestinationRoot -Path $DestinationRoot
    $sourceIdentity = ('{0}|{1}|{2}' -f
        $approvedSource.Path.ToLowerInvariant(),
        $stableSnapshot.LengthBytes,
        $stableSnapshot.LastWriteTimeUtcTicks)
    $stageKey = Get-StringSha256 -Value $sourceIdentity
    $stageDirectory = Join-Path -Path $destination.Path -ChildPath (
        '.staging\' + $stageKey + '.part'
    )
    $stageDriveRoot = [System.IO.Path]::GetPathRoot($stageDirectory)
    Assert-DestinationPathHasNoReparseAncestors `
        -NormalizedPath $stageDirectory -DriveRoot $stageDriveRoot
    [void] (New-Item -ItemType Directory -Path $stageDirectory -Force -ErrorAction Stop)
    Assert-DestinationPathHasNoReparseAncestors `
        -NormalizedPath $stageDirectory -DriveRoot $stageDriveRoot
    $leafName = [System.IO.Path]::GetFileName($approvedSource.Path)
    $stageFilePath = Join-Path -Path $stageDirectory -ChildPath $leafName
    $lockPath = Join-Path -Path $stageDirectory -ChildPath '.stage.lock'

    try {
        try {
            $lockStream = [System.IO.File]::Open(
                $lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        }
        catch {
            Throw-SpoolStageFailure -FailureClass 'Concurrency.StageLocked' `
                -ExitCode $script:SpoolStageExitCode.ConcurrentRun `
                -Message 'Another process is staging the same source snapshot.' `
                -Category ResourceBusy -TargetObject $stageDirectory -InnerException $_.Exception
        }

        $capacity = Assert-DestinationCapacity -DriveInfo $destination.DriveInfo `
            -SourceLengthBytes $stableSnapshot.LengthBytes `
            -SafetyReserveBytes $ReserveBytes -StageFilePath $stageFilePath

        $preCopySnapshot = Get-SpoolFileSnapshot -LiteralPath $approvedSource.Path
        if (-not (Test-SpoolSnapshotEqual -Left $stableSnapshot -Right $preCopySnapshot)) {
            Throw-SpoolStageFailure -FailureClass 'Source.ChangedBeforeCopy' `
                -ExitCode $script:SpoolStageExitCode.SourceUnstable `
                -Message 'Source metadata changed after stability probing and before copy.' `
                -Category InvalidData -TargetObject $approvedSource.Path
        }

        $sourceDirectory = [System.IO.Path]::GetDirectoryName($approvedSource.Path)
        $copyResult = Invoke-RobocopyCopy -SourceDirectory $sourceDirectory `
            -StageDirectory $stageDirectory -LeafName $leafName `
            -RetryCount $RobocopyRetryCount -WaitSeconds $RobocopyWaitSeconds

        try {
            $postCopySnapshot = Get-SpoolFileSnapshot -LiteralPath $approvedSource.Path
        }
        catch {
            Throw-SpoolStageFailure -FailureClass 'Source.PostCopyRestatFailed' `
                -ExitCode $script:SpoolStageExitCode.SourceChanged `
                -Message 'The source could not be restated immediately after copy.' `
                -Category ResourceUnavailable -TargetObject $approvedSource.Path `
                -InnerException $_.Exception
        }

        if (-not (Test-SpoolSnapshotEqual -Left $preCopySnapshot -Right $postCopySnapshot)) {
            Throw-SpoolStageFailure -FailureClass 'Source.ChangedDuringCopy' `
                -ExitCode $script:SpoolStageExitCode.SourceChanged `
                -Message 'Source length or last-write time changed while it was being copied.' `
                -Category InvalidData -TargetObject $approvedSource.Path
        }

        if (-not (Test-Path -LiteralPath $stageFilePath -PathType Leaf)) {
            Throw-SpoolStageFailure -FailureClass 'Copy.StageFileMissing' `
                -ExitCode $script:SpoolStageExitCode.CopyFailed `
                -Message 'Robocopy returned a success-class code but no staging file exists.' `
                -Category ObjectNotFound -TargetObject $stageFilePath
        }

        $stagedItem = Get-Item -LiteralPath $stageFilePath -Force -ErrorAction Stop
        if ([int64] $stagedItem.Length -ne [int64] $postCopySnapshot.LengthBytes) {
            Throw-SpoolStageFailure -FailureClass 'Integrity.LengthMismatch' `
                -ExitCode $script:SpoolStageExitCode.IntegrityFailed `
                -Message 'The local staging length does not match the post-copy source length.' `
                -Category InvalidData -TargetObject $stageFilePath
        }

        if ([int64] $stagedItem.LastWriteTimeUtc.Ticks -ne
            [int64] $postCopySnapshot.LastWriteTimeUtcTicks) {
            Throw-SpoolStageFailure -FailureClass 'Integrity.TimestampMismatch' `
                -ExitCode $script:SpoolStageExitCode.IntegrityFailed `
                -Message 'The local staging timestamp does not match the post-copy source timestamp.' `
                -Category InvalidData -TargetObject $stageFilePath
        }

        try {
            $sha256 = Get-LocalSha256 -LiteralPath $stageFilePath
        }
        catch {
            Throw-SpoolStageFailure -FailureClass 'Integrity.LocalHashFailed' `
                -ExitCode $script:SpoolStageExitCode.IntegrityFailed `
                -Message 'SHA-256 could not be calculated for the local staging file.' `
                -Category ReadError -TargetObject $stageFilePath -InnerException $_.Exception
        }

        if ($sha256 -notmatch '^[0-9a-f]{64}$') {
            Throw-SpoolStageFailure -FailureClass 'Integrity.InvalidHashResult' `
                -ExitCode $script:SpoolStageExitCode.IntegrityFailed `
                -Message 'The local SHA-256 result was not a 64-character hexadecimal digest.' `
                -Category InvalidData -TargetObject $stageFilePath
        }

        $published = Publish-StagedArtifact -StageFilePath $stageFilePath `
            -DestinationRootPath $destination.Path -Sha256 $sha256 `
            -LengthBytes $stagedItem.Length

        $completedUtc = [System.DateTime]::UtcNow
        $receiptDirectory = Join-Path -Path $destination.Path -ChildPath 'receipts\success'
        $receiptName = ('{0}-{1}.json' -f
            $completedUtc.ToString('yyyyMMddTHHmmssfffZ'), $runId)
        $receiptPath = Join-Path -Path $receiptDirectory -ChildPath $receiptName
        $artifactRelativePath = 'objects\' + $sha256.Substring(0, 2) + '\' + $sha256 + '.xml'
        $receiptRelativePath = 'receipts\success\' + $receiptName
        $sourcePathFingerprint = Get-StringSha256 -Value $approvedSource.Path.ToLowerInvariant()
        $allowedRootFingerprint = Get-StringSha256 -Value $approvedSource.AllowedRoot.ToLowerInvariant()
        $sourceLeafFingerprint = Get-StringSha256 -Value $leafName.ToLowerInvariant()

        $receipt = [ordered]@{
            schemaVersion = 1
            status        = 'succeeded'
            runId         = $runId
            startedUtc    = $startedUtc.ToString('o')
            completedUtc  = $completedUtc.ToString('o')
            source        = [ordered]@{
                leafNameFingerprint   = $sourceLeafFingerprint
                pathFingerprint       = $sourcePathFingerprint
                allowedRootFingerprint = $allowedRootFingerprint
                lengthBytes           = [int64] $postCopySnapshot.LengthBytes
                lastWriteTimeUtc      = $postCopySnapshot.LastWriteTimeUtc
                lastWriteTimeUtcTicks = [int64] $postCopySnapshot.LastWriteTimeUtcTicks
            }
            copy          = [ordered]@{
                engine            = 'robocopy.exe'
                exitCode          = [int] $copyResult.ExitCode
                flags             = $copyResult.Flags
                restartable       = $true
                unbuffered        = $true
                retryCount        = $RobocopyRetryCount
                retryWaitSeconds  = $RobocopyWaitSeconds
                stageKey          = $stageKey
            }
            capacity      = [ordered]@{
                availableFreeBytesAtCheck = [int64] $capacity.AvailableFreeBytes
                requiredFreeBytesAtCheck  = [int64] $capacity.RequiredFreeBytes
                existingStageBytes        = [int64] $capacity.ExistingStageBytes
            }
            artifact      = [ordered]@{
                relativePath = $artifactRelativePath
                sha256      = $sha256
                lengthBytes = [int64] $stagedItem.Length
                readOnly    = [bool] $published.ReadOnly
                reused      = [bool] $published.Reused
            }
            receiptRelativePath = $receiptRelativePath
        }

        try {
            Write-JsonReceiptAtomically -Receipt $receipt -ReceiptPath $receiptPath
        }
        catch {
            Throw-SpoolStageFailure -FailureClass 'Receipt.WriteFailed' `
                -ExitCode $script:SpoolStageExitCode.ReceiptFailed `
                -Message 'The artifact was promoted, but its JSON receipt could not be written.' `
                -Category WriteError -TargetObject $receiptPath -InnerException $_.Exception
        }

        return [pscustomobject] $receipt
    }
    finally {
        if ($null -ne $lockStream) {
            $lockStream.Dispose()
        }

        if ($null -ne $lockPath -and (Test-Path -LiteralPath $lockPath)) {
            Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
        }
    }
}

if (-not $script:IsStageSpoolDotSourced) {
    try {
        # Windows PowerShell 5.1 otherwise commonly emits redirected text using
        # legacy encodings. Keep the machine-readable stdout contract UTF-8.
        try {
            [Console]::OutputEncoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
        }
        catch {
            # Some embedded hosts do not expose a mutable console encoding. The
            # persisted receipt still uses explicit no-BOM UTF-8.
        }

        $result = Invoke-SpoolStaging -SourcePath $SourcePath `
            -DestinationRoot $DestinationRoot `
            -StabilityProbeCount $StabilityProbeCount `
            -StabilityProbeSeconds $StabilityProbeSeconds `
            -ReserveBytes $ReserveBytes `
            -RobocopyRetryCount $RobocopyRetryCount `
            -RobocopyWaitSeconds $RobocopyWaitSeconds
        [Console]::Out.WriteLine(($result | ConvertTo-Json -Depth 8 -Compress))
        exit 0
    }
    catch {
        $exitCode = $script:SpoolStageExitCode.Unexpected
        $failureClass = 'Unexpected.UnhandledError'
        if ($_.Exception.Data.Contains('ExitCode')) {
            $exitCode = [int] $_.Exception.Data['ExitCode']
        }
        if ($_.Exception.Data.Contains('FailureClass')) {
            $failureClass = [string] $_.Exception.Data['FailureClass']
        }

        $safeMessage = $_.Exception.Message
        if ($failureClass -eq 'Unexpected.UnhandledError') {
            $safeMessage = 'An unexpected internal error occurred; inspect approved local host logs.'
        }

        $failure = [ordered]@{
            schemaVersion   = 1
            status          = 'failed'
            completedUtc    = [System.DateTime]::UtcNow.ToString('o')
            failureClass    = $failureClass
            exitCode        = $exitCode
            message         = $safeMessage
        }
        [Console]::Out.WriteLine(($failure | ConvertTo-Json -Depth 8 -Compress))
        exit $exitCode
    }
}
