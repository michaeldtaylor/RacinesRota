# RacinesRota

Generates the restaurant's two-week repeating rota from a declarative roster, checks it
against the house rules, and exports JSON and Excel.

```powershell
.\Invoke-Rota.ps1
```

Writes `out\schedule.json` and `out\rota.xlsx`, prints a report, and exits non-zero if any
hard rule is broken — so it can gate a scheduled run. Add `-NoExcel` for JSON only.

---

## Why this exists

The rota was maintained by hand. Four staff work a fixed weekly pattern; the rest are placed
around them according to contracts that differ per person — shifts per week, whether doubles
are allowed, weekend availability, lunch/dinner eligibility, and a required run of consecutive
days off. Barbara's two weeks are different jobs, so the whole rota is a 14-day repeating
template rather than a single week.

Doing that by hand is slow and quietly error-prone. It is easy to leave a service without a
responsable, overshoot someone's contracted hours, or break a days-off guarantee and not
notice. Worse, the failures are invisible: a rota that is two people short on a Thursday looks
exactly like one that is fine until the Thursday arrives.

The engine's job is therefore not only to produce a schedule but to **say plainly what it
could not do**. Every shortfall, every unmet preference and every dependency on temporary
staff is named in the output.

---

## The domain

A **cycle** is 14 days: week 1 Lundi–Dimanche, week 2 Lundi–Dimanche. Each day has two
**services** — lunch (staff start 10H) and dinner (18H, or 19H for Clémentine). Working both
services in one day is a **double**. All 14 services a week are open, and each needs three
people on the floor by default; individual services can ask for more or fewer
(`coverage.overrides`).

| Person | Contract | Role |
|---|---|---|
| Suyeon, Giulia, Lucas | RESP | Fixed pattern, responsable |
| Clémentine | MI TEMPS | Fixed pattern |
| Veronica | MI TEMPS | Placed by the engine |
| Barbara, Beatrice | PLEIN TEMPS | Placed by the engine |
| Federica | TEMPORAIRE | Cover only — leaving, and barred from the rota at present |

Slot eligibility vocabulary, taken from the original spreadsheet:
`OBLIG` every shift must be this service · `NO` never this service ·
`PREF` soft preference · `ANY` no preference.

---

## The rules

**Hard** — a schedule breaking one of these is wrong, and the engine says so.

| | Rule |
|---|---|
| H1 | Every open service has exactly its required number on the floor — under *or* over |
| H2 | At least one responsable on every service |
| H3 | Fixed rows are input and are never modified |
| H4 | Nobody exceeds their contracted ceiling |
| H5 | No doubles unless that person's week allows them |
| H6 | `NO` means never; `OBLIG` means every shift |
| H7 | No weekend work for someone unavailable at weekends |
| H8 | Solved staff get their required run of consecutive days off, **in every week** |
| H9 | The same floor applies to fixed staff (`rules.minConsecutiveDaysOffForEveryone`) |
| H10 | Nobody is rostered on a service they are not available for (`staff[].available`) |
| H11 | Nobody works fewer than their declared floor (`minShifts`) |

An evaluator is not the same thing as a violation. One pass over shift counts can report
three different faults — over the ceiling (H4), under the floor (H11), under the target
(S3) — and days off reports under H8 or H9 depending on whether the person's rota is solved
or fixed. The registry in `src\Constraints.ps1` therefore lists each evaluator with every id
it can raise, and a test holds that list to the ids actually present in the file. H9 and H11
went unlisted for a while precisely because one evaluator was assumed to mean one rule.

**Soft** — scored and traded off, never silently dropped.

| | Preference |
|---|---|
| S1 | `PREF` slot honoured |
| S2 | No isolated single working days |
| S3 | Shift targets met (cost grows with the *square* of the deficit, so shortfalls spread rather than landing on one person) |
| S5 | Weekend and dinner load spread evenly across the permanent solved staff (cover is left out — S7 already wants it light) |
| S6 | Admin lunches genuinely free, not load-bearing |
| S7 | Temporary cover used as little as possible |
| S8 | A longer run of days off that someone would like but is not owed |
| S9 | A fixed shift given up so someone else could be rostered |

