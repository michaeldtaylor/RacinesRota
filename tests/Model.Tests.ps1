#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
#
# Model.Tests.ps1 -- index arithmetic and the days-off measurement.
#
# The days-off tests carry most of the weight here. Two production bugs lived in that
# measurement, both of which produced schedules that looked compliant and were not, so each
# has a named regression test below.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-RotaModuleForTests
    $script:Config = New-TestRotaConfig
}

Describe 'Slot and service indexing' {
    It 'maps <Day>/<Slot> to slot index <Expected>' -TestCases @(
        @{ Day = 0; Slot = 'Lunch'; Expected = 0 }
        @{ Day = 0; Slot = 'Dinner'; Expected = 1 }
        @{ Day = 3; Slot = 'Lunch'; Expected = 6 }
        @{ Day = 6; Slot = 'Dinner'; Expected = 13 }
    ) {
        Get-RotaSlotIndex -DayIndex $Day -Slot $Slot | Should -Be $Expected
    }

    It 'round-trips every slot index back to its day and slot' {
        foreach ($i in 0..13) {
            $at = ConvertFrom-RotaSlotIndex -SlotIndex $i
            Get-RotaSlotIndex -DayIndex $at.DayIndex -Slot $at.Slot | Should -Be $i
        }
    }

    It 'offsets service indexes by a whole week' {
        Get-RotaServiceIndex -Week 1 -DayIndex 0 -Slot 'Lunch' | Should -Be 0
        Get-RotaServiceIndex -Week 2 -DayIndex 0 -Slot 'Lunch' | Should -Be 14
        Get-RotaServiceIndex -Week 2 -DayIndex 6 -Slot 'Dinner' | Should -Be 27
    }

    It 'produces one open service per day, slot and week' {
        $services = Get-RotaServices -Config $script:Config
        $services.Count | Should -Be 28
        @($services | Where-Object Open).Count | Should -Be 28
        @($services | Select-Object -ExpandProperty Key -Unique).Count | Should -Be 28
    }

    It 'marks closed services as closed and requiring nobody' {
        $cfg = New-TestRotaConfig
        $cfg.coverage.closed = @([pscustomobject]@{ day = 'Lundi'; slot = 'Lunch' })
        $services = Get-RotaServices -Config $cfg
        $closed = @($services | Where-Object { -not $_.Open })
        $closed.Count | Should -Be 2          # one per cycle week
        $closed[0].Required | Should -Be 0
    }
}

Describe 'Mask helpers' {
    It 'counts set bits' {
        Get-RotaMaskPopCount -Mask 0 | Should -Be 0
        Get-RotaMaskPopCount -Mask 0b11111111111111 | Should -Be 14
        Get-RotaMaskPopCount -Mask 0b101 | Should -Be 2
    }

    It 'agrees with the kernel population count across the whole mask space' {
        foreach ($m in 0, 1, 42, 8191, 16383) {
            Get-RotaPopCount -Value $m | Should -Be (Get-RotaMaskPopCount -Mask $m)
        }
    }

    It 'reports day load as 0, 1 or 2' {
        $mask = New-RotaMaskFromDays -Config $script:Config -Days @{ Lundi = 'L'; Mardi = 'LD' }
        Get-RotaDayLoad -Mask $mask -DayIndex 0 | Should -Be 1
        Get-RotaDayLoad -Mask $mask -DayIndex 1 | Should -Be 2
        Get-RotaDayLoad -Mask $mask -DayIndex 2 | Should -Be 0
    }
}

