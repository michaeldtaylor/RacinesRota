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

function Get-RotaRepeatMode {
    <#
    .SYNOPSIS
        How a person's weeks relate to one another: 'weekly', 'cycle' or 'none'.
    .DESCRIPTION
        The solver asks exactly one question about a person's weeks -- does this rota repeat
        every week, or is each week placed on its own? Two quite different intentions used to
        answer it through the same number, and a reader could not tell them apart:

          weekly  The same rota every week. One decision, reused. (A 1-week cycle.)
          cycle   The contract itself differs between weeks and repeats over cycleWeeks of
                  them: someone whose week 1 and week 2 are genuinely different jobs.
          none    No repetition is promised. Each week is placed independently, which is what
                  cover staff need -- a gap in week 1 and nothing in week 2 is the right
                  answer, and forcing their weeks to match would make them unusable.

        'cycle' and 'none' can produce the same search structure, so the distinction is not
        one the solver acts on; it is there so the file says which was meant, and so
        validation can object when the stated intent and the week specs disagree.

        Configs written before this field are read by their cycleWeeks, so they keep working
        and keep their current behaviour.
    .OUTPUTS
        One of 'weekly', 'cycle', 'none'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Person
    )
    $declared = Get-RotaProperty -Object $Person -Name 'repeat'
    if (-not [string]::IsNullOrWhiteSpace($declared)) { return "$declared".Trim().ToLowerInvariant() }

    # Legacy shape: cycleWeeks alone. 1 (or absent on a one-week rota) meant "repeats
    # weekly"; anything larger meant "my weeks differ", which is 'cycle'.
    $personCycle = [int](Get-RotaProperty -Object $Person -Name 'cycleWeeks' -Default $Config.meta.cycleWeeks)
    if ($personCycle -le 1) { 'weekly' } else { 'cycle' }
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

        # How this person's weeks relate to each other. See Get-RotaRepeatMode: it is the
        # single question the solver asks, and answering it explicitly is what stops
        # "repeats every week" and "place each week on its own" sharing one number.
        $repeat = Get-RotaRepeatMode -Config $Config -Person $p
        Add-Member -InputObject $p -NotePropertyName RepeatMode -NotePropertyValue $repeat -Force
        Add-Member -InputObject $p -NotePropertyName RepeatsWeekly -NotePropertyValue ($repeat -eq 'weekly') -Force

        # Solved staff: week number -> spec.
        #   weekly  every week uses week 1's spec
        #   cycle   the spec repeats every cycleWeeks weeks
        #   none    every week uses its own spec, and nothing is promised to repeat
        $weekSpec = @{}
        $weeks = Get-RotaProperty -Object $p -Name 'weeks'
        if ($null -ne $weeks) {
            $personCycle = [int](Get-RotaProperty -Object $p -Name 'cycleWeeks' -Default $Config.meta.cycleWeeks)
            for ($w = 1; $w -le $Config.meta.cycleWeeks; $w++) {
                $sourceWeek = switch ($repeat) {
                    'weekly' { 1 }
                    'cycle' { if ($personCycle -le 1) { 1 } else { (($w - 1) % $personCycle) + 1 } }
                    default { $w }
                }
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

        # The repeat mode and the week specs have to tell the same story. These checks exist
        # because two people once carried the same cycleWeeks for opposite reasons and the
        # file gave a reader no way to tell which was which.
        if ($p.RepeatMode -notin @('weekly', 'cycle', 'none')) {
            $problems.Add("${name}: repeat must be 'weekly', 'cycle' or 'none'; got '$($p.RepeatMode)'.")
        }
        elseif ($p.IsSolved) {
            $declaredCycle = Get-RotaProperty -Object $p -Name 'cycleWeeks'
            $specs = @(1..$Config.meta.cycleWeeks | ForEach-Object { $p.WeekSpec[$_] | ConvertTo-Json -Depth 5 -Compress })
            $allSame = (@($specs | Sort-Object -Unique).Count -le 1)

            switch ($p.RepeatMode) {
                'weekly' {
                    if ($null -ne $declaredCycle -and [int]$declaredCycle -gt 1) {
                        $problems.Add("${name}: repeat is 'weekly' but cycleWeeks is $declaredCycle. A weekly rota repeats every week; drop cycleWeeks, or say repeat 'cycle' if the weeks really differ.")
                    }
                }
                'cycle' {
                    if ($null -eq $declaredCycle -or [int]$declaredCycle -lt 2) {
                        $problems.Add("${name}: repeat is 'cycle' but cycleWeeks is not set to 2 or more. A cycle needs to say how many weeks long it is.")
                    }
                    elseif ([int]$declaredCycle -gt $Config.meta.cycleWeeks) {
                        $problems.Add("${name}: cycleWeeks is $declaredCycle but the rota is only $($Config.meta.cycleWeeks) weeks long.")
                    }
                    if ($allSame) {
                        $problems.Add("${name}: repeat is 'cycle' but every week's spec is identical, so there is no cycle to repeat. Use 'weekly' if the same rota should run every week, or 'none' if the weeks just need placing independently -- which is what cover staff want.")
                    }
                }
                'none' {
                    if ($null -ne $declaredCycle) {
                        $problems.Add("${name}: repeat is 'none', so nothing repeats and cycleWeeks ($declaredCycle) means nothing. Remove it.")
                    }
                }
            }
        }

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