There is no S4 — staffing levels are H1's job, in both directions, and the number was left
free rather than renumbering the rest.

**Every person-week has a floor, a target and a ceiling.** `minShifts` is hard (H11) and is
how "must have nine shifts" is said; `shifts` is the target, missing it only costs (S3);
`maxShifts` is a hard cap that defaults to the target. `firmShifts: true` is sugar for
floor = target = ceiling. A new rule like "at least four, ideally six, never more than seven"
needs no new vocabulary.

**A fixed week can be released.** `flexible: { "2": { "maxDrop": 3 } }` says that week's
pattern is a ceiling, not a promise: the engine may work them up to three shifts fewer to
free capacity for someone who needs it. The released week becomes an ordinary search
variable whose domain is that person's own pattern, so shifts can only be taken away, never
moved elsewhere — H3 still rejects anything outside the pattern. Each shift given up is
charged (`weights.releasedFixedShift`) and named under S9.

**`consecutiveDaysOff` is a promise; `preferredConsecutiveDaysOff` is a wish.** Breaking the
first makes a schedule wrong (H8/H9). Missing the second is reported and costed (S8) and
nothing more. Keeping them apart matters: a wish written into the hard field makes the solver
reject perfectly legal rotas, and the report can no longer tell a broken promise from an
unmet preference. Barbara is owed 2 in a row; Beatrice is owed 2 and would like 3.5.

Adding a rule means writing one function and adding one line to the registry in
`src\Constraints.ps1`, naming the ids it can raise. Nothing else changes.

---

## Interpretation decisions

These came out of the original spreadsheet and are recorded because they are judgement calls,
not facts. All are config, not code — change them in `config\roster.json`.

**Days off are measured per week, not per cycle** (`rules.daysOffScope`). One long break in
week 2 does not excuse week 1 having none. Runs are measured on a ring, so a Saturday–Monday
block straddling the boundary counts for both weeks it touches.

**A half day only ever supplies the ".5"** in a requirement like Barbara's 3.5. The whole
number must be met by whole days off. Without this, "lunch Monday, Tuesday off, lunch
Wednesday" scores 2.0 and satisfies a two-days-in-a-row rule while giving nobody two days off
in a row.

**Each solved person says how their weeks relate to each other** (`staff[].repeat`):

| | Meaning | Who |
|---|---|---|
| `weekly` | The same rota every week — one decision, reused | Beatrice |
| `cycle` | The contract itself differs between weeks and repeats over `cycleWeeks` of them | Barbara, Veronica |
| `none` | Nothing repeats; each week is placed on its own | Federica |

Only `weekly` collapses to a single decision. `cycle` and `none` produce the same search
structure and differ in what they *mean*, which is the point: one number used to answer both
questions, and two people carried the same value for opposite reasons. Validation now rejects
a `cycle` whose weeks are identical, and names the two better answers. Set
`rules.enforcePersonCycleRepeat` to false to let a `weekly` person's weeks differ after all.

Veronica is `cycle` because her week 2 — the week Barbara covers dinners and weekends — leans
much harder towards lunches (`preferenceWeight`), even though her shift count is the same.

The distinction is load-bearing for cover. Federica must be `none`: a shortfall usually falls
in one week only, and a repeating week cannot take it without also working the other, where
there may be no room. She is barred at present (see Known limitations), so this only matters
again if she is brought back.

**An office lunch still counts towards the three** (`rules.officeLunchCountsOnFloor`).
Suyeon does admin but can step onto the floor. This contradicts the note on the original
sheet — *"MEANING 4 ON SHIFT TOTAL"* — and was changed on instruction; it recovered three
services. The engine reports (S6) whenever she is load-bearing rather than genuinely free.

**Temporary staff are strictly additive.** See below.

---

## How the solver works

The search is over whole **week patterns** rather than individual shifts, because every
per-person rule is a property of someone's week. Enumerating legal weeks first means the
search never visits a state that breaks one, and coverage becomes pure bitmask arithmetic —
a person's week is a 14-bit mask, and coverage is tracked as one mask per (level, week).

