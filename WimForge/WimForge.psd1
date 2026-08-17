# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

@{
    RootModule            = 'WimForge.psm1'
    ModuleVersion         = '1.0.0'
    GUID                  = 'a4f3c1b2-8d55-4c17-9e0a-6b2f7d3e51c8'
    Author                = 'Paul Admiraal'
    CompanyName           = ''
    Copyright             = '(c) 2026 Paul Admiraal. Released under the MIT licence.'
    Description           = 'Build, service, publish and validate a single Windows image covering many hardware models. WIM servicing, a driver library harvested from real machines, offline updates and customisation, WinPE boot images, WDS publishing, reference VM management, USB media and post-deployment validation.'

    # Windows PowerShell 5.1 on purpose. The DISM module is in-box here and runs
    # natively; under PowerShell 7 it loads through the WinPSCompatSession shim,
    # which is where long-running mount operations intermittently fail. 5.1 is
    # also STA by default, which WinForms requires.
    PowerShellVersion     = '5.1'
    CompatiblePSEditions  = @('Desktop')

    FunctionsToExport = @(
        # Configuration and housekeeping
        'Get-WfConfig'
        'Set-WfConfig'
        'Get-WfConfigPath'
        'Get-WfDefaultConfig'
        'Get-WfSuggestedRoot'
        'Get-WfWorkspaceOption'
        'Test-WfMountPath'
        'Set-WfWorkspaceRoot'
        'Initialize-WfWorkspace'
        'Test-WfSetupRequired'
        'Test-WfEnvironment'
        'Test-WfUpdateAgent'
        'Test-WfDefenderExclusion'
        'Test-WfElevated'
        'Start-WfElevated'
        'Get-WfImageInventory'
        'Get-WfHistory'
        'Write-WfHistory'

        # Branding
        'Get-WfAbout'
        'Get-WfBannerArt'
        'Show-WfBanner'
        'Register-WfLogSink'
        # Exported so front-ends and job bodies can log into the same stream
        'Write-WfLog'

        # Core servicing
        'Get-WfImageInfo'
        'Get-WfImageReport'
        'Mount-WfImage'
        'Dismount-WfImage'
        'Get-WfCurrentMount'
        'Invoke-WfWithMount'
        'Repair-WfMount'
        'Add-WfUpdate'
        'Invoke-WfUpdateInject'
        'Invoke-WfCleanup'
        'Export-WfImage'
        'Invoke-WfServicingRun'

        # Driver library
        'Export-WfModelDriver'
        'Get-WfDriverLibrary'
        'Remove-WfModelDriver'
        'Remove-WfDuplicateDriver'
        'Add-WfDriver'
        'Compare-WfDriver'

        # Boot image and publishing
        'Add-WfBootDriver'
        'Publish-WfImage'

        # Your own software inside WinPE, and the script that starts it
        'Get-WfAdkWinPeRoot'
        'Get-WfPeLaunchCommand'
        'Enable-WfPeLegacyJScript'
        'New-WfPeMenuHta'
        'Get-WfPeOptionalComponent'
        'Add-WfPeOptionalComponent'
        'Set-WfPeScratchSpace'
        'Add-WfPeTool'
        'Get-WfPeTool'
        'New-WfPeStartnet'
        'Set-WfPeShell'
        'Get-WfPeReport'

        # Installation media -- the Setup refresh that servicing boot.wim owes
        'Get-WfMediaSetupIndex'
        'Update-WfMediaSetupFile'

        # Device lockdown and the first boot
        'Get-WfLockdownFeature'
        'Enable-WfLockdownFeature'
        'Set-WfCustomLogon'
        'Set-WfShellLauncher'
        'Set-WfFirstBootScript'
        'New-WfLockdownFirstBoot'

        # The lists behind every "pick one" -- so nothing is typed from memory
        'Get-WfTimeZoneChoice'
        'Get-WfLocaleChoice'
        'Get-WfKeyboardChoice'
        'Get-WfUiLanguageChoice'
        'Get-WfInputLocaleValue'
        'Get-WfKeyboardFilterChoice'

        # Regional identity and local policy
        'Get-WfImageLocale'
        'Set-WfImageLocale'
        'Set-WfOemInformation'
        'Set-WfLocalPolicy'

        # One image, many countries -- presets, the GeoID unattend cannot set,
        # and the WinPE-records-it / first-boot-applies-it pair
        'Get-WfRegionPreset'
        'Get-WfRegionAnswerXml'
        'Set-WfImageGeoId'
        'Set-WfImageRegion'
        'Write-WfRegionAnswer'
        'Get-WfRegionAnswer'
        'New-WfRegionPeScript'
        'New-WfRegionFirstBoot'

        # Taking things out, and the recovery image
        'Get-WfProvisionedApp'
        'Remove-WfProvisionedApp'
        'Get-WfImageCapability'
        'Remove-WfImageCapability'
        'Disable-WfImageFeature'
        'Add-WfRecoveryDriver'

        # Getting a terminal back to the image it shipped with
        'Get-WfRecoveryStatus'
        'Set-WfRecoveryImage'
        'Set-WfResetConfig'
        'Add-WfResetCustomization'
        'New-WfRecoveryBootImage'
        'New-WfRecoveryFirstBoot'

        # Offline customisation
        'Invoke-WfRegistryEdit'
        'Copy-WfPayload'
        'Import-WfCertificate'
        'Set-WfUnattend'
        'Test-WfUnattend'
        'Add-WfCapability'

        # Reference VM -- what the host already knows, so it is picked not typed
        'Get-WfVmHostFact'
        'Get-WfVmSwitchChoice'
        'Get-WfVmIsoChoice'
        'Get-WfVmSizeChoice'
        'Get-WfVmNameSuggestion'

        # Reference VM
        'Test-WfHyperV'
        'Test-WfVmHostIsRemote'
        'Invoke-WfVmHostCommand'
        'Set-WfGuestCredential'
        'Set-WfHostCredential'
        'New-WfReferenceVm'
        'Get-WfReferenceVm'
        'Start-WfReferenceVm'
        'Stop-WfReferenceVm'
        'New-WfReferenceCheckpoint'
        'Get-WfReferenceCheckpoint'
        'Restore-WfReferenceCheckpoint'
        'Remove-WfReferenceCheckpoint'
        'Copy-WfToReferenceVm'
        'Invoke-WfReferenceCommand'
        'Initialize-WfReferenceBuild'
        'Get-WfReferenceVhdPath'
        'Invoke-WfReferenceCapture'

        # Making DISM's failures mean something
        'Get-WfDismError'
        'Get-WfDismLogTail'
        'Format-WfDismError'

        # Updates from the Microsoft Update Catalog
        'Get-WfUpdateProductChoice'
        'Get-WfUpdateArchitectureChoice'
        'Get-WfImageUpdateTarget'
        'Find-WfUpdate'
        'Get-WfUpdateDownloadUrl'
        'Get-WfUpdateDownloadInfo'
        'Get-WfUpdateSet'
        'Get-WfReleaseKind'
        'Save-WfUpdate'
        'Get-WfLatestUpdate'
        'Get-WfUpdateFolder'
        'Remove-WfUpdate'

        # Display languages: a library on disk, and putting them in an image
        'Import-WfLanguagePack'
        'Get-WfLanguageLibrary'
        'Get-WfImageLanguage'
        'Add-WfLanguage'

        # Reference image built from clean media, in Microsoft's documented order
        'New-WfReferenceImage'
        'Expand-WfUpdatePackage'
        'Get-WfLcuServicingStack'
        'Get-WfBuildFamily'

        # Build operations
        'New-WfCapture'
        'New-WfUsbMedia'
        'Test-WfDeployedMachine'
    )

    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()

    PrivateData = @{
        PSData = @{
            # PowerShell Gallery tags. No spaces allowed, so the multi-word
            # ones are run together the way the Gallery's own search expects.
            # These are what someone types when they have the problem this
            # solves, not what the project calls itself.
            Tags         = @(
                'DISM','WIM','Imaging','Deployment','OSD','WDS','PXE','MDT',
                'WinPE','BootImage','Drivers','DriverInjection','Sysprep',
                'Unattend','AuditMode','ReferenceImage','ImageServicing',
                'WindowsUpdate','CumulativeUpdate','UpdateCatalog',
                'LanguagePack','FeaturesOnDemand','Localization',
                'Kiosk','UWF','ShellLauncher','IoTEnterprise','LTSC',
                'HyperV','Windows','Windows10','Windows11','WindowsServer',
                'PowerShell','Automation'
            )
            LicenseUri   = 'https://github.com/centauri/wimforge/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/centauri/wimforge'
            ReleaseNotes = 'First public release.'
        }
    }
}
