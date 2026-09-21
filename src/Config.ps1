# Config.ps1 -- load, validate and normalise config\roster.json.
#
# Everything the engine treats as policy lives in the JSON; this file turns that into a
# shape the rest of the code can index cheaply, and refuses to proceed on bad input.
# Validation collects every problem before throwing, so one run tells you all of them.

Set-StrictMode -Version Latest

$script:SlotEligibility = @('ANY', 'PREF', 'OBLIG', 'NO')

function Test-RotaHasProperty {
    <#  Works for both shapes a config arrives in. roster.json parses into PSCustomObjects,
        whose members are PSObject.Properties; the Excel importer builds hashtables, whose
        members are Keys -- asking one for the other's accessor answers "no" with no error.
        This has now caused three separate silent losses (fixed rows, availability, and the
        give in a released week), so it is settled here once rather than at each call.  #>
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
    $Object.PSObject.Properties.Name -contains $Name
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

function ConvertTo-RotaDayMask {
    <#
    .SYNOPSIS
        A day -> slots map as a 14-bit week mask.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Days,
        [Parameter(Mandatory)][hashtable]$DayIndexOf
    )
    $mask = 0
    foreach ($day in $Days.Keys) {
        if (-not $DayIndexOf.ContainsKey($day)) { continue }
        foreach ($slot in @($Days[$day])) {
            if ($slot -notin @('Lunch', 'Dinner')) { continue }
            $mask = $mask -bor (1 -shl (Get-RotaSlotIndex -DayIndex $DayIndexOf[$day] -Slot $slot))
        }
    }
    $mask
}