Seven things make it tractable:

1. **Shift-count pre-solve.** How many shifts each variable contributes is decided before any
   pattern is examined, by solving a small integer problem over the week totals. Distributions
   are then tried cheapest-first, costed on coverage shortfall, underrun and temporary cover.
2. **Coupling variables first.** A person working every week glues the weeks into one
   problem: until their pattern is pinned, no week's capacity can be pruned on its own.
   They are therefore placed first, ahead of smaller domains. Ordering by domain size alone
   put them last -- the person working every week tends to have the largest domain -- and the
   search then ground through the whole cross product before discovering the one variable
   that never fitted. On this roster that was the difference between an answer and a timeout.
3. **Days off decided up front.** A variable spanning the whole cycle carries the same mask in
   every week, so its days-off verdict is settled by that one pattern. Those are dropped
   before the kernel sees them rather than after components are joined — the difference
   between rejecting a dead branch at its root and walking the whole subtree beneath it.
4. **One search per distinct capacity.** Office-lunch arrangements that leave identical
   per-service gaps pose the identical problem. They are grouped, searched once, and the
   masks handed to every arrangement in the group; they differ only in admin-lunch cost,
   which exact scoring settles.
5. **Independent components.** Variables interact only if they compete for capacity in the
   same week. When nobody spans both weeks, the weeks are separate problems.
6. **Zero-capacity masking.** A pattern touching a full service dies on a single `-band`.
7. **Last-variable determination.** When a week must come out exactly full, the final
   variable's pattern is whatever capacity remains — one hash lookup, not a domain scan.

Prunes 2 and 3 were added after the shipped roster started exhausting its time budget: the
search was visiting 6.8 million nodes, surrendering to the clock, and returning a single
candidate — which is not a search result but an accident, since the scorer had nothing to
choose between. Those two prunes brought it down to 11,605 nodes, and it found a better
schedule than the one it used to time out on.

The roster has since grown harder, and the search has been widened on purpose: fixed weeks
can be released, `maxCostDrop` is 20,000 and the shortlist 5,000, because narrower settings
were stopping at visibly worse rotas. The shipped roster now takes, per pass:

| | nodes | candidates | scored exactly |
|---|---|---|---|
| permanent team only | 4.38 million | 26 | 104 |
| with cover | 1.07 million | 5 | 20 |

Neither pass comes near the budget. The whole `Invoke-Rota.ps1` run takes 15–35 seconds
depending on the machine and its load, and prints a `Search,` line for each pass.

### Two-pass temporary cover

Cover staff must never make the rota *easier* — only fill what the permanent team genuinely
cannot reach. A cost alone cannot promise that: the solver would still trade a contracted
shift for a cover shift whenever the arithmetic suited. It did exactly that, dropping Beatrice
from 7+7 to 6+6 while Federica picked up three shifts.

So the permanent team is solved **first, on its own**, and its resulting shift counts become a
floor for a second pass that includes cover. Cover can then only ever add on top.

### Determinism

Same config, same result, always — fixed iteration order throughout, with no random seed
anywhere. This is what makes the tests meaningful.

---

## Layout

```
Invoke-Rota.ps1          CLI entry point
config\roster.json       the roster: staff, contracts, rules, weights  <- the input
src\Model.ps1            index arithmetic, masks, days-off measurement
src\Config.ps1           loading, validation, normalisation, repeat modes
src\Constraints.ps1      one evaluator per rule, in a registry
src\SearchKernel.ps1     the depth-first search, in C# via Add-Type
src\Solver.ps1           variables, components, orchestration, two-pass cover
src\Report.ps1           coverage, people, temp exposure, violations
src\Export.ps1           .xlsx output
src\ConfigExcel.ps1      criteria as a workbook (see caveat below)
tests\                   Pester suite
```

### Why one file is C#

The search visits millions of nodes and PowerShell's per-call overhead dominated it — the
original took 339 seconds. Moving just the kernel to C# took it to 27. `Add-Type` needs no
.NET SDK, since PowerShell carries its own compiler, so the project still runs from a bare
PowerShell 7 install. Everything else stays in PowerShell where it is readable and changeable.

