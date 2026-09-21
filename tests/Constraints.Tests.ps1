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

Describe 'S8 days-off preference' {
    # consecutiveDaysOff is a promise; preferredConsecutiveDaysOff is a wish. The engine
    # reaches for the wish and reports when it misses, but never fails a schedule over it.

    BeforeAll {
        function New-PreferenceConfig {
            param([double]$Owed = 2, [double]$Wanted = 3.5, [int]$Shifts = 4, [int]$Required = 1)
            $cfg = New-TestRotaConfig -ConsecutiveDaysOff $Owed -SolvedShifts $Shifts -RequiredPerService $Required
            $cfg.staff[1] | Add-Member -NotePropertyName preferredConsecutiveDaysOff -NotePropertyValue $Wanted -Force
            ConvertTo-RotaNormalisedConfig -Config $cfg
        }
    }

    It 'says nothing when nobody has expressed a preference' {
        $schedule = New-ScheduleWithSolved -Week1Mask (Get-WeekdayLunchMask -Config (New-TestRotaConfig))
        @(Test-RotaDaysOffPreference -Schedule $schedule) | Should -BeNullOrEmpty
    }

    It 'says nothing when the preferred run is achieved' {
        # Lundi to Mercredi lunches leaves Jeudi through Dimanche off -- four whole days.
        $cfg = New-PreferenceConfig -Owed 2 -Wanted 3.5 -Shifts 3
        $mask = New-RotaMaskFromDays -Config $cfg -Days @{ Lundi = 'L'; Mardi = 'L'; Mercredi = 'L' }
        $schedule = New-ScheduleWithSolved -Config $cfg -Week1Mask $mask
        @(Test-RotaDaysOffPreference -Schedule $schedule) | Should -BeNullOrEmpty
    }

    It 'reports a missed preference as SOFT, never hard' {
        # Monday to Friday lunches leaves only Samedi and Dimanche: meets the 2 they are
        # owed, misses the 3.5 they would like.
        $cfg = New-PreferenceConfig -Owed 2 -Wanted 3.5 -Shifts 5
        $schedule = New-ScheduleWithSolved -Config $cfg -Week1Mask (Get-WeekdayLunchMask -Config $cfg)

        $v = @(Test-RotaDaysOffPreference -Schedule $schedule)
        $v.Count | Should -BeGreaterThan 0
        foreach ($x in $v) {
            $x.Severity | Should -Be 'Soft'
            $x.Id | Should -Be 'S8-DaysOffPreference'
            $x.Message | Should -Match 'would prefer'
        }
        # ...and the person it applies to breaks no hard rule, which is the whole point.
        # (Boss is fixed and works every day in this fixture, so H9 always fires for him.)
        $hard = @(Test-RotaConsecutiveDaysOff -Schedule $schedule | Where-Object Person -eq 'Solved')
        $hard | Should -BeNullOrEmpty
    }

    It 'costs the shortfall, so a near miss reads as a near miss' {
        $near = New-PreferenceConfig -Owed 2 -Wanted 3 -Shifts 5
        $far = New-PreferenceConfig -Owed 2 -Wanted 5 -Shifts 5
        $nearCost = (@(Test-RotaDaysOffPreference -Schedule (New-ScheduleWithSolved -Config $near -Week1Mask (Get-WeekdayLunchMask -Config $near))) | Measure-Object Cost -Sum).Sum
        $farCost = (@(Test-RotaDaysOffPreference -Schedule (New-ScheduleWithSolved -Config $far -Week1Mask (Get-WeekdayLunchMask -Config $far))) | Measure-Object Cost -Sum).Sum
        $farCost | Should -BeGreaterThan $nearCost
    }

    It 'ignores a preference that is not above what the person is already owed' {
        $cfg = New-PreferenceConfig -Owed 3.5 -Wanted 3.5 -Shifts 4
        $schedule = New-ScheduleWithSolved -Config $cfg -Week1Mask (Get-WeekdayLunchMask -Config $cfg)
        @(Test-RotaDaysOffPreference -Schedule $schedule) | Should -BeNullOrEmpty
    }

    It 'rejects such a preference in config, rather than leaving it dead' {
        $cfg = New-PreferenceConfig -Owed 3.5 -Wanted 3.5
        @(Test-RotaConfig -Config $cfg) -join ' ' | Should -BeLike '*not above what they are already owed*'
    }

    It 'never changes which schedules are legal' {
        # The real guarantee: bolting a preference onto a roster must not alter feasibility.
        # Solve the same roster twice, once with the preference and once without, and the
        # hard outcome must be identical -- only the soft report differs.
        $rules = @{ minConsecutiveDaysOffForEveryone = 0 }
        $plain = New-TestRotaConfig -RequiredPerService 2 -SolvedShifts 10 -Rules $rules

        $withPref = New-TestRotaConfig -RequiredPerService 2 -SolvedShifts 10 -Rules $rules
        $withPref.staff[1] | Add-Member -NotePropertyName preferredConsecutiveDaysOff -NotePropertyValue 5 -Force
        $withPref = ConvertTo-RotaNormalisedConfig -Config $withPref

        $a = Invoke-RotaSolver -Config $plain -ShortlistSize 20
        $b = Invoke-RotaSolver -Config $withPref -ShortlistSize 20

        $hardA = @($a.Violations | Where-Object Severity -eq 'Hard')
        $hardB = @($b.Violations | Where-Object Severity -eq 'Hard')
        $hardB.Count | Should -Be $hardA.Count

        # Same shifts placed, so the preference cost nobody any work.
        for ($w = 1; $w -le 2; $w++) {
            $shiftsA = Get-RotaMaskPopCount -Mask $a.Schedule.Masks["Solved|$w"]
            $shiftsB = Get-RotaMaskPopCount -Mask $b.Schedule.Masks["Solved|$w"]
            $shiftsB | Should -Be $shiftsA
        }

        # And the preference is genuinely unreachable here, so it really was exercised.
        @($b.Violations | Where-Object Id -eq 'S8-DaysOffPreference').Count | Should -BeGreaterThan 0
        @($a.Violations | Where-Object Id -eq 'S8-DaysOffPreference') | Should -BeNullOrEmpty
    }
}