function Get-RotaNameValuePairs {
    <#
    .SYNOPSIS
        Enumerate a day-keyed map whether it came from JSON or from a workbook.
    .DESCRIPTION
        roster.json parses into PSCustomObjects, whose members come from PSObject.Properties.
        The Excel importer builds the same maps as hashtables, whose members do not -- asking
        a hashtable for PSObject.Properties yields Keys, Values and Count rather than the
        days. Reading one shape with the other's accessor produces an empty map and no error,
        which is how a person's availability quietly became "nothing at all".
    .OUTPUTS
        Objects with Name and Value.
    #>
    [CmdletBinding()]
    param($Map)
    if ($null -eq $Map) { return }
    if ($Map -is [System.Collections.IDictionary]) {
        foreach ($key in $Map.Keys) { [pscustomobject]@{ Name = $key; Value = $Map[$key] } }
        return
    }
    foreach ($prop in $Map.PSObject.Properties) { [pscustomobject]@{ Name = $prop.Name; Value = $prop.Value } }
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
            foreach ($entry in (Get-RotaNameValuePairs -Map $fixed)) { $fixedByDay[$entry.Name] = @($entry.Value) }
        }
        Add-Member -InputObject $p -NotePropertyName FixedByDay -NotePropertyValue $fixedByDay -Force

        # A week named in fixedByWeek replaces the default pattern for that week outright --
        # it is not merged. Being explicit avoids the question nobody agrees on, which is
        # whether naming a day in an override adds to that day or replaces it.
        $byWeek = @{}
        $override = Get-RotaProperty -Object $p -Name 'fixedByWeek'
        if ($null -ne $override) {
            foreach ($entry in (Get-RotaNameValuePairs -Map $override)) {
                $days = @{}
                foreach ($d in (Get-RotaNameValuePairs -Map $entry.Value)) { $days[$d.Name] = @($d.Value) }
                $byWeek[[int]$entry.Name] = $days
            }
        }
        Add-Member -InputObject $p -NotePropertyName FixedByWeek -NotePropertyValue $byWeek -Force

        $fixedMask = ConvertTo-RotaDayMask -Days $fixedByDay -DayIndexOf $dayIndex
        Add-Member -InputObject $p -NotePropertyName FixedMask -NotePropertyValue $fixedMask -Force

        # Resolved per week, so nothing downstream has to remember the override exists.
        $maskForWeek = @{}
        $daysForWeek = @{}
        for ($w = 1; $w -le $Config.meta.cycleWeeks; $w++) {
            $daysForWeek[$w] = $(if ($byWeek.ContainsKey($w)) { $byWeek[$w] } else { $fixedByDay })
            $maskForWeek[$w] = $(if ($byWeek.ContainsKey($w)) { ConvertTo-RotaDayMask -Days $byWeek[$w] -DayIndexOf $dayIndex } else { $fixedMask })
        }
        Add-Member -InputObject $p -NotePropertyName FixedDaysForWeek -NotePropertyValue $daysForWeek -Force
        Add-Member -InputObject $p -NotePropertyName FixedMaskForWeek -NotePropertyValue $maskForWeek -Force

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
        # firmShifts is sugar: "this number is not a target, it is the number". Expanding it
        # here means the solver and the constraint engine both see a plain floor and ceiling,
        # and neither needs to know the shorthand exists.
        foreach ($w in @($weekSpec.Keys)) {
            $spec = $weekSpec[$w]
            if ($null -eq $spec) { continue }
            if ([bool](Get-RotaProperty -Object $spec -Name 'firmShifts' -Default $false)) {
                Add-Member -InputObject $spec -NotePropertyName minShifts -NotePropertyValue ([int]$spec.shifts) -Force
                Add-Member -InputObject $spec -NotePropertyName maxShifts -NotePropertyValue ([int]$spec.shifts) -Force
            }
        }

        # Per-day availability: which services this person can work at all. Distinct from the
        # week spec, which can only say "no weekends" or "lunches only" -- it cannot say
        # "Monday lunch and dinner, but Tuesday lunch only". Absent means no restriction.
        $availableByDay = @{}
        $availableMask = $null
        $available = Get-RotaProperty -Object $p -Name 'available'
        if ($null -ne $available) {
            $availableMask = 0
            foreach ($entry in (Get-RotaNameValuePairs -Map $available)) {
                $availableByDay[$entry.Name] = @($entry.Value)
                if (-not $dayIndex.ContainsKey($entry.Name)) { continue }
                foreach ($slot in @($entry.Value)) {
                    if ($slot -notin @('Lunch', 'Dinner')) { continue }
                    $availableMask = $availableMask -bor (1 -shl (Get-RotaSlotIndex -DayIndex $dayIndex[$entry.Name] -Slot $slot))
                }
            }
        }
        Add-Member -InputObject $p -NotePropertyName AvailableByDay -NotePropertyValue $availableByDay -Force
        Add-Member -InputObject $p -NotePropertyName AvailableMask -NotePropertyValue $availableMask -Force

        # Fixed rows are input, but a week can be nominated as give: their pattern becomes a
        # ceiling the engine may work below, to free capacity for someone who needs it. The
        # released weeks become ordinary search variables whose domain is their own pattern,
        # so nothing else in the solver has to learn a new shape.
        $flexibleWeeks = @{}
        $flexible = Get-RotaProperty -Object $p -Name 'flexible'
        if ($null -ne $flexible -and $p.mode -ne 'solved') {
            foreach ($entry in (Get-RotaNameValuePairs -Map $flexible)) {
                $w = [int]$entry.Name
                if ($w -lt 1 -or $w -gt $Config.meta.cycleWeeks) { continue }
                $weekDays = $(if ($byWeek.ContainsKey($w)) { $byWeek[$w] } else { $fixedByDay })
                $fixedCount = 0
                foreach ($day in $weekDays.Keys) { $fixedCount += @($weekDays[$day]).Count }
                $maxDrop = [int](Get-RotaProperty -Object $entry.Value -Name 'maxDrop' -Default 0)
                $flexibleWeeks[$w] = [pscustomobject]@{
                    MaxDrop    = $maxDrop
                    FixedCount = $fixedCount
                }
                # Give the week a spec so the solver can treat it like any other variable:
                # aim for the full pattern, never exceed it, and go no lower than the give.
                $weekSpec[$w] = [pscustomobject]@{
                    doubles   = $true
                    weekend   = $true
                    lunch     = 'ANY'
                    dinner    = 'ANY'
                    shifts    = $fixedCount
                    maxShifts = $fixedCount
                    minShifts = [math]::Max(0, $fixedCount - $maxDrop)
                }
            }
        }
        Add-Member -InputObject $p -NotePropertyName FlexibleWeeks -NotePropertyValue $flexibleWeeks -Force
        Add-Member -InputObject $p -NotePropertyName WeekSpec -NotePropertyValue $weekSpec -Force

        Add-Member -InputObject $p -NotePropertyName IsSolved -NotePropertyValue ($p.mode -eq 'solved') -Force
        Add-Member -InputObject $p -NotePropertyName IsResponsable -NotePropertyValue ([bool]$p.responsable) -Force
    }
    Add-Member -InputObject $Config -NotePropertyName StaffByName -NotePropertyValue $byName -Force
    Add-Member -InputObject $Config -NotePropertyName SolvedStaff -NotePropertyValue @($Config.staff | Where-Object IsSolved) -Force
    Add-Member -InputObject $Config -NotePropertyName FixedStaff -NotePropertyValue @($Config.staff | Where-Object { -not $_.IsSolved }) -Force
    # Fixed staff with give in at least one week. They are placed by the search in those
    # weeks and pre-placed in the rest, so both halves of the engine need to find them.
    Add-Member -InputObject $Config -NotePropertyName FlexibleStaff -NotePropertyValue `
    @($Config.staff | Where-Object { -not $_.IsSolved -and $_.FlexibleWeeks.Count -gt 0 }) -Force
    Add-Member -InputObject $Config -NotePropertyName Services -NotePropertyValue (Get-RotaServices -Config $Config) -Force
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

    # Per-service coverage. A typo here silently staffs the wrong service, which is the kind
    # of mistake nobody notices until the night it happens.
    $closedKeys = @{}
    foreach ($c in @($Config.coverage.closed)) {
        if ($null -ne $c) { $closedKeys["$($c.day)|$($c.slot)"] = $true }
    }
    $seenOverride = @{}
    foreach ($o in @(Get-RotaProperty -Object $Config.coverage -Name 'overrides')) {
        if ($null -eq $o) { continue }
        $oDay = Get-RotaProperty -Object $o -Name 'day'
        $oSlot = Get-RotaProperty -Object $o -Name 'slot'
        if ([string]::IsNullOrWhiteSpace($oDay) -and [string]::IsNullOrWhiteSpace($oSlot)) { continue }
        $where = "coverage.overrides for '$oDay $oSlot'"
        if ([string]::IsNullOrWhiteSpace($oDay) -or -not $Config.DayIndexOf.ContainsKey($oDay)) { $problems.Add("${where}: unknown day '$oDay'.") }
        if ($oSlot -notin @($Config.slots)) { $problems.Add("${where}: unknown slot '$oSlot'.") }
        if (-not (Test-RotaHasProperty -Object $o -Name 'required')) { $problems.Add("${where}: no 'required' given.") }
        elseif ([int](Get-RotaProperty -Object $o -Name 'required') -lt 1) { $problems.Add("${where}: required must be at least 1; close the service instead.") }

        $key = "$oDay|$oSlot"
        if ($seenOverride.ContainsKey($key)) { $problems.Add("${where}: listed more than once.") }
        $seenOverride[$key] = $true
        if ($closedKeys.ContainsKey($key)) { $problems.Add("${where}: the service is also listed as closed, so the two disagree about whether it runs.") }
    }

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

        # officeLunch.count reads as though it did something. It does not: the search
        # assigns exactly one admin lunch per person per week. Saying so beats letting
        # somebody write 2 and wonder why they only ever get one.
        $office = Get-RotaProperty -Object $p -Name 'officeLunch'
        if ($null -ne $office) {
            $count = Get-RotaProperty -Object $office -Name 'count'
            if ($null -ne $count -and [int]$count -ne 1) {
                $problems.Add("${name}: officeLunch.count is $count, but only one admin lunch per week is supported. Remove the key, or set it to 1.")
            }
        }

        foreach ($w in $p.FixedByWeek.Keys) {
            if ($w -lt 1 -or $w -gt $Config.meta.cycleWeeks) {
                $problems.Add("${name}: fixedByWeek names week $w, but the rota is $($Config.meta.cycleWeeks) weeks long.")
                continue
            }
            foreach ($day in $p.FixedByWeek[$w].Keys) {
                if (-not $Config.DayIndexOf.ContainsKey($day)) { $problems.Add("${name}: fixedByWeek week $w references unknown day '$day'.") }
                foreach ($slot in $p.FixedByWeek[$w][$day]) {
                    if ($slot -notin @($Config.slots)) { $problems.Add("${name}: fixedByWeek week $w references unknown slot '$slot' on $day.") }
                }
            }
        }
        if ($p.IsSolved -and $p.FixedByWeek.Count -gt 0) {
            $problems.Add("${name}: fixedByWeek only means something for a fixed person; this one is solved.")
        }

        foreach ($day in $p.AvailableByDay.Keys) {
            if (-not $Config.DayIndexOf.ContainsKey($day)) { $problems.Add("${name}: available references unknown day '$day'.") }
            foreach ($slot in $p.AvailableByDay[$day]) {
                if ($slot -notin @($Config.slots)) { $problems.Add("${name}: available lists unknown slot '$slot' on $day.") }
            }
        }
        if ($null -ne $p.AvailableMask -and $p.AvailableMask -eq 0) {
            $problems.Add("${name}: available is present but lists nothing workable, so they can never be rostered. Remove it, or give them a day.")
        }

        # A preference below what someone is already owed is dead config, and reads as though
        # it were doing something.
        $wanted = [double](Get-RotaProperty -Object $p -Name 'preferredConsecutiveDaysOff' -Default 0)
        if ($wanted -gt 0) {
            $owed = [math]::Max(
                [double](Get-RotaProperty -Object $p -Name 'consecutiveDaysOff' -Default 0),
                [double](Get-RotaProperty -Object $Config.rules -Name 'minConsecutiveDaysOffForEveryone' -Default 0))
            if ($wanted -le $owed) {
                $problems.Add("${name}: preferredConsecutiveDaysOff ($wanted) is not above what they are already owed ($owed), so it can never apply. Raise it, or remove it.")
            }
        }

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
            # A week with give is the search's to fill, not ours -- pre-placing it here
            # would leave the solver nothing to reduce.
            if ($p.FlexibleWeeks.ContainsKey($w)) {
                $office = Get-RotaProperty -Object $p -Name 'officeLunch'
                if ($null -ne $office) {
                    $key = "$($p.name)|$w"
                    $Schedule.OfficeLunch[$key] = $(if ($OfficeLunchDays.ContainsKey($key)) { $OfficeLunchDays[$key] } else { @($office.candidateDays)[0] })
                }
                continue
            }
            $days = $p.FixedDaysForWeek[$w]
            foreach ($day in $days.Keys) {
                foreach ($slot in $days[$day]) {
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


