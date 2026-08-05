#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter()]
    [string] $LocalStagingRoot = $env:TEMP
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:IsEnvironmentProfileDotSourced = ($MyInvocation.InvocationName -eq '.')

function Throw-EnvironmentProfileFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $FailureClass,

        [Parameter(Mandatory = $true)]
        [string] $Message,

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
    $record = New-Object -TypeName System.Management.Automation.ErrorRecord -ArgumentList @(
        $exception,
        $FailureClass,
        [System.Management.Automation.ErrorCategory]::InvalidArgument,
        $null
    )
    throw $record
}

function Assert-ProfilePlainLocalPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -ne $Path.Trim()) {
        Throw-EnvironmentProfileFailure -FailureClass 'Destination.InvalidPath' `
            -Message 'The proposed staging destination is not a valid literal local path.'
    }
    if ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($Path)) {
        Throw-EnvironmentProfileFailure -FailureClass 'Destination.WildcardPath' `
            -Message 'The proposed staging destination must not contain wildcard characters.'
    }
    $destinationTail = $Path.Substring([Math]::Min(2, $Path.Length))
    if ($Path.StartsWith('\\') -or $Path.StartsWith('\\?\') -or
        $Path.StartsWith('\\.\') -or $Path.IndexOf('/') -ge 0 -or
        $destinationTail.IndexOf(':') -ge 0 -or
        $Path -notmatch '^[A-Za-z]:\\') {
        Throw-EnvironmentProfileFailure -FailureClass 'Destination.NotLocalDrivePath' `
            -Message 'The proposed staging destination is not a normal local drive path.'
    }
}

function Get-ProfileDestinationDriveInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $DriveRoot
    )

    try {
        return (New-Object -TypeName System.IO.DriveInfo -ArgumentList $DriveRoot)
    }
    catch {
        Throw-EnvironmentProfileFailure -FailureClass 'Destination.VolumeInspectionFailed' `
            -Message 'The proposed destination volume could not be inspected.' `
            -InnerException $_.Exception
    }
}

function Assert-ProfileDestinationDriveIsReadyAndFixed {
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
        Throw-EnvironmentProfileFailure -FailureClass 'Destination.VolumeInspectionFailed' `
            -Message 'The proposed destination volume readiness and type could not be inspected.' `
            -InnerException $_.Exception
    }

    if (-not $isReady) {
        Throw-EnvironmentProfileFailure -FailureClass 'Destination.VolumeNotReady' `
            -Message 'The proposed destination volume is not ready.'
    }
    if ($driveType -ne [System.IO.DriveType]::Fixed) {
        Throw-EnvironmentProfileFailure -FailureClass 'Destination.NotFixedDrive' `
            -Message 'The proposed staging destination is not on a fixed local volume.'
    }
}

function Assert-ProfileDestinationNotInSyncRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $NormalizedPath
    )

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

        if ([string]::Equals($NormalizedPath, $normalizedSyncRoot,
                [System.StringComparison]::OrdinalIgnoreCase) -or
            $NormalizedPath.StartsWith($normalizedSyncRoot + '\',
                [System.StringComparison]::OrdinalIgnoreCase)) {
            Throw-EnvironmentProfileFailure -FailureClass 'Destination.SyncRootNotAllowed' `
                -Message 'The proposed staging destination is within a configured sync root.'
        }
    }
}

function Assert-ProfileDestinationHasNoReparseAncestors {
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
            if (-not $exists) {
                break
            }
            $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
        }
        catch {
            Throw-EnvironmentProfileFailure -FailureClass 'Destination.AncestorInspectionFailed' `
                -Message 'An existing destination ancestor could not be inspected.' `
                -InnerException $_.Exception
        }

        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Throw-EnvironmentProfileFailure -FailureClass 'Destination.ReparseAncestorNotAllowed' `
                -Message 'The proposed staging destination traverses a reparse point.'
        }
        if (-not $item.PSIsContainer) {
            Throw-EnvironmentProfileFailure -FailureClass 'Destination.AncestorNotDirectory' `
                -Message 'An existing destination component is not a directory.'
        }
    }
}