Describe 'H10 per-day availability' {
    # A week spec speaks in whole slots -- no weekends, lunches only. It cannot say "Monday
    # dinner but no other dinner". staff[].available names the exact services.

    BeforeAll {
        function New-AvailabilityConfig {
            param($Available, [int]$Shifts = 2)
            $cfg = New-TestRotaConfig -SolvedShifts $Shifts
            $cfg.staff[1] | Add-Member -NotePropertyName available -NotePropertyValue ([pscustomobject]$Available) -Force
            ConvertTo-RotaNormalisedConfig -Config $cfg
        }
    }

    It 'says nothing when no availability is declared' {
        $cfg = New-TestRotaConfig
        $mask = New-RotaMaskFromDays -Config $cfg -Days @{ Lundi = 'LD'; Samedi = 'LD' }
        $schedule = New-ScheduleWithSolved -Config $cfg -Week1Mask $mask
        @(Test-RotaAvailability -Schedule $schedule) | Should -BeNullOrEmpty
    }

    It 'accepts a roster inside the declared availability' {
        $cfg = New-AvailabilityConfig @{ Lundi = @('Lunch', 'Dinner'); Mardi = @('Lunch') }
        $mask = New-RotaMaskFromDays -Config $cfg -Days @{ Lundi = 'LD'; Mardi = 'L' }
        $schedule = New-ScheduleWithSolved -Config $cfg -Week1Mask $mask
        @(Test-RotaAvailability -Schedule $schedule) | Should -BeNullOrEmpty
    }

    It 'names the exact service when someone is rostered outside it' {
        # Available for Tuesday lunch only, but rostered on Tuesday dinner.
        $cfg = New-AvailabilityConfig @{ Lundi = @('Lunch'); Mardi = @('Lunch') }
        $mask = New-RotaMaskFromDays -Config $cfg -Days @{ Lundi = 'L'; Mardi = 'D' }
        $schedule = New-ScheduleWithSolved -Config $cfg -Week1Mask $mask -Week2Mask 0

        $v = @(Test-RotaAvailability -Schedule $schedule)
        $v.Count | Should -Be 1
        $v[0].Severity | Should -Be 'Hard'
        $v[0].Id | Should -Be 'H10-Availability'
        $v[0].Day | Should -Be 'Mardi'
        $v[0].Slot | Should -Be 'Dinner'
        $v[0].Message | Should -Match 'not available'
    }

    It 'distinguishes days: dinner allowed on one day is not allowed on another' {
        $cfg = New-AvailabilityConfig @{ Lundi = @('Lunch', 'Dinner'); Mardi = @('Lunch') }
        $ok = New-RotaMaskFromDays -Config $cfg -Days @{ Lundi = 'D' }
        $bad = New-RotaMaskFromDays -Config $cfg -Days @{ Mardi = 'D' }
        @(Test-RotaAvailability -Schedule (New-ScheduleWithSolved -Config $cfg -Week1Mask $ok -Week2Mask 0)) | Should -BeNullOrEmpty
        @(Test-RotaAvailability -Schedule (New-ScheduleWithSolved -Config $cfg -Week1Mask $bad -Week2Mask 0)).Count | Should -Be 1
    }

    It 'REGRESSION: the solver never offers a service the person is unavailable for' {
        # The solver filters its pattern domains by the same mask. If the two ever disagreed
        # the search would quietly propose shifts nobody can work, and only this would catch it.
        $cfg = New-AvailabilityConfig -Available @{ Lundi = @('Lunch', 'Dinner'); Mardi = @('Lunch') } -Shifts 3
        $allowed = Get-RotaAllowedMask -Config $cfg -Person $cfg.staff[1] -Week 1
        ($allowed -band -bnot $cfg.staff[1].AvailableMask) | Should -Be 0

        $patterns = Get-RotaWeekPatterns -Config $cfg -Person $cfg.staff[1] -Week 1 -MinShifts 0 -MaxShifts 3
        foreach ($count in $patterns.Keys) {
            foreach ($m in $patterns[$count]) { ($m -band -bnot $cfg.staff[1].AvailableMask) | Should -Be 0 }
        }
    }

    It 'rejects availability that names a day or slot that does not exist' {
        $cfg = New-AvailabilityConfig @{ Caturday = @('Lunch') }
        @(Test-RotaConfig -Config $cfg) -join ' ' | Should -BeLike "*unknown day 'Caturday'*"
        $cfg2 = New-AvailabilityConfig @{ Lundi = @('Brunch') }
        @(Test-RotaConfig -Config $cfg2) -join ' ' | Should -BeLike "*unknown slot 'Brunch'*"
    }

    It 'rejects availability that lists nothing workable' {
        $cfg = New-AvailabilityConfig @{}
        @(Test-RotaConfig -Config $cfg) -join ' ' | Should -BeLike '*can never be rostered*'
    }
}

