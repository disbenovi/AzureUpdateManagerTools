<#
.SYNOPSIS
    Runbook that automatically creates one or more maintenance configurations in Azure Update Manager, based on update packages already installed on an initial environment (Pre/Dev/Test/QA).

.DESCRIPTION 
    This Runbook uses Azure Update Manager installation results to query the latest update packages installed on a set of machines, and based on a maintenance configuration already deployed, 
    and creates one or more maintenance configurations based on the next stages definitions set as a parameter.
    This runbook requires the Az.Accounts, Az.Resources and Az.ResourceGraph Powershell modules.

    These parameters are needed:
        .PARAMETER MaintenanceConfigurationId
            ARM Id of the Maintenance Configuration to be used as a reference to create deployments for further stages
        .PARAMETER NEXTSTAGEPROPERTIEJSON
            JSON format parameter that will define the scope of the new maintenance configurations. Next an example of a this parameter:
                [
                    {
                        "stageName": "PreProduction-Windows",
                        "offsetDays": 7,
                        "scope": [
                            "/subscriptions/00000000-0000-0000-0000-000000000000",
                            "/subscriptions/00000000-0000-0000-0000-000000000001"
                        ],
                        "tagSettings": {
                            "tags": {
                                "UpdateManagementStage": [
                                    "PreProduction"
                                ],
                                "NeedReboot": [
                                    "True"
                                ]
                            },
                            "filterOperator": "All"
                        },
                        "locations": []
                    },
                    { 
                        "stageName": "Production-Windows",
                        "offsetDays": 14,
                        "scope": [
                            "/subscriptions/00000000-0000-0000-0000-000000000000",
                            "/subscriptions/00000000-0000-0000-0000-000000000001"
                        ],
                        "tagSettings": {
                            "tags": {
                                "UpdateManagementStage": [
                                    "Production"
                                ],
                                "NeedReboot": [
                                    "True"
                                ]
                            },
                            "filterOperator": "All"
                        },
                        "locations": []
					}
                ]
            The above format is based on two tags already deployed on VMs, one for the update phase of the VMs, and the other for the need of reboot after applying updates.

        And last but not least, the runbook uses an Automation Account Managed Identity, for authentication purposes, with the following permissions:
            - Virtual Machine Contributor on Root MG Scope
            - Reader on Root MG Scope
            - Automation Contributor on the Automation account

.NOTES
    AUTHOR: Helder Pinto and Wiszanyel Cruz
    LAST EDIT: Oct 02, 2023
#>

param(
    [parameter(Mandatory = $true)]
    [string]$MaintenanceConfigurationId,

    [parameter(Mandatory = $true)]
    [string]$NextStagePropertiesJson 
)

<#
$NextStagePropertiesJson = @"
[
    {
        "stageName": "windows-phase1-aum-mc",
        "offsetDays": 7,
        "scope": [
            "/subscriptions/dfabc7a1-ca6f-4a95-8a7a-faddb6ef9b7b"
        ],
        "filter": {
            "resourceTypes": [
                "microsoft.compute/virtualmachines"
            ],
            "resourceGroups": [
            ],
            "tagSettings": {
                "tags": {
                    "aum": [
                        "phase1"
                    ],
                    "boundary": [
                        "lab"
                    ]
                },
                "filterOperator": "All"
            },
            "locations": []
        }
    },
    {
        "stageName": "windows-phase2-aum-mc",
        "offsetDays": 14,
        "scope": [
            "/subscriptions/dfabc7a1-ca6f-4a95-8a7a-faddb6ef9b7b"
        ],
        "filter": {
            "resourceTypes": [
                "microsoft.compute/virtualmachines"
            ],
            "resourceGroups": [
            ],
            "tagSettings": {
                "tags": {
                    "aum": [
                        "phase2"
                    ]
                },
                "filterOperator": "All"
            },
            "locations": []
        }
    }
]
"@
#>

function ConvertTo-Hashtable {
    [CmdletBinding()]
    [OutputType('hashtable')]
    param (
        [Parameter(ValueFromPipeline)]
        $InputObject
    )
 
    process {
        if ($null -eq $InputObject) {
            return $null
        }
 
        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            $collection = @(
                foreach ($object in $InputObject) {
                    ConvertTo-Hashtable -InputObject $object
                }
            ) 
            Write-Output -NoEnumerate $collection
        } elseif ($InputObject -is [psobject]) { 
            $hash = @{}
            foreach ($property in $InputObject.PSObject.Properties) {
                $hash[$property.Name] = ConvertTo-Hashtable -InputObject $property.Value
            }
            $hash
        } else {
            $InputObject
        }
    }
}

$ErrorActionPreference = "Stop"

$NextStageProperties = $NextStagePropertiesJson | ConvertFrom-Json

