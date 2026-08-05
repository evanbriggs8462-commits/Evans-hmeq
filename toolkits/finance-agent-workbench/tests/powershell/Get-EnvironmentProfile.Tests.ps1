#requires -Version 5.1
# Pester 5.x tests for scripts/Get-EnvironmentProfile.ps1.

BeforeAll {
    $repositoryRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $profileScript = Join-Path -Path $repositoryRoot -ChildPath 'scripts\Get-EnvironmentProfile.ps1'
    . $profileScript -LocalStagingRoot 'C:\UnitStage'

    $script:OriginalOneDrive = $env:OneDrive
    $script:OriginalOneDriveCommercial = $env:OneDriveCommercial
    $script:OriginalOneDriveConsumer = $env:OneDriveConsumer
}

AfterAll {
    $env:OneDrive = $script:OriginalOneDrive
    $env:OneDriveCommercial = $script:OriginalOneDriveCommercial
    $env:OneDriveConsumer = $script:OriginalOneDriveConsumer
}

Describe 'Get-EnvironmentProfile destination evidence' {
    BeforeEach {
        $env:OneDrive = $null
        $env:OneDriveCommercial = $null
        $env:OneDriveConsumer = $null
    }

    It 'does not confirm a ready network volume as local staging' {
        Mock -CommandName Get-ProfileDestinationDriveInfo -MockWith {
            [pscustomobject]@{
                IsReady = $true
                DriveType = [System.IO.DriveType]::Network
                DriveFormat = 'NTFS'
                AvailableFreeSpace = [int64] 1000000
            }
        }
        Mock -CommandName Assert-ProfileDestinationHasNoReparseAncestors

        $caught = $null
        try {
            Test-LocalStagingDestination -Path 'C:\UnitStage'
        }
        catch {
            $caught = $_
        }

        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Data['FailureClass'] | Should -Be 'Destination.NotFixedDrive'
        Should -Invoke -CommandName Assert-ProfileDestinationHasNoReparseAncestors -Times 0 -Exactly
    }

    It 'does not confirm a fixed volume that is not ready' {
        Mock -CommandName Get-ProfileDestinationDriveInfo -MockWith {
            [pscustomobject]@{
                IsReady = $false
                DriveType = [System.IO.DriveType]::Fixed
                DriveFormat = 'NTFS'
                AvailableFreeSpace = [int64] 1000000
            }
        }

        $caught = $null
        try {
            Test-LocalStagingDestination -Path 'C:\UnitStage'
        }
        catch {
            $caught = $_
        }

        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Data['FailureClass'] | Should -Be 'Destination.VolumeNotReady'
    }

    It 'rejects alternate data-stream destination syntax before volume inspection' {
        Mock -CommandName Get-ProfileDestinationDriveInfo

        { Test-LocalStagingDestination -Path 'C:\UnitStage:stream' } | Should -Throw
        Should -Invoke -CommandName Get-ProfileDestinationDriveInfo -Times 0 -Exactly
    }

    It 'confirms local staging only after fixed-volume, sync-root, and ancestor checks pass' {
        Mock -CommandName Get-ProfileDestinationDriveInfo -MockWith {
            [pscustomobject]@{
                IsReady = $true
                DriveType = [System.IO.DriveType]::Fixed
                DriveFormat = 'NTFS'
                AvailableFreeSpace = [int64] 1000000
            }
        }
        Mock -CommandName Assert-ProfileDestinationNotInSyncRoot
        Mock -CommandName Assert-ProfileDestinationHasNoReparseAncestors
        Mock -CommandName Test-Path -MockWith { $false }

        $result = Test-LocalStagingDestination -Path 'C:\UnitStage'

        $result.local_destination_confirmed | Should -BeTrue
        $result.drive_ready | Should -BeTrue
        $result.drive_type | Should -Be 'Fixed'
        $result.reparse_ancestors_rejected | Should -BeTrue
        $result.sync_roots_rejected | Should -BeTrue
        ($result | ConvertTo-Json -Depth 8) | Should -Not -Match 'UnitStage'
        Should -Invoke -CommandName Assert-ProfileDestinationNotInSyncRoot -Times 1 -Exactly
        Should -Invoke -CommandName Assert-ProfileDestinationHasNoReparseAncestors -Times 1 -Exactly
    }

    It 'rejects a configured sync-root destination' {
        $env:OneDriveCommercial = 'C:\CorporateSync'

        $caught = $null
        try {
            Assert-ProfileDestinationNotInSyncRoot `
                -NormalizedPath 'C:\CorporateSync\SpoolStage'
        }
        catch {
            $caught = $_
        }

        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Data['FailureClass'] | Should -Be 'Destination.SyncRootNotAllowed'
    }

    It 'rejects an existing ancestor junction or symbolic link' {
        Mock -CommandName Test-Path -MockWith { $true }
        Mock -CommandName Get-Item -MockWith {
            param([string] $LiteralPath)
            $attributes = [System.IO.FileAttributes]::Directory
            if ($LiteralPath -eq 'C:\trusted\link') {
                $attributes = $attributes -bor [System.IO.FileAttributes]::ReparsePoint
            }
            [pscustomobject]@{
                Attributes = $attributes
                PSIsContainer = $true
            }
        }

        $caught = $null
        try {
            Assert-ProfileDestinationHasNoReparseAncestors `
                -NormalizedPath 'C:\trusted\link\stage' -DriveRoot 'C:\'
        }
        catch {
            $caught = $_
        }

        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Data['FailureClass'] | Should -Be 'Destination.ReparseAncestorNotAllowed'
    }

    It 'emits sanitized failure JSON without echoing a rejected path' {
        $rejectedPath = '\\private-server\sensitive-share\client-folder'
        $powerShellExe = (Get-Command -Name powershell.exe -CommandType Application `
            -ErrorAction Stop).Path

        $output = @(& $powerShellExe -NoLogo -NoProfile -NonInteractive `
            -File $profileScript -LocalStagingRoot $rejectedPath 2>$null)
        $profileExitCode = $LASTEXITCODE
        $json = ($output -join [System.Environment]::NewLine)
        $failure = $json | ConvertFrom-Json

        $profileExitCode | Should -Be 2
        $failure.status | Should -Be 'failed'
        $failure.staging.local_destination_confirmed | Should -BeFalse
        $json | Should -Not -Match ([regex]::Escape($rejectedPath))
        $json | Should -Not -Match 'private-server|sensitive-share|client-folder'
    }
}
