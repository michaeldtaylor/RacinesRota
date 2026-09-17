#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
#
# Constraints.Tests.ps1 -- one evaluator at a time, against hand-built schedules.
#
# Each rule is tested in both directions: a schedule that satisfies it must produce no
# violation, and a schedule that breaks it must name the person, week and service. A rule
# that only ever gets tested in the passing direction is a rule that might not be wired up.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-RotaModuleForTests

    function New-ScheduleWithSolved {
        param($Config, [int]$Week1Mask, [int]$Week2Mask = -1)
        if (-not $Config) { $Config = New-TestRotaConfig }
        if ($Week2Mask -lt 0) { $Week2Mask = $Week1Mask }
        $schedule = New-RotaSchedule -Config $Config
        Add-RotaFixedStaff -Schedule $schedule | Out-Null
        Set-RotaWeekMask -Schedule $schedule -Person 'Solved' -Week 1 -Mask $Week1Mask
        Set-RotaWeekMask -Schedule $schedule -Person 'Solved' -Week 2 -Mask $Week2Mask
        $schedule
    }

    # Off Samedi and Dimanche, working Monday to Friday lunches: legal in the fixture.
    function Get-WeekdayLunchMask { param($Config)
        New-RotaMaskFromDays -Config $Config -Days @{
            Lundi = 'L'; Mardi = 'L'; Mercredi = 'L'; Jeudi = 'L'; Vendredi = 'L'
        }
    }
}

Describe 'H1 coverage' {
    It 'reports nothing when every service has exactly the required number' {
        # The fixture needs 1 per service and Boss works all 14, so adding nobody is exact.
        $schedule = New-ScheduleWithSolved -Week1Mask 0
        @(Test-RotaCoverage -Schedule $schedule) | Should -BeNullOrEmpty
    }

    It 'reports an overstaffed service' {
        $cfg = New-TestRotaConfig
        $mask = New-RotaMaskFromDays -Config $cfg -Days @{ Mardi = 'L' }
        $schedule = New-ScheduleWithSolved -Config $cfg -Week1Mask $mask
        $v = @(Test-RotaCoverage -Schedule $schedule)
        $v.Count | Should -Be 2                  # same mask in both cycle weeks
        $v[0].Message | Should -Match 'over by 1'
    }

    It 'reports an understaffed service' {
        $cfg = New-TestRotaConfig -RequiredPerService 2
        $schedule = New-ScheduleWithSolved -Config $cfg -Week1Mask 0
        $v = @(Test-RotaCoverage -Schedule $schedule)
        $v.Count | Should -Be 28
        $v[0].Message | Should -Match 'short by 1'
    }
}

Describe 'H2 responsable' {
    It 'passes when a responsable is on every service' {
        $schedule = New-ScheduleWithSolved -Week1Mask 0
        @(Test-RotaResponsable -Schedule $schedule) | Should -BeNullOrEmpty
    }

    It 'reports services with nobody in charge' {
        $cfg = New-TestRotaConfig
        $cfg.staff[0].responsable = $false
        $cfg = ConvertTo-RotaNormalisedConfig -Config $cfg
        $schedule = New-ScheduleWithSolved -Config $cfg -Week1Mask 0
        @(Test-RotaResponsable -Schedule $schedule).Count | Should -Be 28
    }
}

Describe 'H4 shift ceiling and target' {
    It 'accepts working exactly the contracted number' {
        $cfg = New-TestRotaConfig -SolvedShifts 5
        $schedule = New-ScheduleWithSolved -Config $cfg -Week1Mask (Get-WeekdayLunchMask -Config $cfg)
        @(Test-RotaShiftCount -Schedule $schedule) | Should -BeNullOrEmpty
    }

    It 'reports exceeding the ceiling as a hard violation' {
        $cfg = New-TestRotaConfig -SolvedShifts 2
        $schedule = New-ScheduleWithSolved -Config $cfg -Week1Mask (Get-WeekdayLunchMask -Config $cfg)
        $v = @(Test-RotaShiftCount -Schedule $schedule | Where-Object Id -eq 'H4-ShiftCeiling')
        $v.Count | Should -Be 2
        $v[0].Severity | Should -Be 'Hard'
    }

    It 'reports working under the target as a soft violation only' {
        $cfg = New-TestRotaConfig -SolvedShifts 5
        $mask = New-RotaMaskFromDays -Config $cfg -Days @{ Lundi = 'L'; Mardi = 'L' }
        $schedule = New-ScheduleWithSolved -Config $cfg -Week1Mask $mask
        $v = @(Test-RotaShiftCount -Schedule $schedule)
        $v | ForEach-Object { $_.Severity | Should -Be 'Soft' }
        $v[0].Id | Should -Be 'S3-ShiftUnderrun'
    }

    It 'charges a concentrated shortfall more than a spread one' {
        # Two people one short each must beat one person two short, or the engine will always
        # dump the whole loss on a single person's week.
        $cfg = New-TestRotaConfig -SolvedShifts 5
        $oneShort = New-RotaMaskFromDays -Config $cfg -Days @{ Lundi = 'L'; Mardi = 'L'; Mercredi = 'L'; Jeudi = 'L' }
        $twoShort = New-RotaMaskFromDays -Config $cfg -Days @{ Lundi = 'L'; Mardi = 'L'; Mercredi = 'L' }

        $spread = New-ScheduleWithSolved -Config $cfg -Week1Mask $oneShort -Week2Mask $oneShort
        $heaped = New-ScheduleWithSolved -Config $cfg -Week1Mask $twoShort -Week2Mask (Get-WeekdayLunchMask -Config $cfg)

        $spreadCost = (@(Test-RotaShiftCount -Schedule $spread) | Measure-Object -Property Cost -Sum).Sum
        $heapedCost = (@(Test-RotaShiftCount -Schedule $heaped) | Measure-Object -Property Cost -Sum).Sum
        $spreadCost | Should -BeLessThan $heapedCost
    }

    It 'allows a cover worker with a zero target to work up to their ceiling' {
        $cfg = New-TestRotaConfig -SolvedShifts 0
        foreach ($w in '1', '2') {
            $cfg.staff[1].weeks.$w | Add-Member -NotePropertyName maxShifts -NotePropertyValue 5 -Force
        }
        $cfg = ConvertTo-RotaNormalisedConfig -Config $cfg
        $schedule = New-ScheduleWithSolved -Config $cfg -Week1Mask (Get-WeekdayLunchMask -Config $cfg)
        @(Test-RotaShiftCount -Schedule $schedule | Where-Object Id -eq 'H4-ShiftCeiling') | Should -BeNullOrEmpty
    }
}