Connect-AzAccount -Identity

$subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" } | ForEach-Object { "$($_.Id)"}

$ARGPageSize = 1000

$installedPackages = @()

$resultsSoFar = 0

Write-Output "Querying for packages to install..."

$argQuery = @"
patchinstallationresources
| where type == 'microsoft.compute/virtualmachines/patchinstallationresults'
| extend maintenanceRunId=tolower(split(properties.maintenanceRunId,'/providers/microsoft.maintenance/applyupdates')[0])
| where maintenanceRunId == '$MaintenanceConfigurationId'
| extend vmId = tostring(split(tolower(id), '/patchinstallationresults/')[0])
| extend osType = tostring(properties.osType)
| extend lastDeploymentStart = tostring(properties.startDateTime)
| extend deploymentStatus = tostring(properties.status)
| join kind=inner (
    patchinstallationresources
    | where type == 'microsoft.compute/virtualmachines/patchinstallationresults/softwarepatches'
    | extend vmId = tostring(split(tolower(id), '/patchinstallationresults/')[0])
    | extend patchName = tostring(properties.patchName)
    | extend patchVersion = tostring(properties.version)
    | extend kbId = tostring(properties.kbId)
    | extend installationState = tostring(properties.installationState)
    | project vmId, installationState, patchName, patchVersion, kbId
) on vmId
| join kind=inner ( 
    resources
    | where type == 'microsoft.maintenance/maintenanceconfigurations'
    | extend maintenanceDuration = tostring(properties.maintenanceWindow.duration)
    | extend rebootSetting = tostring(properties.installPatches.rebootSetting)
    | project maintenanceRunId=tolower(id), maintenanceDuration, rebootSetting, location, mcTags=tostring(tags)
) on maintenanceRunId
| where installationState == 'Installed'
| distinct osType, lastDeploymentStart, maintenanceDuration, patchName, patchVersion, kbId, rebootSetting, location, mcTags
"@

do
{
    if ($resultsSoFar -eq 0)
    {
        $packages = Search-AzGraph -Query $argQuery -First $ARGPageSize -Subscription $subscriptions
    }
    else
    {
        $packages = Search-AzGraph -Query $argQuery -First $ARGPageSize -Skip $resultsSoFar -Subscription $subscriptions
    }
    if ($packages -and $packages.GetType().Name -eq "PSResourceGraphResponse")
    {
        $packages = $packages.Data
    }
    $resultsCount = $packages.Count
    $resultsSoFar += $resultsCount
    $installedPackages += $packages

} while ($resultsCount -eq $ARGPageSize)

Write-Output "$($installedPackages.Count) packages were installed in the latest run for maintenance configuration $MaintenanceConfigurationId."