Describe 'Days off measurement' {

    It 'finds a plain two-day run inside one week' {
        # Works every day except Samedi and Dimanche.
        $mask = New-RotaMaskFromDays -Config $script:Config -Days @{
            Lundi = 'LD'; Mardi = 'LD'; Mercredi = 'LD'; Jeudi = 'LD'; Vendredi = 'LD'
        }
        $runs = Get-RotaDaysOffRunByWeek -DayLoads (Get-RotaDayLoadsFromMasks -WeekMasks @($mask, $mask)) -DaysPerWeek 7
        $runs.Count | Should -Be 2
        foreach ($r in $runs) { $r.FullDays | Should -Be 2 }
    }

    It 'lets a run straddle the week boundary and credits both weeks' {
        # Off Dimanche of week 1 and Lundi of week 2 only.
        $w1 = New-RotaMaskFromDays -Config $script:Config -Days @{
            Lundi = 'LD'; Mardi = 'LD'; Mercredi = 'LD'; Jeudi = 'LD'; Vendredi = 'LD'; Samedi = 'LD'
        }
        $w2 = New-RotaMaskFromDays -Config $script:Config -Days @{
            Mardi = 'LD'; Mercredi = 'LD'; Jeudi = 'LD'; Vendredi = 'LD'; Samedi = 'LD'; Dimanche = 'LD'
        }
        $runs = Get-RotaDaysOffRunByWeek -DayLoads (Get-RotaDayLoadsFromMasks -WeekMasks @($w1, $w2)) -DaysPerWeek 7
        $runs[0].FullDays | Should -Be 2
        $runs[1].FullDays | Should -Be 2
    }

    It 'REGRESSION: a half day never substitutes for a whole day off' {
        # Lunch Lundi, Mardi completely off, lunch Mercredi. That is ONE day off with a
        # part-worked day either side. It once scored 0.5 + 1 + 0.5 = 2.0 and wrongly
        # satisfied "two days off in a row".
        $mask = New-RotaMaskFromDays -Config $script:Config -Days @{
            Lundi = 'L'; Mercredi = 'L'; Jeudi = 'LD'; Vendredi = 'LD'; Samedi = 'LD'; Dimanche = 'LD'
        }
        $runs = Get-RotaDaysOffRunByWeek -DayLoads (Get-RotaDayLoadsFromMasks -WeekMasks @($mask, $mask)) -DaysPerWeek 7
        $runs[0].FullDays | Should -Be 1
        $runs[0].Value | Should -Be 1.5
        Test-RotaDaysOffRequirement -Run $runs[0] -Required 2 | Should -BeFalse
    }

    It 'accepts a half day only as the fraction of the requirement' {
        # Three full days off with a lunch-only day alongside: 3 whole days, counts as 3.5.
        $mask = New-RotaMaskFromDays -Config $script:Config -Days @{
            Lundi = 'LD'; Mardi = 'LD'; Mercredi = 'L'
        }
        $runs = Get-RotaDaysOffRunByWeek -DayLoads (Get-RotaDayLoadsFromMasks -WeekMasks @($mask, $mask)) -DaysPerWeek 7
        $runs[0].FullDays | Should -Be 4        # Jeudi..Dimanche
        Test-RotaDaysOffRequirement -Run $runs[0] -Required 3.5 | Should -BeTrue
    }

    It 'requires the whole-number part to be met by whole days' -TestCases @(
        @{ Full = 3; Value = 3.5; Required = 3.5; Expected = $true }
        @{ Full = 3; Value = 3.0; Required = 3.5; Expected = $false }
        @{ Full = 2; Value = 2.5; Required = 3.0; Expected = $false }
        @{ Full = 2; Value = 2.0; Required = 2.0; Expected = $true }
        @{ Full = 1; Value = 2.0; Required = 2.0; Expected = $false }   # the regression above
    ) {
        $run = [pscustomobject]@{ Week = 1; FullDays = $Full; Value = $Value }
        Test-RotaDaysOffRequirement -Run $run -Required $Required | Should -Be $Expected
    }

    It 'REGRESSION: assigns runs to the correct week (integer division must floor)' {
        # [int](i/7) rounds in PowerShell, so day 4 landed in week 1 and day 13 overran the
        # array. Days off only in week 2 must leave week 1 with nothing.
        $w1 = New-RotaMaskFromDays -Config $script:Config -Days @{
            Lundi = 'LD'; Mardi = 'LD'; Mercredi = 'LD'; Jeudi = 'LD'
            Vendredi = 'LD'; Samedi = 'LD'; Dimanche = 'LD'
        }
        $w2 = New-RotaMaskFromDays -Config $script:Config -Days @{ Lundi = 'LD'; Mardi = 'LD' }
        $runs = Get-RotaDaysOffRunByWeek -DayLoads (Get-RotaDayLoadsFromMasks -WeekMasks @($w1, $w2)) -DaysPerWeek 7
        $runs.Count | Should -Be 2
        $runs[1].FullDays | Should -Be 5        # Mercredi..Dimanche of week 2
        $runs[0].FullDays | Should -Be 0        # week 1 is fully worked
    }

    It 'treats someone who never works as entirely free' {
        $runs = Get-RotaDaysOffRunByWeek -DayLoads (Get-RotaDayLoadsFromMasks -WeekMasks @(0, 0)) -DaysPerWeek 7
        foreach ($r in $runs) { $r.FullDays | Should -Be 14 }
    }

    It 'gives no days off to someone who works every single service' {
        $all = 0b11111111111111
        $runs = Get-RotaDaysOffRunByWeek -DayLoads (Get-RotaDayLoadsFromMasks -WeekMasks @($all, $all)) -DaysPerWeek 7
        foreach ($r in $runs) {
            $r.FullDays | Should -Be 0
            Test-RotaDaysOffRequirement -Run $r -Required 2 | Should -BeFalse
        }
    }
}

