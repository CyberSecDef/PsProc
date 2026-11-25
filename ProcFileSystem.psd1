@{
    RootModule           = 'ProcFileSystem.psm1'
    ModuleVersion        = '0.2.0'
    GUID                 = '6f0c7e9a-3b2d-4d8e-9a51-2c4f7b1e8d03'
    Author               = 'Robert Weber'
    Copyright            = '(c) 2026 Robert Weber. MIT License.'
    Description          = 'A Linux-style /proc pseudo-filesystem (proc: drive) for Windows, built on SHiPS.'
    PowerShellVersion    = '7.0'
    CompatiblePSEditions = @('Core')

    # SHiPS must be loaded before the module's classes are parsed, because they derive
    # from SHiPSDirectory/SHiPSLeaf. RequiredModules guarantees that ordering.
    RequiredModules      = @('SHiPS')

    FunctionsToExport    = @('Mount-ProcDrive', 'Dismount-ProcDrive')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData          = @{
        PSData = @{
            Tags       = @('proc', 'procfs', 'SHiPS', 'provider', 'Windows', 'Linux')
            LicenseUri = 'https://github.com/CyberSecDef/PsProc/blob/main/LICENSE'
            ProjectUri = 'https://github.com/CyberSecDef/PsProc'
        }
    }
}
