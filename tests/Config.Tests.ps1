#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
#
# Config.Tests.ps1 -- loading, validating and normalising the roster.
#
# The shipped roster.json is asserted against the figures taken off the original spreadsheet.
# If someone edits it into a different shape, these tests say so before the solver quietly
# produces a plausible-looking rota for the wrong restaurant.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-RotaModuleForTests
    $script:RosterPath = Join-Path (Get-RotaRepoRoot) 'config\roster.json'
    $script:Roster = Import-RotaConfig -Path $script:RosterPath
}

Describe 'The shipped roster' {
    It 'loads and validates' {
        Test-RotaConfig -Config $script:Roster | Should -BeNullOrEmpty
    }

    It 'has the expected people in the expected roles' {
        @($script:Roster.staff | ForEach-Object name) | Should -Contain 'Suyeon'
        $script:Roster.Responsables | Should -Be @('Suyeon', 'Giulia', 'Lucas')
        @($script:Roster.FixedStaff | ForEach-Object name).Count | Should -Be 4
    }

    It 'gives the fixed staff the shift counts taken off the original sheet' -TestCases @(
        @{ Person = 'Suyeon'; Shifts = 7 }
        @{ Person = 'Giulia'; Shifts = 7 }
        @{ Person = 'Lucas'; Shifts = 7 }
        @{ Person = 'Clementine'; Shifts = 3 }
    ) {
        $schedule = New-RotaSchedule -Config $script:Roster
        Add-RotaFixedStaff -Schedule $schedule | Out-Null
        Get-RotaMaskPopCount -Mask $schedule.Masks["$Person|1"] | Should -Be $Shifts
    }

    It 'repeats the fixed pattern into every cycle week' {
        $schedule = New-RotaSchedule -Config $script:Roster
        Add-RotaFixedStaff -Schedule $schedule | Out-Null
        foreach ($p in $script:Roster.FixedStaff) {
            for ($w = 1; $w -le [int]$script:Roster.meta.cycleWeeks; $w++) {
                if ($p.FlexibleWeeks.ContainsKey($w)) {
                    # A released week is the search's to fill, so pre-placement leaves it
                    # empty on purpose -- that is what gives the solver something to reduce.
                    $schedule.Masks["$($p.name)|$w"] | Should -Be 0 -Because "$($p.name) week $w is released"
                }
                else {
                    $schedule.Masks["$($p.name)|$w"] | Should -Be $p.FixedMask -Because "$($p.name) week $w is fixed"
                }
            }
        }
    }

    It 'releases only the weeks that were nominated' {
        $script:Roster.StaffByName['Suyeon'].FlexibleWeeks.Keys | Should -Be @(2)
        $script:Roster.StaffByName['Giulia'].FlexibleWeeks.Keys | Should -Be @(2)
        $script:Roster.StaffByName['Lucas'].FlexibleWeeks.Count | Should -Be 0
        $script:Roster.StaffByName['Clementine'].FlexibleWeeks.Count | Should -Be 0
    }

    It 'leaves 18 services per week for the solved staff to fill' {
        # Fixed staff cover 24 of the 42 person-shifts a week needs. This number drives every
        # coverage conclusion in the reports, so it is pinned here.
        $schedule = New-RotaSchedule -Config $script:Roster
        Add-RotaFixedStaff -Schedule $schedule | Out-Null
        $gaps = Get-RotaWeekGaps -Schedule $schedule -Week 1
        ($gaps | Measure-Object -Sum).Sum | Should -Be 18
    }

    It 'puts Barbara and Veronica on a fortnightly cycle, Beatrice on a weekly one' {
        # Barbara's two weeks are different jobs. Veronica's differ too, since week 2 -- the
        # week Barbara covers dinners -- leans hard towards lunches for her. Beatrice works
        # the same week every week. Cover is excluded: it is neither, see below.
        $expected = @{ Barbara = 'cycle'; Veronica = 'cycle'; Beatrice = 'weekly' }
        foreach ($p in $script:Roster.SolvedStaff) {
            if (Get-RotaProperty -Object $p -Name 'temporary' -Default $false) { continue }
            $p.RepeatMode | Should -Be $expected[$p.name]
            if ($expected[$p.name] -eq 'cycle') { Get-RotaProperty -Object $p -Name 'cycleWeeks' | Should -Be 2 }
        }
    }

    It 'marks Federica as temporary and nobody else' {
        $temps = @($script:Roster.staff | Where-Object { Get-RotaProperty -Object $_ -Name 'temporary' -Default $false } | ForEach-Object name)
        $temps | Should -Be @('Federica')
    }

    It 'bars Federica outright: she is not to be used at present' {
        # She is kept on the roster as a record, but with a ceiling of zero the engine cannot
        # roster her at all. Raising maxShifts back above zero makes her gap cover again.
        $fed = $script:Roster.StaffByName['Federica']
        foreach ($w in 1, 2) {
            $fed.WeekSpec[$w].shifts | Should -Be 0
            (Get-RotaProperty -Object $fed.WeekSpec[$w] -Name 'maxShifts') | Should -Be 0
        }
    }

    It 'REGRESSION: a barred person is given no shifts at all' {
        # The point of barring her. If the solver ever hands her work again, the rota is
        # relying on somebody the restaurant has said it will not use.
        $result = Invoke-RotaSolver -Config $script:Roster -ShortlistSize 200 -WarningAction SilentlyContinue
        for ($w = 1; $w -le [int]$script:Roster.meta.cycleWeeks; $w++) {
            (Get-RotaMaskPopCount -Mask $result.Schedule.Masks["Federica|$w"]) |
                Should -Be 0 -Because "Federica is barred in week $w"
        }
    }
}