Describe 'A week can weigh its own slot preference' {
    It 'costs a missed preference more when the week says it matters more' {
        $plain = New-TestRotaConfig -Lunch 'PREF' -Dinner 'ANY' -SolvedShifts 2
        $heavy = New-TestRotaConfig -Lunch 'PREF' -Dinner 'ANY' -SolvedShifts 2
        foreach ($w in '1', '2') {
            $heavy.staff[1].weeks.$w | Add-Member -NotePropertyName preferenceWeight -NotePropertyValue 120 -Force
        }
        $heavy = ConvertTo-RotaNormalisedConfig -Config $heavy

        $mask = New-RotaMaskFromDays -Config $plain -Days @{ Lundi = 'D'; Mardi = 'D' }
        $plainCost = (@(Test-RotaSlotPreference -Schedule (New-ScheduleWithSolved -Config $plain -Week1Mask $mask)) | Measure-Object Cost -Sum).Sum
        $heavyCost = (@(Test-RotaSlotPreference -Schedule (New-ScheduleWithSolved -Config $heavy -Week1Mask $mask)) | Measure-Object Cost -Sum).Sum
        $heavyCost | Should -BeGreaterThan $plainCost
        $heavyCost | Should -Be ($plainCost * 12)      # 120 against the default 10
    }
}

Describe 'The solver and the rules must agree about responsables' {
    # The search filters candidates by H2 before shortlisting, because once a responsable's
    # week can be released it can take the only manager off a service. That check has to
    # obey the same switch the constraint engine does, or the search would reject schedules
    # the rules allow and the two halves would disagree about what the rules are.

    It 'requires one per service when the rule is on' {
        $cfg = New-TestRotaConfig -Rules @{ requireResponsablePerService = $true }
        $masks = @{ 'Solved|1' = 0; 'Solved|2' = 0; 'Boss|1' = 0; 'Boss|2' = 0 }
        Test-RotaMasksResponsable -Config $cfg -Masks $masks | Should -BeFalse
    }

    It 'requires nothing when the rule is off' {
        $cfg = New-TestRotaConfig -Rules @{ requireResponsablePerService = $false }
        $masks = @{ 'Solved|1' = 0; 'Solved|2' = 0; 'Boss|1' = 0; 'Boss|2' = 0 }
        Test-RotaMasksResponsable -Config $cfg -Masks $masks | Should -BeTrue
    }

    It 'agrees with the constraint engine either way' {
        foreach ($on in $true, $false) {
            $cfg = New-TestRotaConfig -Rules @{ requireResponsablePerService = $on }
            $schedule = New-RotaSchedule -Config $cfg          # nobody placed at all
            $masks = @{}
            foreach ($p in $cfg.staff) { for ($w = 1; $w -le 2; $w++) { $masks["$($p.name)|$w"] = 0 } }
            $engineHappy = @(Test-RotaResponsable -Schedule $schedule).Count -eq 0
            $searchHappy = Test-RotaMasksResponsable -Config $cfg -Masks $masks
            $searchHappy | Should -Be $engineHappy -Because "rule on = $on"
        }
    }
}