The kernel knows nothing about rota rules. It is handed pre-filtered pattern domains and a
capacity model and returns the cheapest complete assignments it finds. Every rule lives in
`Constraints.ps1`, which is also what scores the winner.

Worth knowing before optimising further: the kernel is *not* the slow part any more. In one
profiled 28-second solve of the shipped roster, the kernel took 3.6 seconds across both
passes, while `Join-RotaComponents` — the PowerShell that combines component solutions into
candidates — took 12.4, and exact scoring by `Test-RotaSchedule` 2.9. The rest was other
PowerShell: pattern enumeration, costing and schedule building. If a run needs to be faster,
start with the join, not the kernel.

---

## Testing

```powershell
Invoke-Pester .\tests -Output Normal
```

184 tests, 2–4 minutes (the workbook round trip solves the real roster twice).

| File | Covers |
|---|---|
| `Model.Tests.ps1` | Indexing, masks, days-off measurement, coverage overrides |
| `Config.Tests.ps1` | Loading, validation, repeat modes, the shipped roster's figures |
| `Constraints.Tests.ps1` | Every rule, passing **and** failing |
| `Solver.Tests.ps1` | Search structure, determinism, cover behaviour |
| `Integration.Tests.ps1` | The real roster, solved — tagged `Slow` |
| `ConfigExcel.Tests.ps1` | The roster through the workbook and back — tagged `Slow` |

Most tests run against a small synthetic roster in `TestHelpers.ps1` that solves in about a
second. The shipped roster's own figures — 40 person-shifts a week, which fixed weeks may be
released, who repeats how, Federica as the only temp and barred outright — are asserted in
`Config.Tests.ps1`, so editing `roster.json` into a different shape fails loudly rather than
producing a plausible rota for the wrong restaurant.

Skip the slow ones while iterating:

```powershell
Invoke-Pester .\tests -ExcludeTagFilter Slow
```

Three tests are worth knowing about:

- **Solver and constraint engine must agree on days off.** The solver has a fast inline copy
  for speed; if the two drift, the search would silently discard good schedules and nothing
  else would notice.
- **Cover never reduces permanent hours.** The two-pass guarantee, asserted directly.
- **The real roster's search completes.** `Integration.Tests.ps1` solves `roster.json` and
  fails if the search times out or returns a single candidate. The synthetic fixture never
  approaches the time budget, so nothing else in the suite can see that failure.

Every bug found during development has a named `REGRESSION:` test.

---

## Known limitations

**The Excel criteria workbook is not the input.** `Export-RotaConfigExcel` and
`Import-RotaConfigExcel` round-trip staff, criteria, availability, coverage overrides and
rules, and `ConfigExcel.Tests.ps1` now proves a full roster survives the trip and solves to
the same score. But `roster.json` is still what the engine is driven from, and nothing in
normal use goes through the workbook. Adding a config field means adding it to both sides, or
the sheet loses it silently the first time somebody edits it — that round-trip test is what
catches this.

**A rota with a named problem beats a refusal.** Where the staff simply cannot cover the
week, the engine still returns the best arrangement it can find and names the gap, rather
than throwing. The same applies to a shift floor that cannot be met: it solves again without
the floors and reports the breach as H11. The exit code is still non-zero, so a scheduled run
notices.

**The search is bounded, not exhaustive.** It stops at a time budget
(`solver.timeBudgetSeconds`) and searches a band of shift-count distributions
(`solver.maxCostDrop`, a cost budget rather than a shift count). The result is the best found,
not a proven global optimum. A run that hits the budget says so, and a timeout is never
reported as "impossible" — those are very different answers about a roster.

**Rows below 17 of the original spreadsheet were never supplied**, so any rules there are not
implemented.

**Contracted hours exceed the rota's gaps; responsables give shifts back to absorb them.**
A week needs 40 person-shifts — 14 services at three, less one each for the midweek lunches
(Mercredi and Jeudi) that run with two. The fixed rows cover 24, leaving 16 for solved staff:

