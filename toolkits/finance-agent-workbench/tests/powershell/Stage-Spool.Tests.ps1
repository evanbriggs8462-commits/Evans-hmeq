#requires -Version 5.1
# Pester 5.x tests for scripts/Stage-Spool.ps1.

BeforeAll {
    $repositoryRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $stageScript = Join-Path -Path $repositoryRoot -ChildPath 'scripts\Stage-Spool.ps1'

    # Supplying values satisfies the script-level mandatory parameters. Dot
    # sourcing defines the functions without executing the command entry point.
    . $stageScript -SourcePath '\\unit-server\approved\dummy.xml' `
        -DestinationRoot 'C:\UnitStage'

    $script:OriginalAllowedRoots = [System.Environment]::GetEnvironmentVariable(
        'SPOOL_ALLOWED_UNC_ROOTS',
        [System.EnvironmentVariableTarget]::Process
    )
}

AfterAll {
    [System.Environment]::SetEnvironmentVariable(
        'SPOOL_ALLOWED_UNC_ROOTS',
        $script:OriginalAllowedRoots,
        [System.EnvironmentVariableTarget]::Process
    )
}

Describe 'Stage-Spool source policy' {
    BeforeEach {
        $env:SPOOL_ALLOWED_UNC_ROOTS = '\\unit-server\approved;\\unit-server\second-root'
    }

    It 'accepts a literal XML path beneath an allowlisted root' {
        $resolved = Resolve-ApprovedSource -Path '\\unit-server\approved\exports\ledger.XML'

        $resolved.Path | Should -Be '\\unit-server\approved\exports\ledger.XML'
        $resolved.AllowedRoot | Should -Be '\\unit-server\approved'
    }

    It 'rejects wildcard source paths before any file access' {
        $caught = $null
        try {
            Resolve-ApprovedSource -Path '\\unit-server\approved\exports\*.xml'
        }
        catch {
            $caught = $_
        }

        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Data['FailureClass'] | Should -Be 'Validation.WildcardPath'
    }

    It 'rejects a sibling path that only shares the allowlist text prefix' {
        $caught = $null
        try {
            Resolve-ApprovedSource -Path '\\unit-server\approved-evil\ledger.xml'
        }
        catch {
            $caught = $_
        }

        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Data['FailureClass'] | Should -Be 'Policy.SourceOutsideAllowlist'
    }

    It 'rejects parent traversal and alternate data-stream syntax' {
        foreach ($unsafePath in @(
                '\\unit-server\approved\..\secret\ledger.xml',
                '\\unit-server\approved\ledger.xml:stream'
            )) {
            { Resolve-ApprovedSource -Path $unsafePath } | Should -Throw
        }
    }

    It 'does not expose a credential parameter' {
        $parameterNames = @((Get-Command -Name Invoke-SpoolStaging).Parameters.Keys)

        $parameterNames | Should -Not -Contain 'Credential'
        $parameterNames | Should -Not -Contain 'UserName'
        $parameterNames | Should -Not -Contain 'Password'
        $parameterNames | Should -Not -Contain 'Token'
    }
}

Describe 'Stage-Spool stability probes' {
    BeforeEach {
        $script:SnapshotCall = 0
        Mock -CommandName Start-Sleep
    }

    It 'requires every metadata probe to match' {
        Mock -CommandName Get-SpoolFileSnapshot -MockWith {
            [pscustomobject]@{
                Path                  = '\\unit-server\approved\ledger.xml'
                LengthBytes           = [int64] 1024
                LastWriteTimeUtc      = '2026-08-05T12:00:00.0000000Z'
                LastWriteTimeUtcTicks = [int64] 639215280000000000
            }
        }

        $snapshot = Assert-SourceStable `
            -LiteralPath '\\unit-server\approved\ledger.xml' `
            -ProbeCount 3 -ProbeSeconds 1

        $snapshot.LengthBytes | Should -Be 1024
        Should -Invoke -CommandName Get-SpoolFileSnapshot -Times 3 -Exactly
        Should -Invoke -CommandName Start-Sleep -Times 2 -Exactly
    }

    It 'fails with a typed class when length changes between probes' {
        Mock -CommandName Get-SpoolFileSnapshot -MockWith {
            $script:SnapshotCall++
            $length = [int64] 1024
            if ($script:SnapshotCall -gt 1) {
                $length = [int64] 2048
            }

            [pscustomobject]@{
                Path                  = '\\unit-server\approved\ledger.xml'
                LengthBytes           = $length
                LastWriteTimeUtc      = '2026-08-05T12:00:00.0000000Z'
                LastWriteTimeUtcTicks = [int64] 639215280000000000
            }
        }

        $caught = $null
        try {
            Assert-SourceStable -LiteralPath '\\unit-server\approved\ledger.xml' `
                -ProbeCount 3 -ProbeSeconds 1
        }
        catch {
            $caught = $_
        }

        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Data['FailureClass'] | Should -Be 'Source.UnstableDuringProbe'
        $caught.Exception.Data['ExitCode'] | Should -Be 4
    }
}