if ($installedPackages.Count -gt 0) 
{
    $lastDeploymentDate = ($installedPackages | Select-Object -Property lastDeploymentStart -Unique -First 1).lastDeploymentStart
    $maintenanceConfLocation = ($installedPackages | Select-Object -Property location -Unique -First 1).location
    $maintenanceDuration = ($installedPackages | Select-Object -Property maintenanceDuration -Unique -First 1).maintenanceDuration
    $rebootSetting = ($installedPackages | Select-Object -Property rebootSetting -Unique -First 1).rebootSetting
    $tags = ($installedPackages | Select-Object -Property mcTags -Unique -First 1).mcTags
    $windowsPackages = ($installedPackages | Where-Object { $_.osType -eq "Windows" } | Select-Object -Property kbId -Unique).kbId
    $windowsPackageNames = ($installedPackages | Where-Object { $_.osType -eq "Windows" } | Select-Object -Property patchName -Unique).patchName
    $kbNumbersToInclude = "[ ]"
    if ($windowsPackages)
    {
        if ($windowsPackages.Count -eq 1)
        {
            $kbNumbersToInclude = '[ "' + $windowsPackages + '" ]'
        }
        else
        {
            $kbNumbersToInclude = $windowsPackages | ConvertTo-Json
        }
    }
    $linuxPatches = ($installedPackages | Where-Object { $_.osType -eq "Linux" } | Select-Object -Property patchName -Unique).patchName
    $packageNameMasksToInclude = "[ ]"
    $linuxPackages = @()
    foreach ($linuxPatch in $linuxPatches) 
    {
        $linuxPatchVersion = ($installedPackages | Where-Object { $_.osType -eq "Linux" -and $_.patchName -eq $linuxPatch } | Select-Object -Property patchVersion -Unique | Sort-Object -Property patchVersion -Descending).patchVersion
        $linuxPackage = "$linuxPatch=$linuxPatchVersion"
        $linuxPackages += $linuxPackage
    }
    if ($linuxPackages.Count -eq 1)
    {
        $packageNameMasksToInclude = '[ "' + $linuxPackages + '" ]'
    }
    else
    {
        if ($linuxPackages.Count -gt 1)
        { 
            $packageNameMasksToInclude = $linuxPackages | ConvertTo-Json
        }
    }

    Write-Output "Creating $($NextStageProperties.Count) maintenance stages using $($lastDeploymentDate.ToString('u')) as the reference date..." 

    foreach ($stageProperties in $NextStageProperties) 
    {
        $stageStartTime = $lastDeploymentDate.AddDays($stageProperties.offsetDays).ToString("u").Substring(0,16)
        $stageEndTime = $lastDeploymentDate.AddDays($stageProperties.offsetDays+1).ToString("u").Substring(0,16)
        $maintenanceConfName = $stageProperties.stageName
        $maintenanceConfSubId = $MaintenanceConfigurationId.Split("/")[2]
        $maintenanceConfRG = $MaintenanceConfigurationId.Split("/")[4]
        $maintenanceConfDeploymentTemplateJson = @"
        {
            `"`$schema`": `"http://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#`",
            `"contentVersion`": `"1.0.0.0`",
            `"resources`": [
                {
                    `"type`": `"Microsoft.Maintenance/maintenanceConfigurations`",
                    `"apiVersion`": `"2023-04-01`",
                    `"name`": `"$($maintenanceConfName)`",
                    `"location`": `"$maintenanceConfLocation`",
                    `"tags`": $tags,
                    `"properties`": {
                        `"maintenanceScope`": `"InGuestPatch`",
                        `"installPatches`": {
                            `"linuxParameters`": {
                                `"classificationsToInclude`": [
                                    `"Critical`",
                                    `"Security`"
                                ],
                                `"packageNameMasksToExclude`": null,
                                `"packageNameMasksToInclude`": $packageNameMasksToInclude
                            },
                            `"windowsParameters`": {
                                `"classificationsToInclude`": [
                                    `"Critical`",
                                    `"Security`"
                                ],
                                `"kbNumbersToExclude`": null,
                                `"kbNumbersToInclude`": $kbNumbersToInclude
                            },
                            `"rebootSetting`": `"$rebootSetting`"
                        },
                        `"extensionProperties`": {
                            `"InGuestPatchMode`": `"User`"
                        },
                        `"maintenanceWindow`": {
                            `"startDateTime`": `"$stageStartTime`",
                            `"duration`": `"$maintenanceDuration`",
                            `"timeZone`": `"UTC`",
                            `"expirationDateTime`": `"$stageEndTime`",
                            `"recurEvery`": `"Week`"
                        }
                    }
                }
            ]
        }
"@
        Write-Output "Creating/updating $maintenanceConfName maintenance configuration for the following packages:"
        Write-Output $linuxPatches
        Write-Output $windowsPackageNames

        $deploymentNameTemplate = "{0}-" + (Get-Date).ToString("yyMMddHHmmss")
        $templateObject = ConvertFrom-Json $maintenanceConfDeploymentTemplateJson | ConvertTo-Hashtable
        if ((Get-AzContext).Subscription.Id -ne $maintenanceConfSubId)
        {
            Select-AzSubscription -SubscriptionId $maintenanceConfSubId | Out-Null
        }
        New-AzResourceGroupDeployment -TemplateObject $templateObject -ResourceGroupName $maintenanceConfRG -Name ($deploymentNameTemplate -f $maintenanceConfName) | Out-Null
        Write-Output "Maintenance configuration deployed."

        foreach ($scope in $stageProperties.scope)
        {
            $assignmentName = "$($maintenanceConfName)dynamicassignment1"
            $maintenanceConfAssignApiPath = "$scope/providers/Microsoft.Maintenance/configurationAssignments/$($assignmentName)?api-version=2023-04-01"
            $maintenanceConfAssignApiBody = @"
            {
                "properties": {
                  "maintenanceConfigurationId": "/subscriptions/$maintenanceConfSubId/resourceGroups/$maintenanceConfRG/providers/Microsoft.Maintenance/maintenanceConfigurations/$maintenanceConfName",
                  "resourceId": "$scope",
                  "filter": $($stageProperties.filter | ConvertTo-Json -Depth 3)
                }
            }
"@

            Write-Output "Creating/updating $assignmentName maintenance configuration assignment for scope $scope..."
            $response = Invoke-AzRestMethod -Path $maintenanceConfAssignApiPath -Method PUT -Payload $maintenanceConfAssignApiBody

            if ($response.StatusCode -eq 200)
            {
                Write-Output "Maintenance configuration assignment created/updated."
            }
            else
            {
                Write-Output "Maintenance configuration assignment creation/update failed (HTTP $($response.StatusCode))."
                Write-Output $response.Content
            }
        }
    }
}
else 
{
    Write-Output "No need to create further maintenance stages"
}
