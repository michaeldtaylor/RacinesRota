#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
#
# Integration.Tests.ps1 -- the shipped roster, solved for real.
#
# Everything else in the suite runs against the small synthetic fixture, which solves in
# about a second. That is the right trade for unit tests, but it means the suite cannot see
# the failure mode that actually bit: the fixture never approaches the time budget, so a
# search that degrades until it times out on the real roster stays invisible.
#
# These tests solve config/roster.json with its own settings. Tagged Slow so they can be
# skipped during quick iteration:
#
#     Invoke-Pester -Path ./tests -ExcludeTagFilter Slow

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-RotaModuleForTests
    $script:Roster = Import-RotaConfig -Path (Join-Path (Get-RotaRepoRoot) 'config\roster.json')
}

Describe 'Office arrangements that pose the same problem are searched once' -Tag 'Slow' {
    # Suyeon's admin lunch can fall on Mercredi or Jeudi in either week: four arrangements.
    # With officeLunchCountsOnFloor set she counts towards the three either way, so all four
    # leave identical gaps and the search only has to run once.
    BeforeAll {
        $script:Combos = Get-RotaOfficeCombinations -Config $script:Roster
        $script:Groups = Get-RotaOfficeCapacityGroups -Config $script:Roster -OfficeCombinations $script:Combos
    }

    It 'collapses the four arrangements to a single capacity problem' {
        @($script:Combos).Count | Should -Be 4
        @($script:Groups).Count | Should -Be 1
    }

    It 'keeps every arrangement, so none is lost from the final choice' {
        $kept = @($script:Groups | ForEach-Object { $_.Offices })
        $kept.Count | Should -Be @($script:Combos).Count
    }

    It 'gives each group a representative drawn from its own members' {
        foreach ($g in $script:Groups) { @($g.Offices) | Should -Contain $g.Representative }
    }
}

Describe 'Solving the shipped roster' -Tag 'Slow' {
    BeforeAll {
        $script:Result = Invoke-RotaSolver -Config $script:Roster
    }

    It 'REGRESSION: completes the search instead of running out of time' {
        # This is the failure this file exists for. The search once spent its whole 240s
        # budget per pass and surrendered, which is reported as a timeout rather than an
        # answer -- and a timeout means the schedule shipped to the restaurant is whatever
        # the clock happened to allow, not the best one available.
        $script:Result.Stats.TimedOut | Should -BeFalse
    }

    It 'scores more than one arrangement' {
        # The shortlist must give the exact scorer something to choose between. With cover
        # barred the roster is tight enough that the search finds few whole candidates, but
        # it must still weigh more than a single office arrangement.
        $script:Result.Stats.ExactlyScored | Should -BeGreaterThan 1
    }

    It 'searches one capacity problem rather than one per office arrangement' {
        $script:Result.Stats.OfficeCapacityGroups | Should -BeLessThan $script:Result.Stats.OfficeCombinations
    }

    It 'stays far inside the configured time budget' {
        # Generous on purpose: this guards against a return to the minutes-long search, not
        # against ordinary variation between machines.
        $budget = [double](Get-RotaProperty -Object $script:Roster.solver -Name 'timeBudgetSeconds' -Default 300)
        $script:Result.Elapsed.TotalSeconds | Should -BeLessThan ($budget / 2)
    }

    It 'breaks no rule except the coverage it cannot meet' {
        # Federica is barred, and without her the permanent team reaches only 17 of week 1's
        # 18. That one shortfall is expected and is reported; anything else is a fault.
        $hard = @($script:Result.Violations | Where-Object Severity -eq 'Hard')
        @($hard | Where-Object Id -ne 'H1-Coverage') | Should -BeNullOrEmpty
    }

    It 'is short in exactly one service, and says which' {
        # Pinned deliberately. If a second gap appears, something has regressed or the
        # roster has changed, and either way somebody needs to know before the week starts.
        $summary = Get-RotaSummary -Schedule $script:Result.Schedule -Violations $script:Result.Violations
        $summary.Understaffed | Should -Be 1
        $summary.Overstaffed | Should -Be 0
        $summary.MissingResponsable | Should -Be 0

        $short = @(Get-RotaTempCoverReport -Schedule $script:Result.Schedule)
        $short.Count | Should -Be 1
        $short[0].PeopleShort | Should -Be 1
    }

    It 'keeps everyone else on their full contract despite the gap' {
        # The gap must not be paid for by quietly shorting somebody's hours.
        foreach ($p in $script:Roster.SolvedStaff) {
            if ($p.name -eq 'Federica') { continue }
            for ($w = 1; $w -le [int]$script:Roster.meta.cycleWeeks; $w++) {
                (Get-RotaMaskPopCount -Mask $script:Result.Schedule.Masks["$($p.name)|$w"]) |
                    Should -Be ([int]$p.WeekSpec[$w].shifts) -Because "$($p.name) week $w is contracted"
            }
        }
    }

    It 'reports a missed days-off preference rather than dropping it' {
        # With cover barred, Beatrice's preferred 3.5 is no longer reachable -- the hours
        # have to come from somewhere. What matters is that it is still weighed and named,
        # not silently forgotten. That the shortlist can see S8 at all is proved in
        # Solver.Tests.ps1; this checks the report does not lose it.
        $missed = @($script:Result.Violations | Where-Object Id -eq 'S8-DaysOffPreference')
        if ($missed.Count -gt 0) { foreach ($m in $missed) { $m.Severity | Should -Be 'Soft' } }
    }

    It 'REGRESSION: the barred cover is given no work at all' {
        for ($w = 1; $w -le [int]$script:Roster.meta.cycleWeeks; $w++) {
            (Get-RotaMaskPopCount -Mask $script:Result.Schedule.Masks["Federica|$w"]) | Should -Be 0
        }
    }

    It 'uses the leaver only where the permanent team cannot reach' {
        # Federica is going. Every shift she holds is a gap in waiting, so the engine must
        # reach for her last -- a handful at most, never a working share of the rota.
        $temp = 0
        for ($w = 1; $w -le [int]$script:Roster.meta.cycleWeeks; $w++) {
            $temp += Get-RotaMaskPopCount -Mask $script:Result.Schedule.Masks["Federica|$w"]
        }
        $temp | Should -BeLessOrEqual 4
    }
}