Describe 'Stage-Spool destination capacity' {
    It 'fails before copy when free space is below remaining bytes plus reserve' {
        $drive = [pscustomobject]@{ AvailableFreeSpace = [int64] 1099 }
        $stageFile = Join-Path -Path $TestDrive -ChildPath 'missing.xml'

        $caught = $null
        try {
            Assert-DestinationCapacity -DriveInfo $drive `
                -SourceLengthBytes 1000 -SafetyReserveBytes 100 `
                -StageFilePath $stageFile
        }
        catch {
            $caught = $_
        }

        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Data['FailureClass'] | Should -Be 'Destination.InsufficientSpace'
        $caught.Exception.Data['ExitCode'] | Should -Be 5
    }

    It 'credits an existing restartable partial file in the capacity calculation' {
        $stageFile = Join-Path -Path $TestDrive -ChildPath 'partial.xml'
        [System.IO.File]::WriteAllBytes($stageFile, [byte[]] (0..74))
        $drive = [pscustomobject]@{ AvailableFreeSpace = [int64] 40 }

        $capacity = Assert-DestinationCapacity -DriveInfo $drive `
            -SourceLengthBytes 100 -SafetyReserveBytes 10 `
            -StageFilePath $stageFile

        $capacity.ExistingStageBytes | Should -Be 75
        $capacity.RequiredFreeBytes | Should -Be 35
    }
}