Describe 'Coverage counting' {
    It 'counts an office lunch towards the requirement by default' {
        $cfg = New-TestRotaConfig
        $cfg.staff[0] | Add-Member -NotePropertyName officeLunch -NotePropertyValue ([pscustomobject]@{
                count = 1; slot = 'Lunch'; candidateDays = @('Mercredi')
            }) -Force
        $schedule = New-RotaSchedule -Config (ConvertTo-RotaNormalisedConfig -Config $cfg)
        Add-RotaFixedStaff -Schedule $schedule | Out-Null

        $service = $schedule.Services | Where-Object { $_.Week -eq 1 -and $_.Day -eq 'Mercredi' -and $_.Slot -eq 'Lunch' }
        (Get-RotaCoverage -Schedule $schedule -Service $service) | Should -Contain 'Boss'
    }

    It 'excludes the office lunch when officeLunchCountsOnFloor is false' {
        $cfg = New-TestRotaConfig -Rules @{ officeLunchCountsOnFloor = $false }
        $cfg.staff[0] | Add-Member -NotePropertyName officeLunch -NotePropertyValue ([pscustomobject]@{
                count = 1; slot = 'Lunch'; candidateDays = @('Mercredi')
            }) -Force
        $schedule = New-RotaSchedule -Config (ConvertTo-RotaNormalisedConfig -Config $cfg)
        Add-RotaFixedStaff -Schedule $schedule | Out-Null

        $service = $schedule.Services | Where-Object { $_.Week -eq 1 -and $_.Day -eq 'Mercredi' -and $_.Slot -eq 'Lunch' }
        (Get-RotaCoverage -Schedule $schedule -Service $service) | Should -Not -Contain 'Boss'
    }
}

Describe 'Schedule mutation' {
    It 'keeps assignments and masks in step' {
        $schedule = New-TestSchedule -Config $script:Config
        $mask = New-RotaMaskFromDays -Config $script:Config -Days @{ Mardi = 'LD' }
        Set-RotaWeekMask -Schedule $schedule -Person 'Solved' -Week 1 -Mask $mask

        Get-RotaWeekMask -Schedule $schedule -Person 'Solved' -Week 1 | Should -Be $mask
        $service = $schedule.Services | Where-Object { $_.Week -eq 1 -and $_.Day -eq 'Mardi' -and $_.Slot -eq 'Dinner' }
        $schedule.Assignments[$service.Index] | Should -Contain 'Solved'
    }

    It 'removes assignments when a mask is replaced' {
        $schedule = New-TestSchedule -Config $script:Config
        $first = New-RotaMaskFromDays -Config $script:Config -Days @{ Mardi = 'LD' }
        Set-RotaWeekMask -Schedule $schedule -Person 'Solved' -Week 1 -Mask $first
        Set-RotaWeekMask -Schedule $schedule -Person 'Solved' -Week 1 -Mask 0

        $service = $schedule.Services | Where-Object { $_.Week -eq 1 -and $_.Day -eq 'Mardi' -and $_.Slot -eq 'Dinner' }
        $schedule.Assignments[$service.Index] | Should -Not -Contain 'Solved'
        Get-RotaWeekMask -Schedule $schedule -Person 'Solved' -Week 1 | Should -Be 0
    }
}

