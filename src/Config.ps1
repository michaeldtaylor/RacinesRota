# Config.ps1 -- load, validate and normalise config\roster.json.
#
# Everything the engine treats as policy lives in the JSON; this file turns that into a
# shape the rest of the code can index cheaply, and refuses to proceed on bad input.
# Validation collects every problem before throwing, so one run tells you all of them.

Set-StrictMode -Version Latest

$script:SlotEligibility = @('ANY', 'PREF', 'OBLIG', 'NO')

function Test-RotaHasProperty {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)
    $null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name
}

function Get-RotaProperty {
    param($Object, [string]$Name, $Default = $null)
    if (Test-RotaHasProperty -Object $Object -Name $Name) { $Object.$Name } else { $Default }
}

function Import-RotaConfig {
    <#
    .SYNOPSIS
        Read roster.json, validate it, and return a normalised config object.
    .PARAMETER Path
        Path to the roster JSON.
    .PARAMETER SkipValidation
        Load without validating. Only for tests that deliberately build broken configs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$SkipValidation
    )

    if (-not (Test-Path -LiteralPath $Path)) { throw "Rota config not found: $Path" }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $config = $raw | ConvertFrom-Json

    $config = ConvertTo-RotaNormalisedConfig -Config $config
    if (-not $SkipValidation) {
        $problems = @(Test-RotaConfig -Config $config)
        if ($problems.Count -gt 0) {
            throw ("Invalid rota config '$Path':`n  - " + ($problems -join "`n  - "))
        }
    }
    $config
}

function ConvertTo-RotaNormalisedConfig {
    <#
    .SYNOPSIS
        Add computed lookups so the solver never re-parses the raw JSON shape.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    $dayIndex = @{}
    for ($i = 0; $i -lt $Config.days.Count; $i++) { $dayIndex[$Config.days[$i]] = $i }
    Add-Member -InputObject $Config -NotePropertyName DayIndexOf -NotePropertyValue $dayIndex -Force

    $weekendIdx = @($Config.weekendDays | ForEach-Object { $dayIndex[$_] })
    Add-Member -InputObject $Config -NotePropertyName WeekendDayIndexes -NotePropertyValue $weekendIdx -Force

    $byName = @{}
    foreach ($p in $Config.staff) {
        $byName[$p.name] = $p

        # Fixed staff: day -> slot list, expanded identically into every cycle week.
        $fixedByDay = @{}
        $fixed = Get-RotaProperty -Object $p -Name 'fixed'
        if ($null -ne $fixed) {
            foreach ($prop in $fixed.PSObject.Properties) { $fixedByDay[$prop.Name] = @($prop.Value) }
        }
        Add-Member -InputObject $p -NotePropertyName FixedByDay -NotePropertyValue $fixedByDay -Force

        # Solved staff: week number -> spec. A 1-week cycle repeats week 1's spec.
        $weekSpec = @{}
        $weeks = Get-RotaProperty -Object $p -Name 'weeks'
        if ($null -ne $weeks) {
            $personCycle = [int](Get-RotaProperty -Object $p -Name 'cycleWeeks' -Default $Config.meta.cycleWeeks)
            for ($w = 1; $w -le $Config.meta.cycleWeeks; $w++) {
                $sourceWeek = if ($personCycle -le 1) { 1 } else { (($w - 1) % $personCycle) + 1 }
                $weekSpec[$w] = $weeks."$sourceWeek"
            }
        }
        Add-Member -InputObject $p -NotePropertyName WeekSpec -NotePropertyValue $weekSpec -Force

        Add-Member -InputObject $p -NotePropertyName IsSolved -NotePropertyValue ($p.mode -eq 'solved') -Force
        Add-Member -InputObject $p -NotePropertyName IsResponsable -NotePropertyValue ([bool]$p.responsable) -Force
    }
    Add-Member -InputObject $Config -NotePropertyName StaffByName -NotePropertyValue $byName -Force
    Add-Member -InputObject $Config -NotePropertyName SolvedStaff -NotePropertyValue @($Config.staff | Where-Object IsSolved) -Force
    Add-Member -InputObject $Config -NotePropertyName FixedStaff -NotePropertyValue @($Config.staff | Where-Object { -not $_.IsSolved }) -Force
    Add-Member -InputObject $Config -NotePropertyName Responsables -NotePropertyValue @($Config.staff | Where-Object IsResponsable | ForEach-Object name) -Force

    $Config
}

