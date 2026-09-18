#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
#
# ConfigExcel.Tests.ps1 -- the roster as an editable workbook, and back again.
#
# This path had no tests at all and did not work: Import-RotaConfigExcel returned nothing,
# because `[int](if ...)` is not a cast in PowerShell and the whole function died on it. A
# round-trip is the only assertion that catches that class of fault, and it is also the only
# thing that notices when a new config field is added to the JSON but not to the workbook --
# which loses it silently, without an error, the first time somebody edits the sheet.
#
# Tagged Slow: it writes a real .xlsx and needs ImportExcel.

# Pester runs discovery and execution in separate scopes, so this is needed in both: in the
# file body for -Skip (evaluated during discovery) and again in BeforeAll for the tests
# themselves. Set in only one place, it is either always skipped or unset at run time.
$script:HasExcel = [bool](Get-Module -ListAvailable -Name ImportExcel)

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-RotaModuleForTests
    $script:HasExcel = [bool](Get-Module -ListAvailable -Name ImportExcel)
    $script:RosterPath = Join-Path (Get-RotaRepoRoot) 'config\roster.json'
    $script:Path = $null
}

Describe 'Roster survives a trip through the workbook' -Tag 'Slow' {
    BeforeAll {
        if ($script:HasExcel) {
            $script:Source = Import-RotaConfig -Path $script:RosterPath
            $script:Path = Join-Path ([System.IO.Path]::GetTempPath()) "rota-criteria-$([guid]::NewGuid()).xlsx"
            Export-RotaConfigExcel -Config $script:Source -Path $script:Path | Out-Null
            $script:Back = Import-RotaConfigExcel -Path $script:Path
        }
    }
    AfterAll {
        if ($script:Path -and (Test-Path -LiteralPath $script:Path)) { Remove-Item -LiteralPath $script:Path -Force }
    }


    It 'imports at all' -Skip:(-not $script:HasExcel) {
        $script:Back | Should -Not -BeNullOrEmpty
        @($script:Back.staff).Count | Should -Be @($script:Source.staff).Count
    }

    It 'comes back valid' -Skip:(-not $script:HasExcel) {
        @(Test-RotaConfig -Config $script:Back) | Should -BeNullOrEmpty
    }

    It 'keeps every solved person''s terms' -Skip:(-not $script:HasExcel) {
        foreach ($p in $script:Source.SolvedStaff) {
            $b = $script:Back.StaffByName[$p.name]
            $b | Should -Not -BeNullOrEmpty -Because "$($p.name) should survive the round trip"
            $b.RepeatMode | Should -Be $p.RepeatMode -Because "$($p.name) repeat mode"
            $b.AvailableMask | Should -Be $p.AvailableMask -Because "$($p.name) availability"
            (Get-RotaProperty -Object $b -Name 'preferredConsecutiveDaysOff' -Default 0) |
                Should -Be (Get-RotaProperty -Object $p -Name 'preferredConsecutiveDaysOff' -Default 0) -Because "$($p.name) preferred days off"
            for ($w = 1; $w -le [int]$script:Source.meta.cycleWeeks; $w++) {
                (Get-RotaProperty -Object $b.WeekSpec[$w] -Name 'preferenceWeight' -Default 0) |
                    Should -Be (Get-RotaProperty -Object $p.WeekSpec[$w] -Name 'preferenceWeight' -Default 0) -Because "$($p.name) week $w preference weight"
                [int]$b.WeekSpec[$w].shifts | Should -Be ([int]$p.WeekSpec[$w].shifts) -Because "$($p.name) week $w shifts"
            }
        }
    }

    It 'keeps the fixed rows' -Skip:(-not $script:HasExcel) {
        foreach ($p in $script:Source.FixedStaff) {
            $b = $script:Back.StaffByName[$p.name]
            $b.FixedByDay.Count | Should -Be $p.FixedByDay.Count -Because "$($p.name) fixed days"
        }
    }

    It 'keeps coverage, including per-service overrides' -Skip:(-not $script:HasExcel) {
        $script:Back.coverage.requiredPerService | Should -Be $script:Source.coverage.requiredPerService
        $a = Get-RotaServices -Config $script:Source
        $b = Get-RotaServices -Config $script:Back
        for ($i = 0; $i -lt $a.Count; $i++) { $b[$i].Required | Should -Be $a[$i].Required }
    }

    It 'solves to the same schedule either way' -Skip:(-not $script:HasExcel) {
        $fromJson = Invoke-RotaSolver -Config $script:Source
        $fromXlsx = Invoke-RotaSolver -Config $script:Back
        $fromXlsx.Score | Should -Be $fromJson.Score
    }
}

Describe 'Reading a day map whatever shape it arrives in' {
    # JSON gives PSCustomObjects; the importer builds hashtables. Asking a hashtable for
    # PSObject.Properties returns Keys/Values/Count, not the days -- an empty map and no
    # error, which is how availability quietly became "nothing at all".
    It 'reads a PSCustomObject' {
        $pairs = @(Get-RotaNameValuePairs -Map ([pscustomobject]@{ Lundi = @('Lunch'); Mardi = @('Dinner') }))
        @($pairs | ForEach-Object Name | Sort-Object) | Should -Be @('Lundi', 'Mardi')
    }
    It 'reads a hashtable' {
        $pairs = @(Get-RotaNameValuePairs -Map @{ Lundi = @('Lunch'); Mardi = @('Dinner') })
        @($pairs | ForEach-Object Name | Sort-Object) | Should -Be @('Lundi', 'Mardi')
    }
    It 'gives the same availability mask from either shape' {
        $asObject = New-TestRotaConfig
        $asObject.staff[1] | Add-Member available ([pscustomobject]@{ Lundi = @('Lunch', 'Dinner') }) -Force
        $asHash = New-TestRotaConfig
        $asHash.staff[1] | Add-Member available @{ Lundi = @('Lunch', 'Dinner') } -Force
        $a = ConvertTo-RotaNormalisedConfig -Config $asObject
        $b = ConvertTo-RotaNormalisedConfig -Config $asHash
        $b.staff[1].AvailableMask | Should -Be $a.staff[1].AvailableMask
        $b.staff[1].AvailableMask | Should -Not -Be 0
    }
    It 'returns nothing for a missing map, rather than throwing' {
        @(Get-RotaNameValuePairs -Map $null) | Should -BeNullOrEmpty
    }
}