Describe 'Per-service coverage overrides' {
    # A single requiredPerService cannot say that Saturday dinner is busier than Tuesday
    # lunch. An override names the service and applies in every week, because how busy a
    # service is belongs to the day of the week, not to which half of the fortnight it is.

    BeforeAll {
        $script:OverrideConfig = {
            param($Overrides)
            $cfg = New-TestRotaConfig -RequiredPerService 2
            $cfg.coverage | Add-Member overrides $Overrides -Force
            ConvertTo-RotaNormalisedConfig -Config $cfg
        }
    }

    It 'raises the named service and leaves the rest on the house default' {
        $cfg = & $script:OverrideConfig @([pscustomobject]@{ day = 'Samedi'; slot = 'Dinner'; required = 5 })
        $services = Get-RotaServices -Config $cfg
        foreach ($s in $services) {
            $expected = if ($s.Day -eq 'Samedi' -and $s.Slot -eq 'Dinner') { 5 } else { 2 }
            $s.Required | Should -Be $expected
        }
    }

    It 'applies in every week of the cycle' {
        $cfg = & $script:OverrideConfig @([pscustomobject]@{ day = 'Samedi'; slot = 'Dinner'; required = 5 })
        $services = Get-RotaServices -Config $cfg   # assign first: the helper comma-wraps
        $hit = @($services | Where-Object { $_.Required -eq 5 })
        $hit.Count | Should -Be ([int]$cfg.meta.cycleWeeks)
        @($hit | ForEach-Object Week | Sort-Object) | Should -Be @(1, 2)
    }

    It 'can lower a service as well as raise it' {
        $cfg = & $script:OverrideConfig @([pscustomobject]@{ day = 'Mardi'; slot = 'Lunch'; required = 1 })
        $services = Get-RotaServices -Config $cfg   # assign first: the helper comma-wraps
        $s = @($services | Where-Object { $_.Day -eq 'Mardi' -and $_.Slot -eq 'Lunch' })[0]
        $s.Required | Should -Be 1
    }

    It 'leaves a closed service closed, whatever an override asks for' {
        $cfg = New-TestRotaConfig -RequiredPerService 2
        $cfg.coverage.closed = @([pscustomobject]@{ day = 'Lundi'; slot = 'Lunch' })
        $cfg.coverage | Add-Member overrides @([pscustomobject]@{ day = 'Lundi'; slot = 'Lunch'; required = 4 }) -Force
        $cfg = ConvertTo-RotaNormalisedConfig -Config $cfg
        $services = Get-RotaServices -Config $cfg   # assign first: the helper comma-wraps
        $s = @($services | Where-Object { $_.Day -eq 'Lundi' -and $_.Slot -eq 'Lunch' })[0]
        $s.Open | Should -BeFalse
        $s.Required | Should -Be 0
        # ...and the contradiction is reported rather than silently resolved.
        @(Test-RotaConfig -Config $cfg) -join ' ' | Should -BeLike '*also listed as closed*'
    }

    It 'behaves exactly as before when no overrides are given' {
        $cfg = New-TestRotaConfig -RequiredPerService 2
        $services = Get-RotaServices -Config $cfg
        foreach ($s in $services) { $s.Required | Should -Be 2 }
    }

    It 'rejects an override that names a service that does not exist' -TestCases @(
        @{ Day = 'Caturday'; Slot = 'Dinner'; Required = 4; Like = "*unknown day 'Caturday'*" }
        @{ Day = 'Samedi'; Slot = 'Brunch'; Required = 4; Like = "*unknown slot 'Brunch'*" }
        @{ Day = 'Samedi'; Slot = 'Dinner'; Required = 0; Like = '*at least 1*' }
    ) {
        $cfg = & $script:OverrideConfig @([pscustomobject]@{ day = $Day; slot = $Slot; required = $Required })
        @(Test-RotaConfig -Config $cfg) -join ' ' | Should -BeLike $Like
    }

    It 'rejects the same service listed twice, since the two disagree' {
        $cfg = & $script:OverrideConfig @(
            [pscustomobject]@{ day = 'Samedi'; slot = 'Dinner'; required = 4 }
            [pscustomobject]@{ day = 'Samedi'; slot = 'Dinner'; required = 5 }
        )
        @(Test-RotaConfig -Config $cfg) -join ' ' | Should -BeLike '*listed more than once*'
    }
}

