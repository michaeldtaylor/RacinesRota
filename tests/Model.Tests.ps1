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