Describe 'Stage-Spool destination trust boundary' {
    It 'rejects a ready network drive before creating DestinationRoot' {
        Mock -CommandName Get-DestinationDriveInfo -MockWith {
            [pscustomobject]@{
                IsReady = $true
                DriveType = [System.IO.DriveType]::Network
                AvailableFreeSpace = [int64] 1000000
            }
        }
        Mock -CommandName New-Item

        $caught = $null
        try {
            Resolve-LocalDestinationRoot -Path 'C:\UnitStage'
        }
        catch {
            $caught = $_
        }

        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Data['FailureClass'] | Should -Be 'Destination.NotFixedDrive'
        Should -Invoke -CommandName New-Item -Times 0 -Exactly
    }

    It 'rejects any existing reparse-point ancestor' {
        Mock -CommandName Test-Path -MockWith { $true }
        Mock -CommandName Get-Item -MockWith {
            param([string] $LiteralPath)
            $attributes = [System.IO.FileAttributes]::Directory
            if ($LiteralPath -eq 'C:\trusted\junction') {
                $attributes = $attributes -bor [System.IO.FileAttributes]::ReparsePoint
            }
            [pscustomobject]@{
                Attributes = $attributes
                PSIsContainer = $true
            }
        }

        $caught = $null
        try {
            Assert-DestinationPathHasNoReparseAncestors `
                -NormalizedPath 'C:\trusted\junction\stage' -DriveRoot 'C:\'
        }
        catch {
            $caught = $_
        }

        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Data['FailureClass'] | Should -Be 'Destination.ReparseAncestorNotAllowed'
    }

    It 'rejects a configured sync root before directory creation' {
        $originalOneDriveCommercial = $env:OneDriveCommercial
        try {
            $env:OneDriveCommercial = 'C:\CorporateSync'
            Mock -CommandName New-Item

            $caught = $null
            try {
                Resolve-LocalDestinationRoot -Path 'C:\CorporateSync\SpoolStage'
            }
            catch {
                $caught = $_
            }

            $caught | Should -Not -BeNullOrEmpty
            $caught.Exception.Data['FailureClass'] | Should -Be 'Destination.SyncRootNotAllowed'
            Should -Invoke -CommandName New-Item -Times 0 -Exactly
        }
        finally {
            $env:OneDriveCommercial = $originalOneDriveCommercial
        }
    }

    It 'checks the fixed volume and ancestors before creating the directory' {
        $script:DestinationValidationOrder = New-Object System.Collections.Generic.List[string]
        Mock -CommandName Get-DestinationDriveInfo -MockWith {
            [void] $script:DestinationValidationOrder.Add('drive')
            [pscustomobject]@{
                IsReady = $true
                DriveType = [System.IO.DriveType]::Fixed
                AvailableFreeSpace = [int64] 1000000
            }
        }
        Mock -CommandName Assert-DestinationPathHasNoReparseAncestors -MockWith {
            [void] $script:DestinationValidationOrder.Add('ancestors')
        }
        Mock -CommandName Test-Path -MockWith { $false }
        Mock -CommandName New-Item -MockWith {
            [void] $script:DestinationValidationOrder.Add('create')
        }

        $resolved = Resolve-LocalDestinationRoot -Path 'C:\UnitStage'

        $resolved.Path | Should -Be 'C:\UnitStage'
        $observedOrder = @($script:DestinationValidationOrder.ToArray())
        $observedOrder.Count | Should -Be 4
        $observedOrder[0] | Should -Be 'drive'
        $observedOrder[1] | Should -Be 'ancestors'
        $observedOrder[2] | Should -Be 'create'
        $observedOrder[3] | Should -Be 'ancestors'
    }
}

Describe 'Stage-Spool robocopy contract' {
    BeforeEach {
        $script:CapturedRobocopyArguments = @()
        $script:MockRobocopyExitCode = 0
        Mock -CommandName Invoke-NativeRobocopy -MockWith {
            param([string[]] $Arguments)
            $script:CapturedRobocopyArguments = @($Arguments)
            [pscustomobject]@{
                ExitCode = $script:MockRobocopyExitCode
                Output   = @()
            }
        }
    }

    It 'uses restartable unbuffered copy with bounded retries and no destructive switches' {
        [void] (Invoke-RobocopyCopy `
            -SourceDirectory '\\unit-server\approved\exports with spaces' `
            -StageDirectory 'C:\SpoolStage\.staging\abc.part' `
            -LeafName 'ledger file.xml' -RetryCount 2 -WaitSeconds 5)

        $script:CapturedRobocopyArguments[0] | Should -Be '\\unit-server\approved\exports with spaces'
        $script:CapturedRobocopyArguments[1] | Should -Be 'C:\SpoolStage\.staging\abc.part'
        $script:CapturedRobocopyArguments[2] | Should -Be 'ledger file.xml'
        $script:CapturedRobocopyArguments | Should -Contain '/Z'
        $script:CapturedRobocopyArguments | Should -Contain '/J'
        $script:CapturedRobocopyArguments | Should -Contain '/R:2'
        $script:CapturedRobocopyArguments | Should -Contain '/W:5'
        $script:CapturedRobocopyArguments | Should -Contain '/COPY:DT'
        $script:CapturedRobocopyArguments | Should -Contain '/IS'

        $destructive = @($script:CapturedRobocopyArguments | Where-Object {
                $_ -match '^/(MIR|MOV|MOVE|PURGE|DELETE)(:|$)'
            })
        $destructive.Count | Should -Be 0
    }

    It 'accepts every documented robocopy success-class exit code from 0 through 7' {
        foreach ($successCode in 0..7) {
            $script:MockRobocopyExitCode = $successCode
            $result = Invoke-RobocopyCopy `
                -SourceDirectory '\\unit-server\approved' `
                -StageDirectory 'C:\SpoolStage\.staging\abc.part' `
                -LeafName 'ledger.xml' -RetryCount 2 -WaitSeconds 5

            $result.ExitCode | Should -Be $successCode
        }
    }

    It 'rejects robocopy exit code 8 and higher as copy failures' {
        foreach ($failureCode in @(8, 16)) {
            $script:MockRobocopyExitCode = $failureCode
            $caught = $null
            try {
                Invoke-RobocopyCopy `
                    -SourceDirectory '\\unit-server\approved' `
                    -StageDirectory 'C:\SpoolStage\.staging\abc.part' `
                    -LeafName 'ledger.xml' -RetryCount 2 -WaitSeconds 5
            }
            catch {
                $caught = $_
            }

            $caught | Should -Not -BeNullOrEmpty
            $caught.Exception.Data['FailureClass'] | Should -Be 'Copy.RobocopyFailed'
            $caught.Exception.Data['ExitCode'] | Should -Be 6
        }
    }

    It 'redacts source and staging paths from a robocopy error envelope' {
        $script:DiagnosticSourceDirectory = '\\unit-server\approved\client folder'
        $script:DiagnosticStageDirectory = 'C:\SpoolStage\.staging\secret.part'
        $script:DiagnosticLeafName = 'client-ledger.xml'
        Mock -CommandName Invoke-NativeRobocopy -MockWith {
            [pscustomobject]@{
                ExitCode = 8
                Output   = @(('ERROR copying {0}\{1} to {2}' -f $script:DiagnosticSourceDirectory, $script:DiagnosticLeafName, $script:DiagnosticStageDirectory))
            }
        }

        $caught = $null
        try {
            Invoke-RobocopyCopy `
                -SourceDirectory $script:DiagnosticSourceDirectory `
                -StageDirectory $script:DiagnosticStageDirectory `
                -LeafName $script:DiagnosticLeafName -RetryCount 2 -WaitSeconds 5
        }
        catch {
            $caught = $_
        }

        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Message | Should -Not -Match ([regex]::Escape($script:DiagnosticSourceDirectory))
        $caught.Exception.Message | Should -Not -Match ([regex]::Escape($script:DiagnosticStageDirectory))
        $caught.Exception.Message | Should -Not -Match ([regex]::Escape($script:DiagnosticLeafName))
        $caught.Exception.Message | Should -Match '<source-directory>'
        $caught.Exception.Message | Should -Match '<stage-directory>'
    }
}

Describe 'Stage-Spool content-addressed promotion' {
    It 'treats an exact artifact created by a concurrent rename as idempotent success' {
        $store = Join-Path -Path $TestDrive -ChildPath 'race-store'
        $stageDirectory = Join-Path -Path $store -ChildPath '.staging\race.part'
        [void] (New-Item -ItemType Directory -Path $stageDirectory -Force)
        $stageFile = Join-Path -Path $stageDirectory -ChildPath 'ledger.xml'
        [System.IO.File]::WriteAllBytes($stageFile, [byte[]] (0..15))
        $sha256 = ('cd' * 32)

        Mock -CommandName Move-Item -MockWith {
            param([string] $LiteralPath, [string] $Destination)
            [System.IO.File]::Copy($LiteralPath, $Destination, $false)
            throw 'Synthetic concurrent destination race.'
        }
        Mock -CommandName Get-LocalSha256 -MockWith { $sha256 }

        $published = Publish-StagedArtifact -StageFilePath $stageFile `
            -DestinationRootPath $store -Sha256 $sha256 -LengthBytes 16

        $published.Reused | Should -BeTrue
        Test-Path -LiteralPath $published.ArtifactPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $stageFile | Should -BeFalse
        Should -Invoke -CommandName Get-LocalSha256 -Times 1 -Exactly
    }
}

