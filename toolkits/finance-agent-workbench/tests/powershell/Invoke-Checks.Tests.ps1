#requires -Version 5.1
# Pester 5.x tests for the fail-closed Pester result gate.

BeforeAll {
    $repositoryRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $checksScript = Join-Path -Path $repositoryRoot -ChildPath 'scripts\Invoke-Checks.ps1'
    . $checksScript -SkipPython -SkipPowerShell
}

Describe 'Invoke-Checks Pester run assessment' {
    It 'accepts a Passed run with positive discovery and execution evidence' {
        $result = [pscustomobject]@{
            Result = 'Passed'
            TotalCount = 2
            PassedCount = 2
            FailedCount = 0
            SkippedCount = 0
            NotRunCount = 0
            FailedContainersCount = 0
            FailedBlocksCount = 0
            Containers = @()
        }

        $assessment = Test-PesterRunResult -PesterResult $result

        $assessment.Passed | Should -BeTrue
        $assessment.Evidence.run_result | Should -Be 'Passed'
        $assessment.Evidence.discovered_count | Should -Be 2
        $assessment.Evidence.executed_count | Should -Be 2
        $assessment.Evidence.executed_count_source | Should -Be 'PassedCount+FailedCount'
    }

    It 'rejects Result Failed even when FailedCount is zero' {
        $result = [pscustomobject]@{
            Result = 'Failed'
            TotalCount = 1
            PassedCount = 1
            FailedCount = 0
            FailedContainersCount = 0
            FailedBlocksCount = 0
            Containers = @()
        }

        $assessment = Test-PesterRunResult -PesterResult $result

        $assessment.Passed | Should -BeFalse
        $assessment.Reasons | Should -Contain 'Pester Result was not Passed.'
    }

    It 'rejects a failed discovery container when FailedCount is zero' {
        $result = [pscustomobject]@{
            Result = 'Passed'
            TotalCount = 1
            PassedCount = 1
            FailedCount = 0
            FailedContainersCount = 1
            FailedBlocksCount = 0
            Containers = @()
        }

        $assessment = Test-PesterRunResult -PesterResult $result

        $assessment.Passed | Should -BeFalse
        $assessment.Evidence.failed_containers_count | Should -Be 1
        $assessment.Reasons | Should -Contain 'Pester reported a discovery or container failure.'
    }

    It 'rejects container error records when count properties are absent or zero' {
        $result = [pscustomobject]@{
            Result = 'Passed'
            TotalCount = 1
            PassedCount = 1
            FailedCount = 0
            FailedContainersCount = 0
            FailedBlocksCount = 0
            Containers = @(
                [pscustomobject]@{
                    Result = 'Passed'
                    ErrorRecord = @(
                        [pscustomobject]@{ Message = 'Synthetic setup error.' }
                    )
                }
            )
        }

        $assessment = Test-PesterRunResult -PesterResult $result

        $assessment.Passed | Should -BeFalse
        $assessment.Evidence.container_error_records | Should -Be 1
    }

    It 'rejects a block setup failure when FailedCount is zero' {
        $result = [pscustomobject]@{
            Result = 'Passed'
            TotalCount = 1
            PassedCount = 1
            FailedCount = 0
            FailedContainersCount = 0
            FailedBlocksCount = 1
            Containers = @()
        }

        $assessment = Test-PesterRunResult -PesterResult $result

        $assessment.Passed | Should -BeFalse
        $assessment.Evidence.failed_blocks_count | Should -Be 1
        $assessment.Reasons | Should -Contain 'Pester reported a block setup or teardown failure.'
    }

    It 'rejects a Passed run that discovered zero tests' {
        $result = [pscustomobject]@{
            Result = 'Passed'
            TotalCount = 0
            PassedCount = 0
            FailedCount = 0
            SkippedCount = 0
            NotRunCount = 0
            FailedContainersCount = 0
            FailedBlocksCount = 0
            Containers = @()
        }

        $assessment = Test-PesterRunResult -PesterResult $result

        $assessment.Passed | Should -BeFalse
        $assessment.Evidence.discovered_count | Should -Be 0
        $assessment.Reasons | Should -Contain 'Pester discovered zero tests or supplied no discovery count.'
    }

    It 'rejects a Passed run where every discovered test was skipped' {
        $result = [pscustomobject]@{
            Result = 'Passed'
            TotalCount = 2
            PassedCount = 0
            FailedCount = 0
            SkippedCount = 2
            NotRunCount = 0
            FailedContainersCount = 0
            FailedBlocksCount = 0
            Containers = @()
        }

        $assessment = Test-PesterRunResult -PesterResult $result

        $assessment.Passed | Should -BeFalse
        $assessment.Evidence.executed_count | Should -Be 0
        $assessment.Reasons | Should -Contain 'Pester executed zero tests or supplied no execution evidence.'
    }

    It 'supports a Pester 5 shape that exposes Tests instead of aggregate discovery and pass counts' {
        $result = [pscustomobject]@{
            Result = 'Passed'
            FailedCount = 0
            FailedContainers = @()
            FailedBlocks = @()
            Containers = @()
            Tests = @(
                [pscustomobject]@{ Executed = $true; Result = 'Passed' },
                [pscustomobject]@{ Executed = $true; Result = 'Passed' }
            )
        }

        $assessment = Test-PesterRunResult -PesterResult $result

        $assessment.Passed | Should -BeTrue
        $assessment.Evidence.discovered_count | Should -Be 2
        $assessment.Evidence.discovered_count_source | Should -Be 'Tests.Count'
        $assessment.Evidence.executed_count | Should -Be 2
        $assessment.Evidence.executed_count_source | Should -Be 'Tests.Executed'
    }
}