Describe 'A fixed pattern that differs between weeks' {
    # fixed repeats into every week, which is right for a standing rota and wrong the moment
    # somebody covers one extra shift in one week only. fixedByWeek replaces the pattern for
    # the weeks it names -- replaces, not merges, so there is no question about what a named
    # day means.

    BeforeAll {
        function New-PerWeekConfig {
            param($ByWeek)
            $cfg = New-TestRotaConfig
            $cfg.staff[0] | Add-Member -NotePropertyName fixedByWeek -NotePropertyValue ([pscustomobject]$ByWeek) -Force
            ConvertTo-RotaNormalisedConfig -Config $cfg
        }
    }

    It 'uses the default pattern for weeks that are not named' {
        $cfg = New-PerWeekConfig @{ '2' = [pscustomobject]@{ Lundi = @('Lunch') } }
        $cfg.staff[0].FixedMaskForWeek[1] | Should -Be $cfg.staff[0].FixedMask
    }

    It 'replaces the pattern for a week that is named' {
        $cfg = New-PerWeekConfig @{ '2' = [pscustomobject]@{ Lundi = @('Lunch') } }
        $expected = New-RotaMaskFromDays -Config $cfg -Days @{ Lundi = 'L' }
        $cfg.staff[0].FixedMaskForWeek[2] | Should -Be $expected
        $cfg.staff[0].FixedMaskForWeek[2] | Should -Not -Be $cfg.staff[0].FixedMask
    }

    It 'places each week from its own pattern' {
        $cfg = New-PerWeekConfig @{ '2' = [pscustomobject]@{ Lundi = @('Lunch') } }
        $schedule = New-RotaSchedule -Config $cfg
        Add-RotaFixedStaff -Schedule $schedule | Out-Null
        $schedule.Masks['Boss|1'] | Should -Be $cfg.staff[0].FixedMask
        $schedule.Masks['Boss|2'] | Should -Be $cfg.staff[0].FixedMaskForWeek[2]
    }

    It 'holds the fixed rows to the right week, not the default' {
        # H3 must compare each week against that week's pattern. Comparing both against the
        # default would call a correct week-2 rota a modification of the fixed rows.
        $cfg = New-PerWeekConfig @{ '2' = [pscustomobject]@{ Lundi = @('Lunch') } }
        $schedule = New-RotaSchedule -Config $cfg
        Add-RotaFixedStaff -Schedule $schedule | Out-Null
        @(Test-RotaFixedAssignments -Schedule $schedule) | Should -BeNullOrEmpty
    }

    It 'rejects an override naming a week the rota does not have' {
        $cfg = New-PerWeekConfig @{ '5' = [pscustomobject]@{ Lundi = @('Lunch') } }
        @(Test-RotaConfig -Config $cfg) -join ' ' | Should -BeLike '*names week 5*'
    }

    It 'rejects an override on a solved person, where it means nothing' {
        $cfg = New-TestRotaConfig
        $cfg.staff[1] | Add-Member -NotePropertyName fixedByWeek -NotePropertyValue ([pscustomobject]@{ '2' = [pscustomobject]@{ Lundi = @('Lunch') } }) -Force
        $cfg = ConvertTo-RotaNormalisedConfig -Config $cfg
        @(Test-RotaConfig -Config $cfg) -join ' ' | Should -BeLike '*only means something for a fixed person*'
    }

    It 'leaves a roster without overrides exactly as it was' {
        $cfg = New-TestRotaConfig
        for ($w = 1; $w -le [int]$cfg.meta.cycleWeeks; $w++) {
            $cfg.staff[0].FixedMaskForWeek[$w] | Should -Be $cfg.staff[0].FixedMask
        }
    }
}