Describe 'H5 doubles' {
    It 'permits a double when doubles are allowed' {
        $cfg = New-TestRotaConfig -Doubles $true -SolvedShifts 2
        $schedule = New-ScheduleWithSolved -Config $cfg -Week1Mask (New-RotaMaskFromDays -Config $cfg -Days @{ Mardi = 'LD' })
        @(Test-RotaDoubles -Schedule $schedule) | Should -BeNullOrEmpty
    }

    It 'reports a double when doubles are forbidden' {
        $cfg = New-TestRotaConfig -Doubles $false -SolvedShifts 2
        $schedule = New-ScheduleWithSolved -Config $cfg -Week1Mask (New-RotaMaskFromDays -Config $cfg -Days @{ Mardi = 'LD' })
        $v = @(Test-RotaDoubles -Schedule $schedule)
        $v.Count | Should -Be 2
        $v[0].Day | Should -Be 'Mardi'
    }
}

Describe 'H6 slot eligibility' {
    It 'reports a dinner when dinner is NO' {
        $cfg = New-TestRotaConfig -Dinner 'NO' -SolvedShifts 1
        $schedule = New-ScheduleWithSolved -Config $cfg -Week1Mask (New-RotaMaskFromDays -Config $cfg -Days @{ Mardi = 'D' })
        @(Test-RotaSlotEligibility -Schedule $schedule).Count | Should -Be 2
    }

    It 'reports a dinner when lunch is OBLIG' {
        $cfg = New-TestRotaConfig -Lunch 'OBLIG' -SolvedShifts 1
        $schedule = New-ScheduleWithSolved -Config $cfg -Week1Mask (New-RotaMaskFromDays -Config $cfg -Days @{ Mardi = 'D' })
        @(Test-RotaSlotEligibility -Schedule $schedule).Count | Should -Be 2
    }

    It 'accepts a lunch when lunch is OBLIG' {
        $cfg = New-TestRotaConfig -Lunch 'OBLIG' -SolvedShifts 1
        $schedule = New-ScheduleWithSolved -Config $cfg -Week1Mask (New-RotaMaskFromDays -Config $cfg -Days @{ Mardi = 'L' })
        @(Test-RotaSlotEligibility -Schedule $schedule) | Should -BeNullOrEmpty
    }

    It 'treats PREF as soft, not hard' {
        $cfg = New-TestRotaConfig -Lunch 'PREF' -SolvedShifts 1
        $schedule = New-ScheduleWithSolved -Config $cfg -Week1Mask (New-RotaMaskFromDays -Config $cfg -Days @{ Mardi = 'D' })
        @(Test-RotaSlotEligibility -Schedule $schedule) | Should -BeNullOrEmpty
        @(Test-RotaSlotPreference -Schedule $schedule).Count | Should -Be 2
    }
}

Describe 'H7 weekend availability' {
    It 'reports weekend work when the person is unavailable at weekends' {
        $cfg = New-TestRotaConfig -Weekend $false -SolvedShifts 1
        $schedule = New-ScheduleWithSolved -Config $cfg -Week1Mask (New-RotaMaskFromDays -Config $cfg -Days @{ Samedi = 'L' })
        $v = @(Test-RotaWeekendAvailability -Schedule $schedule)
        $v.Count | Should -Be 2
        $v[0].Day | Should -Be 'Samedi'
    }

    It 'allows midweek work for the same person' {
        $cfg = New-TestRotaConfig -Weekend $false -SolvedShifts 1
        $schedule = New-ScheduleWithSolved -Config $cfg -Week1Mask (New-RotaMaskFromDays -Config $cfg -Days @{ Mardi = 'L' })
        @(Test-RotaWeekendAvailability -Schedule $schedule) | Should -BeNullOrEmpty
    }
}