Describe 'Stage-Spool end-to-end orchestration with mocked UNC and robocopy' {
    It 'promotes a complete local file, hashes locally, and writes a UTF-8 JSON receipt' {
        $source = '\\unit-server\approved\exports\ledger.xml'
        $store = Join-Path -Path $TestDrive -ChildPath 'store'
        [void] (New-Item -ItemType Directory -Path $store)
        $hash = ('ab' * 32)
        $script:ObservedStageDirectory = $null

        Mock -CommandName Resolve-ApprovedSource -MockWith {
            [pscustomobject]@{
                Path        = $source
                AllowedRoot = '\\unit-server\approved'
            }
        }
        Mock -CommandName Resolve-LocalDestinationRoot -MockWith {
            [pscustomobject]@{
                Path      = $store
                DriveInfo = [pscustomobject]@{
                    AvailableFreeSpace = [int64] 1073741824
                }
            }
        }
        Mock -CommandName Start-Sleep
        Mock -CommandName Get-SpoolFileSnapshot -MockWith {
            [pscustomobject]@{
                Path                  = $source
                LengthBytes           = [int64] 16
                LastWriteTimeUtc      = '2026-08-05T12:00:00.0000000Z'
                LastWriteTimeUtcTicks = [int64] 639215280000000000
            }
        }
        Mock -CommandName Invoke-RobocopyCopy -MockWith {
            param(
                [string] $SourceDirectory,
                [string] $StageDirectory,
                [string] $LeafName,
                [int] $RetryCount,
                [int] $WaitSeconds
            )
            $script:ObservedStageDirectory = $StageDirectory
            $localFile = Join-Path -Path $StageDirectory -ChildPath $LeafName
            [System.IO.File]::WriteAllBytes($localFile, [byte[]] (0..15))
            [System.IO.File]::SetLastWriteTimeUtc(
                $localFile,
                [System.DateTime]::Parse('2026-08-05T12:00:00.0000000Z').ToUniversalTime()
            )
            [pscustomobject]@{
                ExitCode = 1
                Flags    = [pscustomobject]@{
                    FilesCopied  = $true
                    ExtraFiles   = $false
                    Mismatches   = $false
                    CopyFailures = $false
                    FatalError   = $false
                }
            }
        }
        Mock -CommandName Get-LocalSha256 -MockWith { $hash }

        $result = Invoke-SpoolStaging -SourcePath $source `
            -DestinationRoot $store -StabilityProbeCount 2 `
            -StabilityProbeSeconds 1 -ReserveBytes 0 `
            -RobocopyRetryCount 2 -RobocopyWaitSeconds 5

        $result.status | Should -Be 'succeeded'
        $result.artifact.sha256 | Should -Be $hash
        $result.artifact.lengthBytes | Should -Be 16
        $result.artifact.readOnly | Should -BeTrue
        $script:ObservedStageDirectory | Should -Match '\.part$'
        $artifactPath = Join-Path -Path $store -ChildPath $result.artifact.relativePath
        $receiptPath = Join-Path -Path $store -ChildPath $result.receiptRelativePath
        Test-Path -LiteralPath $artifactPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $receiptPath -PathType Leaf | Should -BeTrue

        $receiptBytes = [System.IO.File]::ReadAllBytes($receiptPath)
        $receiptBytes[0] | Should -Be 123 # "{"; proves there is no UTF-8 BOM.
        $persisted = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        $persisted.schemaVersion | Should -Be 1
        $persisted.copy.exitCode | Should -Be 1
        $persisted.artifact.sha256 | Should -Be $hash

        $receiptJson = $result | ConvertTo-Json -Depth 8
        $receiptJson | Should -Not -Match ([regex]::Escape($source))
        $receiptJson | Should -Not -Match ([regex]::Escape($store))
        $receiptJson | Should -Not -Match ([regex]::Escape('ledger.xml'))
        $result.source.leafNameFingerprint | Should -Match '^[0-9a-f]{64}$'

        Should -Invoke -CommandName Get-SpoolFileSnapshot -Times 4 -Exactly
        Should -Invoke -CommandName Get-LocalSha256 -Times 1 -Exactly
    }
}
