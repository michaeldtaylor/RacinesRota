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
            $schedule.Masks["$($p.name)|1"] | Should -Be $schedule.Masks["$($p.name)|2"]
        }
    }

    It 'leaves 18 services per week for the solved staff to fill' {
        # Fixed staff cover 24 of the 42 person-shifts a week needs. This number drives every
        # coverage conclusion in the reports, so it is pinned here.
        $schedule = New-RotaSchedule -Config $script:Roster
        Add-RotaFixedStaff -Schedule $schedule | Out-Null
        $gaps = Get-RotaWeekGaps -Schedule $schedule -Week 1
        ($gaps | Measure-Object -Sum).Sum | Should -Be 18
    }

    It 'puts Barbara on a two-week cycle and the other contracted staff on one' {
        # Cover staff are deliberately two-week as well, so their weeks stay independent and
        # they can be called on in one week without committing them to the other.
        foreach ($p in $script:Roster.SolvedStaff) {
            if (Get-RotaProperty -Object $p -Name 'temporary' -Default $false) { continue }
            $cycle = Get-RotaProperty -Object $p -Name 'cycleWeeks' -Default 2
            if ($p.name -eq 'Barbara') { $cycle | Should -Be 2 } else { $cycle | Should -Be 1 }
        }
    }

    It 'marks Federica as temporary and nobody else' {
        $temps = @($script:Roster.staff | Where-Object { Get-RotaProperty -Object $_ -Name 'temporary' -Default $false } | ForEach-Object name)
        $temps | Should -Be @('Federica')
    }

    It 'gives Federica a zero target so she is only ever cover' {
        $fed = $script:Roster.StaffByName['Federica']
        foreach ($w in 1, 2) {
            $fed.WeekSpec[$w].shifts | Should -Be 0
            (Get-RotaProperty -Object $fed.WeekSpec[$w] -Name 'maxShifts') | Should -BeGreaterThan 0
        }
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

    It 'reports every problem at once rather than stopping at the first' {
        $cfg = New-TestRotaConfig -Lunch 'MAYBE' -Dinner 'PERHAPS'
        @(Test-RotaConfig -Config $cfg).Count | Should -BeGreaterThan 1
    }

    It 'throws on a missing file' {
        { Import-RotaConfig -Path 'D:\nope\missing.json' } | Should -Throw '*not found*'
    }
}