Describe 'How a person''s weeks relate to each other' {
    # One number used to answer two unrelated questions -- "does my rota repeat every week?"
    # and "may my weeks be placed independently?" -- and two people carried the same value
    # for opposite reasons. The repeat field says which is meant.

    It 'reads the three modes off the shipped roster' -TestCases @(
        @{ Name = 'Veronica'; Mode = 'cycle' }
        @{ Name = 'Beatrice'; Mode = 'weekly' }
        @{ Name = 'Barbara'; Mode = 'cycle' }
        @{ Name = 'Federica'; Mode = 'none' }
    ) {
        $script:Roster.StaffByName[$Name].RepeatMode | Should -Be $Mode
    }

    It 'collapses to one decision only for a weekly person' {
        $script:Roster.StaffByName['Beatrice'].RepeatsWeekly | Should -BeTrue
        $script:Roster.StaffByName['Veronica'].RepeatsWeekly | Should -BeFalse
        $script:Roster.StaffByName['Barbara'].RepeatsWeekly | Should -BeFalse
        $script:Roster.StaffByName['Federica'].RepeatsWeekly | Should -BeFalse
    }

    It 'still understands a config written before the field existed' {
        # Old rosters carried cycleWeeks alone. They must keep loading, and keep behaving.
        $legacy = [pscustomobject]@{ name = 'Old'; mode = 'solved'; cycleWeeks = 1 }
        Get-RotaRepeatMode -Config $script:Roster -Person $legacy | Should -Be 'weekly'
        $legacy = [pscustomobject]@{ name = 'Old'; mode = 'solved'; cycleWeeks = 2 }
        Get-RotaRepeatMode -Config $script:Roster -Person $legacy | Should -Be 'cycle'
    }

    It 'REGRESSION: cover must not be forced to repeat its weeks' {
        # Federica is cover. The shortfall is in week 1 only, so a weekly rota cannot take it
        # without also working week 2, where there is no room -- and week 1 goes understaffed.
        # This is why she is 'none' and not 'weekly'; it is not a stylistic choice.
        $script:Roster.StaffByName['Federica'].RepeatsWeekly | Should -BeFalse
    }
}

Describe 'Week spec normalisation' {
    It 'repeats week 1 for a person on a one-week cycle' {
        $cfg = New-TestRotaConfig -PersonCycleWeeks 1
        $person = $cfg.StaffByName['Solved']
        $person.WeekSpec[1].shifts | Should -Be $person.WeekSpec[2].shifts
    }

    It 'keeps the weeks distinct for a person on a two-week cycle' {
        $cfg = New-TestRotaConfig -PersonCycleWeeks 2
        $cfg.staff[1].weeks.'2'.shifts = 6
        $cfg = ConvertTo-RotaNormalisedConfig -Config $cfg
        $cfg.StaffByName['Solved'].WeekSpec[1].shifts | Should -Be 4
        $cfg.StaffByName['Solved'].WeekSpec[2].shifts | Should -Be 6
    }
}