Describe 'H8/H9 consecutive days off' {
    It 'passes when the run is present in both weeks' {
        $cfg = New-TestRotaConfig -SolvedShifts 5
        $schedule = New-ScheduleWithSolved -Config $cfg -Week1Mask (Get-WeekdayLunchMask -Config $cfg)
        @(Test-RotaConsecutiveDaysOff -Schedule $schedule | Where-Object Person -eq 'Solved') | Should -BeNullOrEmpty
    }

    It 'REGRESSION: a long break in one week does not excuse the other' {
        # Works all seven days of week 1, entirely free in week 2. Under the old per-cycle
        # rule this passed; "two days off in a row" is a promise made every week.
        $cfg = New-TestRotaConfig -SolvedShifts 7
        $all = New-RotaMaskFromDays -Config $cfg -Days @{
            Lundi = 'L'; Mardi = 'L'; Mercredi = 'L'; Jeudi = 'L'; Vendredi = 'L'; Samedi = 'L'; Dimanche = 'L'
        }
        $schedule = New-ScheduleWithSolved -Config $cfg -Week1Mask $all -Week2Mask 0
        $v = @(Test-RotaConsecutiveDaysOff -Schedule $schedule | Where-Object Person -eq 'Solved')
        $v.Count | Should -Be 1
        $v[0].Week | Should -Be 1
    }

    It 'accepts the same schedule when daysOffScope is cycle' {
        $cfg = New-TestRotaConfig -SolvedShifts 7 -Rules @{ daysOffScope = 'cycle' }
        $all = New-RotaMaskFromDays -Config $cfg -Days @{
            Lundi = 'L'; Mardi = 'L'; Mercredi = 'L'; Jeudi = 'L'; Vendredi = 'L'; Samedi = 'L'; Dimanche = 'L'
        }
        $schedule = New-ScheduleWithSolved -Config $cfg -Week1Mask $all -Week2Mask 0
        @(Test-RotaConsecutiveDaysOff -Schedule $schedule | Where-Object Person -eq 'Solved') | Should -BeNullOrEmpty
    }

    It 'applies the global floor to fixed staff too' {
        # Boss works every service of every day and can never get two days off.
        $schedule = New-ScheduleWithSolved -Week1Mask 0
        $v = @(Test-RotaConsecutiveDaysOff -Schedule $schedule | Where-Object Person -eq 'Boss')
        $v.Count | Should -Be 2
        $v[0].Id | Should -Be 'H9-DaysOffFloor'
    }
}

Describe 'S7 temporary cover' {
    It 'charges nothing when no temporary staff exist' {
        $schedule = New-ScheduleWithSolved -Week1Mask 0
        @(Test-RotaTemporaryStaff -Schedule $schedule) | Should -BeNullOrEmpty
    }

    It 'charges per shift and names the exposure' {
        $cfg = New-TestRotaConfig -SolvedShifts 0
        $cfg.staff[1] | Add-Member -NotePropertyName temporary -NotePropertyValue $true -Force
        foreach ($w in '1', '2') {
            $cfg.staff[1].weeks.$w | Add-Member -NotePropertyName maxShifts -NotePropertyValue 5 -Force
        }
        $cfg = ConvertTo-RotaNormalisedConfig -Config $cfg
        $mask = New-RotaMaskFromDays -Config $cfg -Days @{ Lundi = 'L'; Mardi = 'L' }
        $schedule = New-ScheduleWithSolved -Config $cfg -Week1Mask $mask

        $v = @(Test-RotaTemporaryStaff -Schedule $schedule)
        $v.Count | Should -Be 1
        $v[0].Cost | Should -Be (300 * 4)          # 2 shifts in each of 2 weeks
        $v[0].Message | Should -Match 'become gaps'
    }
}

Describe 'The constraint registry' {
    It 'runs every registered evaluator through Test-RotaSchedule' {
        $schedule = New-ScheduleWithSolved -Week1Mask 0
        { Test-RotaSchedule -Schedule $schedule } | Should -Not -Throw
    }

    It 'gives every violation an id, a severity and a non-negative cost' {
        $cfg = New-TestRotaConfig -RequiredPerService 2
        $schedule = New-ScheduleWithSolved -Config $cfg -Week1Mask 0
        foreach ($v in (Test-RotaSchedule -Schedule $schedule)) {
            $v.Id | Should -Not -BeNullOrEmpty
            $v.Severity | Should -BeIn @('Hard', 'Soft')
            $v.Cost | Should -BeGreaterOrEqual 0
        }
    }

    It 'sums violation costs into the score' {
        $cfg = New-TestRotaConfig -RequiredPerService 2
        $schedule = New-ScheduleWithSolved -Config $cfg -Week1Mask 0
        $violations = Test-RotaSchedule -Schedule $schedule
        Get-RotaScore -Schedule $schedule -Violations $violations |
            Should -Be ($violations | Measure-Object -Property Cost -Sum).Sum
    }
}
