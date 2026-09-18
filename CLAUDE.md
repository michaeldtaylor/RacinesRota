# Working in this repo

## Comma-wrapped returns — assign before you use

Most collection-returning functions here end with `, $thing`. That leading comma is
deliberate: without it PowerShell unrolls the pipeline and a **single-element** array arrives
as a bare scalar, so `.Count` is missing and indexing silently does the wrong thing. The comma
wraps the array in an outer one-element array, which the pipeline unrolls back to the array
itself.

The cost is that the wrapper survives if you *don't* let it unroll:

```powershell
# WRONG -- $v is the whole wrapped array, not the first variable.
$v = @(New-RotaSolverVariables -Config $cfg)[0]

# WRONG -- Where-Object receives one item (the entire array) and tests it as a single object.
$hit = @(Get-RotaServices -Config $cfg | Where-Object { $_.Required -eq 5 })

# RIGHT -- assignment unrolls the wrapper. Assign first, then index, pipe or filter.
$vars = New-RotaSolverVariables -Config $cfg
$v = $vars[0]

$services = Get-RotaServices -Config $cfg
$hit = @($services | Where-Object { $_.Required -eq 5 })
```

The failure is quiet and the error message points somewhere else: you get `Expected 1, but got
2`, or a `Should -BeFalse` that got `$true`, or `Expected 1, but got @(2, 2, 1, ...)` — because
the assertion ran against the array rather than the element. Production code gets this right
because it assigns; it is test code that tends to reach for `@(Func)[0]`.

**Rule: never call one of these inline. Assign the result to a variable first, then use the
variable.**

| File | Functions |
|---|---|
| `src\Model.ps1` | `Get-RotaServices`, `Get-RotaCoverage`, `Get-RotaCycleDayLoads`, `Get-RotaDaysOffRunByWeek` |
| `src\Solver.ps1` | `New-RotaSolverVariables`, `Get-RotaWeekGaps`, `Get-RotaPopcountCombinations`, `Get-RotaVariableComponents`, `Get-RotaVariableCosts`, `Get-RotaOfficeCombinations`, `Get-RotaOfficeCapacityGroups`, `Join-RotaComponents` |
| `src\Constraints.ps1` | `Test-RotaSchedule` |
| `tests\TestHelpers.ps1` | `Get-RotaDayLoadsFromMasks` |

If you add a function that returns a collection, wrap it the same way — and add it here.

---

## Other things worth knowing

**Run the tests before and after.** `Invoke-Pester .\tests -Output Normal` — 154 tests, about
25 seconds. Add `-ExcludeTagFilter Slow` to skip the ones that solve the real roster.

**Solve the real roster after touching the solver.** The synthetic test fixture solves in a
second and never approaches the time budget, so it cannot see a search that degrades until it
times out. `.\Invoke-Rota.ps1 -NoExcel` should finish in about 8 seconds with score 1470, zero
hard violations and `TimedOut` false. `Integration.Tests.ps1` asserts this, but run it
yourself too — a passing suite with a 490-second solve has happened.

**`Search-RotaComponent` and `Join-RotaComponents` are exported but low-level.** They expect
marshalled flat arrays. Prefer driving `Invoke-RotaSolver`.

**Rules live in one place.** Adding a constraint means writing one evaluator and adding one
line to the registry in `src\Constraints.ps1`. The C# kernel in `src\SearchKernel.ps1` knows
nothing about rota rules and must stay that way — it takes pre-filtered domains and a capacity
model, and `Constraints.ps1` scores the winner.

**The kernel is not the slow part.** PowerShell setup is roughly 3% of a run. Wins come from
searching less, not from rewriting more in C#.

**Write examples against the synthetic fixture, not the real roster.**
`New-TestRotaConfig` in `tests\TestHelpers.ps1` solves in about a second and takes parameters
for the rule you are exercising, so a test can bend one thing without rebuilding the roster.
`config\roster.json` is the live one — it belongs to the restaurant, its figures are asserted
in `Config.Tests.ps1`, and editing it to make a test pass will fail those assertions.