Describe 'officeLunch.count' {
    It 'accepts the one value that is actually supported' {
        $cfg = New-TestRotaConfig
        $cfg.staff[0] | Add-Member -NotePropertyName officeLunch -NotePropertyValue ([pscustomobject]@{
                count = 1; slot = 'Lunch'; candidateDays = @('Mercredi')
            }) -Force
        $cfg = ConvertTo-RotaNormalisedConfig -Config $cfg
        @(Test-RotaConfig -Config $cfg) -join ' ' | Should -Not -BeLike '*officeLunch.count*'
    }

    It 'rejects a count it would silently ignore' {
        # It used to accept 2 and quietly give one, which is the worst of both.
        $cfg = New-TestRotaConfig
        $cfg.staff[0] | Add-Member -NotePropertyName officeLunch -NotePropertyValue ([pscustomobject]@{
                count = 2; slot = 'Lunch'; candidateDays = @('Mercredi', 'Jeudi')
            }) -Force
        $cfg = ConvertTo-RotaNormalisedConfig -Config $cfg
        @(Test-RotaConfig -Config $cfg) -join ' ' | Should -BeLike '*only one admin lunch per week is supported*'
    }
}

Describe 'The registry says what the engine actually reports' {
    # H9 and H11 were raised by the engine, printed in reports, and named in no registry
    # entry, because one evaluator can report several different faults and the registry
    # listed only one id each. A reader auditing the rules would have missed two of them.
    # These tests hold the registry to the ids that exist in the source.

    BeforeAll {
        $script:Constraints = Get-RotaConstraints
        $script:Declared = @($script:Constraints | ForEach-Object Emits | Sort-Object -Unique)

        # Every id the source can raise: the literals, plus the two that are chosen at
        # runtime and so cannot be found by looking for -Id '...'.
        $source = Get-Content (Join-Path (Get-RotaRepoRoot) 'src\Constraints.ps1') -Raw
        $literals = @([regex]::Matches($source, "-Id\s+'([A-Za-z0-9-]+)'") | ForEach-Object { $_.Groups[1].Value })
        $computed = @([regex]::Matches($source, "'((?:H|S)\d+-[A-Za-z]+)'") | ForEach-Object { $_.Groups[1].Value })
        $script:Raised = @($literals + $computed | Sort-Object -Unique)
        $script:Source = $source
    }

    It 'declares every id the source can raise' {
        foreach ($id in $script:Raised) {
            # S5 interpolates its suffix, so match on the stem.
            $covered = $script:Declared | Where-Object { $_ -eq $id -or $_ -like "$id-*" }
            @($covered) | Should -Not -BeNullOrEmpty -Because "$id is raised somewhere but no registry entry declares it"
        }
    }

    It 'declares nothing the source cannot raise' {
        foreach ($id in $script:Declared) {
            # Match on the stem against the file text, because an id whose suffix is
            # interpolated -- "S5-Fairness-$name" -- never appears in full as a literal.
            $stem = ($id -split '-')[0..1] -join '-'
            $script:Source | Should -Match ([regex]::Escape($stem)) -Because "$id is declared but nothing in the source raises it"
        }
    }

    It 'names H9 and H11 specifically' {
        # The two that went missing. Named outright so the omission cannot recur quietly.
        $script:Declared | Should -Contain 'H9-DaysOffFloor'
        $script:Declared | Should -Contain 'H11-ShiftFloor'
    }

    It 'gives every evaluator a name and something to report' {
        foreach ($c in $script:Constraints) {
            $c.Name | Should -Not -BeNullOrEmpty
            @($c.Emits).Count | Should -BeGreaterThan 0 -Because "$($c.Name) must say what it reports"
            $c.Test | Should -Not -BeNullOrEmpty
        }
    }

    It 'has no duplicate ids across evaluators' {
        $all = @($script:Constraints | ForEach-Object Emits)
        @($all).Count | Should -Be (@($all | Sort-Object -Unique)).Count
    }
}