function Test-LocalStagingDestination {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    Assert-ProfilePlainLocalPath -Path $Path
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $driveRoot = [System.IO.Path]::GetPathRoot($fullPath)
    }
    catch {
        Throw-EnvironmentProfileFailure -FailureClass 'Destination.InvalidPath' `
            -Message 'The proposed staging destination could not be normalized.' `
            -InnerException $_.Exception
    }

    if ([string]::Equals($fullPath.TrimEnd([char]'\'), $driveRoot.TrimEnd([char]'\'),
        [System.StringComparison]::OrdinalIgnoreCase)) {
        Throw-EnvironmentProfileFailure -FailureClass 'Destination.DriveRootNotAllowed' `
            -Message 'A dedicated staging directory is required; a drive root is too broad.'
    }

    $normalizedPath = $fullPath.TrimEnd([char]'\')
    $drive = Get-ProfileDestinationDriveInfo -DriveRoot $driveRoot
    Assert-ProfileDestinationDriveIsReadyAndFixed -DriveInfo $drive
    Assert-ProfileDestinationNotInSyncRoot -NormalizedPath $normalizedPath
    Assert-ProfileDestinationHasNoReparseAncestors `
        -NormalizedPath $normalizedPath -DriveRoot $driveRoot

    $destinationExists = Test-Path -LiteralPath $normalizedPath -PathType Container
    return [ordered]@{
        local_destination_confirmed = $true
        drive_ready = $true
        drive_type = 'Fixed'
        drive_format = $drive.DriveFormat
        available_free_bytes = [int64] $drive.AvailableFreeSpace
        destination_exists = [bool] $destinationExists
        reparse_ancestors_rejected = $true
        sync_roots_rejected = $true
    }
}

function Get-NativeVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    $command = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $command) {
        return [ordered]@{ available = $false; version = $null }
    }

    try {
        $outputLines = @(& $command.Path @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
        $output = ($outputLines | Out-String).Trim()
        return [ordered]@{
            available = $true
            exit_code = $exitCode
            version = $output
        }
    }
    catch {
        return [ordered]@{
            available = $true
            exit_code = $null
            version = $null
            probe_error = $_.Exception.GetType().FullName
        }
    }
}

function Get-EnvironmentProfileData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StagingRoot
    )

    # This is evaluated first. The profile cannot claim a safe local landing
    # zone merely because the string begins with a drive letter.
    $stagingProfile = Test-LocalStagingDestination -Path $StagingRoot

    $longPathsEnabled = $null
    try {
        $longPathSettings = Get-ItemProperty `
            -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
            -Name LongPathsEnabled -ErrorAction Stop
        $longPathsEnabled = [bool] $longPathSettings.LongPathsEnabled
    }
    catch {
        $longPathsEnabled = $null
    }

    $windowsIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $pesterVersion = Get-Module -ListAvailable -Name Pester |
        Sort-Object Version -Descending |
        Select-Object -ExpandProperty Version -First 1
    $robocopy = Get-Command -Name robocopy.exe -CommandType Application `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    $robocopyVersion = $null
    if ($null -ne $robocopy) {
        $robocopyVersion = (Get-Item -LiteralPath $robocopy.Path).VersionInfo.FileVersion
    }

    return [ordered]@{
        schema_version = '1.1'
        status = 'succeeded'
        powershell = [ordered]@{
            version = $PSVersionTable.PSVersion.ToString()
            edition = if ($PSVersionTable.ContainsKey('PSEdition')) { $PSVersionTable.PSEdition } else { 'Desktop' }
            clr_version = $PSVersionTable.CLRVersion.ToString()
        }
        operating_system = [ordered]@{
            version = [System.Environment]::OSVersion.Version.ToString()
            is_64_bit_os = [System.Environment]::Is64BitOperatingSystem
            is_64_bit_process = [System.Environment]::Is64BitProcess
            long_paths_enabled = $longPathsEnabled
        }
        locale = [ordered]@{
            culture = [System.Globalization.CultureInfo]::CurrentCulture.Name
            ui_culture = [System.Globalization.CultureInfo]::CurrentUICulture.Name
            console_output_encoding = [Console]::OutputEncoding.WebName
        }
        identity = [ordered]@{
            authenticated = $windowsIdentity.IsAuthenticated
            authentication_type = $windowsIdentity.AuthenticationType
            qualified_name_present = $windowsIdentity.Name.Contains('\')
        }
        staging = $stagingProfile
        tools = [ordered]@{
            robocopy = [ordered]@{
                available = ($null -ne $robocopy)
                version = $robocopyVersion
            }
            python = Get-NativeVersion -Name 'python' -Arguments @('--version')
            opencode = Get-NativeVersion -Name 'opencode' -Arguments @('--version')
            pester = [ordered]@{
                available = ($null -ne $pesterVersion)
                version = if ($null -ne $pesterVersion) { $pesterVersion.ToString() } else { $null }
            }
        }
    }
}

if (-not $script:IsEnvironmentProfileDotSourced) {
    try {
        try {
            [Console]::OutputEncoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
        }
        catch {
            # The JSON remains valid in embedded hosts that own console encoding.
        }
        $profile = Get-EnvironmentProfileData -StagingRoot $LocalStagingRoot
        [Console]::Out.WriteLine(($profile | ConvertTo-Json -Depth 8 -Compress))
        exit 0
    }
    catch {
        $failureClass = 'EnvironmentProfile.UnexpectedFailure'
        $message = 'The environment profile could not be completed safely.'
        if ($_.Exception.Data.Contains('FailureClass')) {
            $failureClass = [string] $_.Exception.Data['FailureClass']
            $message = $_.Exception.Message
        }

        # Never echo LocalStagingRoot or an exception-generated path.
        $failure = [ordered]@{
            schema_version = '1.1'
            status = 'failed'
            staging = [ordered]@{
                local_destination_confirmed = $false
                failure_class = $failureClass
                message = $message
            }
        }
        [Console]::Out.WriteLine(($failure | ConvertTo-Json -Depth 8 -Compress))
        exit 2
    }
}
