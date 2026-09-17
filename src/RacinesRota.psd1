@{
    RootModule        = 'RacinesRota.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b1e6a4c2-7d34-4f58-9a21-3c8e5f0d6b79'
    Author            = 'Racines'
    Description       = 'Restaurant rota engine: generates a repeating multi-week schedule from a declarative roster, validates it against the house rules, and exports JSON and Excel.'
    PowerShellVersion = '7.0'
    FunctionsToExport = '*'
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags = @('rota', 'scheduling', 'rostering', 'constraint-solver')
        }
    }
}