Describe 'Validation' {
    It 'accepts the test fixture' {
        Test-RotaConfig -Config (New-TestRotaConfig) | Should -BeNullOrEmpty
    }

    It 'rejects a duplicate name' {
        $cfg = New-TestRotaConfig
        $cfg.staff[1].name = 'Boss'
        $cfg = ConvertTo-RotaNormalisedConfig -Config $cfg
        Test-RotaConfig -Config $cfg | Should -Match 'Duplicate'
    }

    It 'rejects an unknown mode' {
        $cfg = New-TestRotaConfig
        $cfg.staff[1].mode = 'sometimes'
        $cfg = ConvertTo-RotaNormalisedConfig -Config $cfg
        Test-RotaConfig -Config $cfg | Should -Match "mode must be"
    }

    It 'rejects an unknown slot eligibility word' {
        $cfg = New-TestRotaConfig -Lunch 'MAYBE'
        Test-RotaConfig -Config $cfg | Should -Match 'lunch must be one of'
    }

    It 'rejects more shifts than a week without doubles can hold' {
        $cfg = New-TestRotaConfig -Doubles $false -SolvedShifts 10
        Test-RotaConfig -Config $cfg | Should -Match 'impossible without doubles'
    }

    It 'rejects a ceiling below the target' {
        $cfg = New-TestRotaConfig -SolvedShifts 5
        foreach ($w in '1', '2') {
            $cfg.staff[1].weeks.$w | Add-Member -NotePropertyName maxShifts -NotePropertyValue 2 -Force
        }
        $cfg = ConvertTo-RotaNormalisedConfig -Config $cfg
        Test-RotaConfig -Config $cfg | Should -Match 'maxShifts'
    }

    It 'rejects both services being NO while shifts are expected' {
        $cfg = New-TestRotaConfig -Lunch 'NO' -Dinner 'NO' -SolvedShifts 3
        Test-RotaConfig -Config $cfg | Should -Match 'both lunch and dinner are NO'
    }

    It 'rejects an office lunch on a day the person does not work' {
        $cfg = New-TestRotaConfig
        $cfg.staff[0] | Add-Member -NotePropertyName officeLunch -NotePropertyValue ([pscustomobject]@{
                count = 1; slot = 'Lunch'; candidateDays = @('Nonesuch')
            }) -Force
        $cfg = ConvertTo-RotaNormalisedConfig -Config $cfg
        Test-RotaConfig -Config $cfg | Should -Match 'unknown day'
    }

    It 'rejects a repeat mode it does not recognise' {
        $cfg = New-TestRotaConfig
        $cfg.staff[1] | Add-Member repeat 'fortnightly' -Force
        $cfg = ConvertTo-RotaNormalisedConfig -Config $cfg
        Test-RotaConfig -Config $cfg | Should -Contain "Solved: repeat must be 'weekly', 'cycle' or 'none'; got 'fortnightly'."
    }

    It 'rejects a cycle whose weeks are all the same, and says what to use instead' {
        # Exactly the shape that caused the confusion: a cover worker written as a 2-week
        # cycle when nothing about the two weeks differs.
        $cfg = New-TestRotaConfig -PersonCycleWeeks 2
        $cfg.staff[1] | Add-Member repeat 'cycle' -Force
        $cfg = ConvertTo-RotaNormalisedConfig -Config $cfg
        @(Test-RotaConfig -Config $cfg) -join ' ' | Should -BeLike "*no cycle to repeat*"
    }

    It 'rejects a weekly person who also declares a multi-week cycle' {
        $cfg = New-TestRotaConfig -PersonCycleWeeks 2
        $cfg.staff[1] | Add-Member repeat 'weekly' -Force
        $cfg = ConvertTo-RotaNormalisedConfig -Config $cfg
        @(Test-RotaConfig -Config $cfg) -join ' ' | Should -BeLike "*repeat is 'weekly' but cycleWeeks is 2*"
    }

    It 'reports every problem at once rather than stopping at the first' {
        $cfg = New-TestRotaConfig -Lunch 'MAYBE' -Dinner 'PERHAPS'
        @(Test-RotaConfig -Config $cfg).Count | Should -BeGreaterThan 1
    }

    It 'throws on a missing file' {
        { Import-RotaConfig -Path 'D:\nope\missing.json' } | Should -Throw '*not found*'
    }
}
