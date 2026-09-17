# TestHelpers.ps1 -- fixtures shared by the test suite.
#
# The shipped roster is a slow, tightly-constrained problem: good for end-to-end assertions,
# far too slow to sit behind every unit test. Most tests therefore run against a small
# synthetic roster built here, which solves in a second or two while exercising the same
# code paths.

Set-StrictMode -Version Latest

function Get-RotaRepoRoot {
    Split-Path -Parent $PSScriptRoot
}

function Import-RotaModuleForTests {
    Import-Module (Join-Path (Get-RotaRepoRoot) 'src\RacinesRota.psd1') -Force
}

function New-TestRotaConfig {
    <#
    .SYNOPSIS
        A small, fast roster for unit tests.
    .DESCRIPTION
        Seven days (the engine requires a full week) but only one person needed per service,
        one fixed responsable, and one solved person. Parameters let individual tests bend
        exactly the rule they are about without rebuilding the whole fixture.
    #>
    [CmdletBinding()]
    param(
        [int]$CycleWeeks = 2,
        [int]$RequiredPerService = 1,
        [int]$SolvedShifts = 4,
        [double]$ConsecutiveDaysOff = 2,
        [bool]$Doubles = $true,
        [string]$Lunch = 'ANY',
        [string]$Dinner = 'ANY',
        [bool]$Weekend = $true,
        [int]$PersonCycleWeeks = 1,
        [hashtable]$Rules = @{}
    )

    # Named $ruleSet, not $rules: PowerShell variable names are case-insensitive, so $rules
    # and the $Rules parameter would be the same hashtable and the merge below would be
    # enumerating the collection it is modifying.
    $ruleSet = @{
        minConsecutiveDaysOffForEveryone = 2
        requireResponsablePerService     = $true
        enforcePersonCycleRepeat         = $true
        officeLunchCountsOnFloor         = $true
        daysOffScope                     = 'week'
    }
    foreach ($k in $Rules.Keys) { $ruleSet[$k] = $Rules[$k] }

    $json = @{
        meta        = @{ name = 'TestRoster'; cycleWeeks = $CycleWeeks }
        days        = @('Lundi', 'Mardi', 'Mercredi', 'Jeudi', 'Vendredi', 'Samedi', 'Dimanche')
        weekendDays = @('Samedi', 'Dimanche')
        slots       = @('Lunch', 'Dinner')
        startTimes  = @{ Lunch = '10H'; Dinner = '18H' }
        coverage    = @{ requiredPerService = $RequiredPerService; closed = @() }
        solver      = @{ underrunAllowance = 3; maxCostDrop = 2500; componentShortlist = 60
            maxComponentCombinations = 500; timeBudgetSeconds = 30; shiftCountTolerance = 0
        }
        weights     = @{ coverageShortfall = 1000; shiftUnderrun = 200; slotPreference = 10
            isolatedWorkDay = 5; weekendFairness = 3; dinnerFairness = 3
            adminLunchUnprotected = 25; temporaryShift = 300
        }
        staff       = @(
            @{
                name = 'Boss'; contract = 'RESP'; responsable = $true; mode = 'fixed'
                fixed = @{
                    Lundi = @('Lunch', 'Dinner'); Mardi = @('Lunch', 'Dinner')
                    Mercredi = @('Lunch', 'Dinner'); Jeudi = @('Lunch', 'Dinner')
                    Vendredi = @('Lunch', 'Dinner'); Samedi = @('Lunch', 'Dinner')
                    Dimanche = @('Lunch', 'Dinner')
                }
            },
            @{
                name = 'Solved'; contract = ''; responsable = $false; mode = 'solved'
                cycleWeeks = $PersonCycleWeeks; consecutiveDaysOff = $ConsecutiveDaysOff
                weeks = @{
                    '1' = @{ doubles = $Doubles; shifts = $SolvedShifts; weekend = $Weekend; lunch = $Lunch; dinner = $Dinner }
                    '2' = @{ doubles = $Doubles; shifts = $SolvedShifts; weekend = $Weekend; lunch = $Lunch; dinner = $Dinner }
                }
            }
        )
        rules       = $ruleSet
    }

    ConvertTo-RotaNormalisedConfig -Config ($json | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
}

function New-TestSchedule {
    <#
    .SYNOPSIS
        A schedule with the fixed staff placed, ready for a test to add solved staff to.
    #>
    [CmdletBinding()]
    param($Config)
    if (-not $Config) { $Config = New-TestRotaConfig }
    $schedule = New-RotaSchedule -Config $Config
    Add-RotaFixedStaff -Schedule $schedule | Out-Null
    $schedule
}

function New-RotaMaskFromDays {
    <#
    .SYNOPSIS
        Build a week mask from a readable description, e.g. @{ Lundi = 'L'; Mardi = 'LD' }.
    .DESCRIPTION
        Tests read far better asserting on "Lundi lunch, Mardi double" than on 0b0000001101.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][hashtable]$Days
    )
    $mask = 0
    foreach ($day in $Days.Keys) {
        $d = $Config.DayIndexOf[$day]
        if ($null -eq $d) { throw "Unknown day in test mask: $day" }
        foreach ($ch in $Days[$day].ToCharArray()) {
            $slot = switch ($ch) { 'L' { 'Lunch' } 'D' { 'Dinner' } default { throw "Use L or D, got '$ch'" } }
            $mask = $mask -bor (1 -shl (Get-RotaSlotIndex -DayIndex $d -Slot $slot))
        }
    }
    $mask
}

function Get-RotaDayLoadsFromMasks {
    <#
    .SYNOPSIS
        Day loads for a cycle from one mask per week, without needing a schedule.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int[]]$WeekMasks)
    $loads = foreach ($mask in $WeekMasks) {
        foreach ($d in 0..6) { Get-RotaDayLoad -Mask $mask -DayIndex $d }
    }
    , [int[]]@($loads)
}