| | week 1 | week 2 |
|---|---|---|
| gaps left by the fixed rows | 16 | 16 |
| permanent solved staff contracted to fill them | 17 | **21** |
| fixed shifts Suyeon and Giulia may release (`flexible`) | up to 2 | up to 6 |
| released in the current rota | 1 | 5 |

Barbara's week 1 is capped at exactly five by her own terms — lunch only, no weekends, no
doubles gives Monday to Friday lunch and no choice in it — so a full-time 14 forces nine into
week 2. **The contracts stand as written**: the surplus of six is absorbed by releasing six of
Suyeon's and Giulia's fixed shifts, each charged and named under S9. Every service is staffed
and no hard rule breaks.

The margin is thin. Week 1 can release only one more shift, so it has room for at most one
more contracted shift. Beyond that, added week 1 hours — a new hire, or a raised contract —
break a floor (H11) or overstaff a service (H1) unless `flexible` allows more to be released.

**Federica is barred** (`maxShifts: 0` in both weeks) and the rota no longer needs her. She
stays on the roster as a record; raising her `maxShifts` makes her gap cover again.

---

## Configuration

Everything lives in `config\roster.json`.

| Key | Effect |
|---|---|
| `coverage.requiredPerService` | People needed per service, by default |
| `coverage.overrides` | `{day, slot, required}` for services that differ from that default, in every week |
| `coverage.closed` | Services that do not run at all |
| `rules.daysOffScope` | `week` or `cycle` |
| `rules.enforcePersonCycleRepeat` | Whether a `weekly` person really repeats |
| `rules.officeLunchCountsOnFloor` | Whether an admin lunch counts towards the three |
| `rules.minConsecutiveDaysOffForEveryone` | The floor that applies to fixed staff too |
| `weights.*` | What the engine trades against what |
| `solver.timeBudgetSeconds` | How long to search, per pass — and there are two passes |
| `solver.maxCostDrop` | How far above the cheapest distribution to keep looking (a cost, not a count) |
| `staff[].repeat` | `weekly`, `cycle` or `none` — see above |
| `staff[].consecutiveDaysOff` | The run of days off this person is **owed** (hard) |
| `staff[].preferredConsecutiveDaysOff` | A longer run they would **like** (soft, S8). Must be above what they are owed, or it is rejected as dead config |
| `staff[].available` | `{day: [slots]}` — the exact services this person can work. Absent means no restriction. The week spec can only say "no weekends" or "lunches only"; this says "Monday dinner but no other dinner" |
| `staff[].weeks.N.minShifts` | A hard floor on shifts that week (H11) |
| `staff[].weeks.N.firmShifts` | Sugar: floor = target = ceiling |
| `staff[].fixedByWeek` | `{week: {day: [slots]}}` — replaces the fixed pattern for the weeks it names. Use it when somebody covers an extra shift in one week only |
| `staff[].flexible` | `{week: {maxDrop: n}}` — a fixed week the engine may work below, by at most `n` |
| `staff[].weeks.N.preferenceWeight` | What a missed `PREF` costs in *this* week, overriding `weights.slotPreference`. Use it for a preference that is nearly a rule without being one |
| `staff[].temporary` | Cover only — never used to solve |
| `staff[].weeks.N.maxShifts` | Ceiling above the target, for cover staff |

A person with `"temporary": true`, a target of `0` and a `maxShifts` ceiling is cover: charged
per shift, used only where the permanent team cannot reach, and listed under **leaver
exposure** in every report. Note that `contract: "TEMPORAIRE"` does *not* do this — the
`temporary` flag is what the engine reads; the contract string is a label for the report.

---

## Requirements

- PowerShell 7+
- `Pester` 6+ for the tests — `Install-Module Pester -MinimumVersion 6.0 -Scope CurrentUser -SkipPublisherCheck`
- `ImportExcel` for `.xlsx` output — `Install-Module ImportExcel -Scope CurrentUser`.
  Optional: `.\Invoke-Rota.ps1 -NoExcel` writes JSON only and needs nothing extra.

No .NET SDK required.