function Test-RotaConfig {
    <#
    .SYNOPSIS
        Return a list of human-readable problems. Empty list means the config is usable.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    $problems = [System.Collections.Generic.List[string]]::new()

    if ($Config.meta.cycleWeeks -lt 1) { $problems.Add("meta.cycleWeeks must be at least 1.") }
    if ($Config.days.Count -ne 7) { $problems.Add("days must list exactly 7 days; found $($Config.days.Count).") }
    if (@($Config.slots) -join ',' -ne 'Lunch,Dinner') { $problems.Add("slots must be exactly ['Lunch','Dinner'].") }
    if ($Config.coverage.requiredPerService -lt 1) { $problems.Add("coverage.requiredPerService must be at least 1.") }

    foreach ($d in $Config.weekendDays) {
        if (-not $Config.DayIndexOf.ContainsKey($d)) { $problems.Add("weekendDays contains unknown day '$d'.") }
    }

    $seen = @{}
    foreach ($p in $Config.staff) {
        $name = $p.name
        if ([string]::IsNullOrWhiteSpace($name)) { $problems.Add("A staff entry has no name."); continue }
        if ($seen.ContainsKey($name)) { $problems.Add("Duplicate staff name '$name'.") }
        $seen[$name] = $true

        if ($p.mode -notin @('fixed', 'solved')) { $problems.Add("${name}: mode must be 'fixed' or 'solved'; got '$($p.mode)'.") }

        foreach ($day in $p.FixedByDay.Keys) {
            if (-not $Config.DayIndexOf.ContainsKey($day)) { $problems.Add("${name}: fixed references unknown day '$day'.") }
            foreach ($slot in $p.FixedByDay[$day]) {
                if ($slot -notin $Config.slots) { $problems.Add("${name}: fixed['$day'] references unknown slot '$slot'.") }
            }
        }

        if ($p.IsSolved) {
            if ($p.WeekSpec.Count -lt $Config.meta.cycleWeeks) {
                $problems.Add("${name}: is solved but has no week spec covering all $($Config.meta.cycleWeeks) cycle weeks.")
                continue
            }
            for ($w = 1; $w -le $Config.meta.cycleWeeks; $w++) {
                $spec = $p.WeekSpec[$w]
                if ($null -eq $spec) { $problems.Add("${name}: week $w spec is missing."); continue }
                if ($spec.shifts -lt 0) { $problems.Add("$name week ${w}: shifts must be >= 0.") }
                $ceiling = Get-RotaProperty -Object $spec -Name 'maxShifts' -Default $spec.shifts
                if ($ceiling -lt $spec.shifts) { $problems.Add("$name week ${w}: maxShifts ($ceiling) is below the target of $($spec.shifts).") }
                if ($ceiling -gt ($Config.days.Count * 2)) { $problems.Add("$name week ${w}: $ceiling shifts exceeds the $($Config.days.Count * 2) services in a week.") }
                if (-not $spec.doubles -and $ceiling -gt $Config.days.Count) {
                    $problems.Add("$name week ${w}: $ceiling shifts is impossible without doubles across $($Config.days.Count) days.")
                }
                foreach ($slotName in @('lunch', 'dinner')) {
                    if ($spec.$slotName -notin $script:SlotEligibility) {
                        $problems.Add("$name week ${w}: $slotName must be one of $($script:SlotEligibility -join '/'); got '$($spec.$slotName)'.")
                    }
                }
                if ($spec.lunch -eq 'NO' -and $spec.dinner -eq 'NO' -and $spec.shifts -gt 0) {
                    $problems.Add("$name week ${w}: both lunch and dinner are NO but shifts is $($spec.shifts).")
                }
            }
            $off = [double](Get-RotaProperty -Object $p -Name 'consecutiveDaysOff' -Default 0)
            if ($off -lt 0) { $problems.Add("${name}: consecutiveDaysOff must be >= 0.") }
        }

        $office = Get-RotaProperty -Object $p -Name 'officeLunch'
        if ($null -ne $office) {
            foreach ($day in @($office.candidateDays)) {
                if (-not $Config.DayIndexOf.ContainsKey($day)) { $problems.Add("${name}: officeLunch references unknown day '$day'.") }
                elseif ($p.FixedByDay.ContainsKey($day) -and $office.slot -notin $p.FixedByDay[$day]) {
                    $problems.Add("${name}: officeLunch candidate '$day' is not a $($office.slot) they actually work.")
                }
            }
        }
    }

    if ($Config.Responsables.Count -eq 0 -and $Config.rules.requireResponsablePerService) {
        $problems.Add("rules.requireResponsablePerService is on but no staff member is marked responsable.")
    }

    # Returned unwrapped, unlike the other collection helpers here: callers naturally write
    # @(Test-RotaConfig ...), and a comma-wrapped array would arrive as a single element.
    $problems.ToArray()
}

function Add-RotaFixedStaff {
    <#
    .SYNOPSIS
        Pre-place every fixed staff member into a schedule, for all cycle weeks.
    .DESCRIPTION
        Fixed rows are immutable input, so they are written once up front and the solver
        only ever fills around them. Also records each office-lunch choice, which is a
        per-week decision the solver branches on.
    .PARAMETER OfficeLunchDays
        Hashtable of "person|week" -> day name. Where absent, the first candidate day is
        used so that a schedule is always well-formed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Schedule,
        [hashtable]$OfficeLunchDays = @{}
    )
    $config = $Schedule.Config
    foreach ($p in $config.FixedStaff) {
        for ($w = 1; $w -le $config.meta.cycleWeeks; $w++) {
            foreach ($day in $p.FixedByDay.Keys) {
                foreach ($slot in $p.FixedByDay[$day]) {
                    Add-RotaAssignment -Schedule $Schedule -Person $p.name -Week $w `
                        -DayIndex $config.DayIndexOf[$day] -Slot $slot
                }
            }
            $office = Get-RotaProperty -Object $p -Name 'officeLunch'
            if ($null -ne $office) {
                $key = "$($p.name)|$w"
                $day = if ($OfficeLunchDays.ContainsKey($key)) { $OfficeLunchDays[$key] } else { @($office.candidateDays)[0] }
                $Schedule.OfficeLunch[$key] = $day
            }
        }
    }
    $Schedule
}


