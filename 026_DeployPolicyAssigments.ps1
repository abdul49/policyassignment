<#
    .SYNOPSIS
        - deployment for policy assignments
    .NOTES
        [date]    [author]                      [notes]
        20201118  viliam.batka@accenture.com    - initial version
        20201202  f.palomino.benito@avanade.com - Refactor + Network policy assigments
        20210127 milan.marusin@accenture.com - Refactor to process all jsons in folder

        # https://docs.microsoft.com/en-us/azure/azure-resource-manager/templates/deploy-to-tenant?tabs=azure-cli#required-access

    .PARAMETER topLevelManagementGroupPrefix
        topLevelManagementGroupPrefix where policy definitions will be deployed.

    .PARAMETER location
        Location for the deployment. The location of the deployment is separate from the location of the resources you deploy.

    .PARAMETER test
        Switch variable if it is true, it will not deploy anything, it will test the deployment using Test-AzManagementGroupDeployment.

    .EXAMPLE
        # deploy policy assigment on a Management Group with Id "RWE-ALZP-ROOT-VB" using West Europe resources to run the deployment.
        .\026_DeployPolicyAssigments.ps1 -topLevelManagementGroupPrefix "RWE-ALZP-ROOT-VB" -location "westeurope"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    $topLevelManagementGroupPrefix,
    [Parameter(Mandatory)]
    $location,
    $test = $false,
    [switch] $skipPolicyAssignmentTest,
    [Parameter(Mandatory)]
    $environment,
    [Parameter(Mandatory)]
    $subscriptionId, # e.g. 'e78cb895-0312-4d35-8894-5bb40eeb8a02',  #  'ZC03X-RWEALZDEV-PL03'
    $targetOrgId = "c03", # (part of prefix)target environemnt 3 char naming convention
    $targetPlatformId = "lzp", # target subscription platform usage
    $region = "euw1"
)

Write-Output "... > Running '$($MyInvocation.MyCommand.Name)'";

Import-Module "$PSScriptRoot/PolicyModule.psm1" -DisableNameChecking;

# Cache all policydefinitions to be used directly by functions instead of create one request for each policy definition needed.
Initialize-PolicyArrays $topLevelManagementGroupPrefix

$assignments = Get-ChildItem -path "$PSScriptRoot\reference\policy" -Filter *.json | ForEach-Object {
    # Remove Comments
    $content = ($_ | Get-Content) -replace '(?m)(?<=^([^"]|"[^"]*")*)//.*' -replace '(?ms)/\*.*?\*/';

    # Process Tokens
    $tokens = @{
        "%ORG%"      = $targetOrgId;
        "%PLATFORM%" = $targetPlatformId;
        "%REGION%"   = $region;
        "%ENV%"      = $environment;
        "%SUBID%"    = $subscriptionId;
    }
    foreach ($token in $tokens.GetEnumerator()) {
        $content = $content -replace $token.Name, $token.Value;
    }
    $content | ConvertFrom-Json
} | Select-Object -Property `
    policyDefinition,
    PolicySetDefinition,
    displayName,
    managementGroupIdSuffix,
    @{Name = 'name'; Expression = {
            # Get unique, consistent 24 character name for assignment from scope + definition
            $_ | Select-Object -Property *, @{Name = "Scope"; Expression = { $topLevelManagementGroupPrefix + $_.managementGroupIdSuffix } } | Generate-PolicyAssignmentName
        }
    },
    @{Name = 'policyDefinitionId'; Expression = {
            if ($_.policyDefinition -like "/providers/Microsoft.Authorization/*") {
                return $_.policyDefinition
            }
            if ($_.policySetDefinition -like "/providers/Microsoft.Authorization/*") {
                return $_.policySetDefinition
            }
            if ($_.policyDefinition -ne $null) {
                return "/providers/Microsoft.Management/managementGroups/$topLevelManagementGroupPrefix/providers/Microsoft.Authorization/policyDefinitions/" + $_.policyDefinition
            }
            elseif ($_.policySetDefinition -ne $null) {
                return "/providers/Microsoft.Management/managementGroups/$topLevelManagementGroupPrefix/providers/Microsoft.Authorization/policySetDefinitions/" + $_.policySetDefinition
            }
            Write-Error "Neither Policy nor PolicySet is defined on assignment"
        }
    },
    @{Name = 'parameters'; Expression = {
            $parameters = $_.parameters
            $parameters | Get-Member -MemberType NoteProperty *___ID | ForEach-Object {
                $propertyName = $_.Name -replace "___ID", ""
                $i = $_.Name;
                $resource = Get-AzResource -Name $parameters.$i
                $parameters | Add-Member -MemberType NoteProperty -Name $propertyName -Value $resource.Id
            }
            $parameters.PsObject.Properties | ForEach-Object {
                $i = $_.Name
                $parameters.$i = [PSCustomObject]@{value = $_.Value }
            }
            $parameters | Select-Object -ExcludeProperty *___ID
        }
    },
    @{Name = 'notScopes'; Expression = { 
            $notScopes = $_.notScopes 
            $notScopes | Select-Object
        } 
    },
    @{Name = 'useIdentity'; Expression = { $_.useIdentity -eq $true } },
    @{Name = 'uami'; Expression = { 
            if ($_.uami) {
                return $_.uami
            } else {
                return ''
            }
        } 
    }

$assignments `
| Group-Object managementGroupIdSuffix
| ForEach-Object {

    $policyAssignments = @($_.Group | Where-Object { $_.PolicyDefinitionId -ne $null } | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashTable) # necessary for arm teplate to recognize the properties. Force array to avoid bug when only one item is returned
    $roleAssignments = Get-ManagedIdentitiesRequiredRoles `
        -PolicyAssignments $policyAssignments `
        -ManagementGroupId ($topLevelManagementGroupPrefix + $_.Name)

    $policyAssignmentOverrideParameters = @{
        ManagementGroupId    = ($topLevelManagementGroupPrefix + $_.Name)
        Location             = $location
        locationFromTemplate = $location
        policyAssignments    = $policyAssignments
    }

    "RoleAssignments For $($policyAssignmentOverrideParameters.ManagementGroupId):"
    $roleAssignments

    ."$PSScriptRoot\035_DeployTemplate.ps1" `
        -deploymentType 'ManagementGroupDeployment' `
        -overrideParameters $policyAssignmentOverrideParameters `
        -templateFilePath "$PSScriptRoot\reference\armTemplates\policies\policyAssignment.json" `
        -parametersFilePath "$PSScriptRoot\reference\armTemplates\policies\policyAssignment.parameters.json" `
        -test $test

    #Add roles required to policy assignment system identity.
    if ($null -ne $roleAssignments) {

        #Workaround until removing policy assignment removes the managed a identity and their roles assigneds
        #Remove role assigments that are not related with any object
        $managementGrouResourceId = (Get-AzManagementGroup -GroupId ($topLevelManagementGroupPrefix + $_.Name)).Id
        Get-AzRoleAssignment -Scope $managementGrouResourceId `
        | Where-Object { $_.ObjectType -eq "Unknown" } `
        #| Remove-AzRoleAssignment

        #Wait for few seconds to allow system managed id creation. The policyAssignmentSystemIdentityRoles ARM template references 
        #'principalId' in the next step and if its not available at that time. 
        #This is a workaround until we find a way to add a condition to check if the principalId exists.
        Start-Sleep -Seconds 45

        $policyAssignmentOverrideParameters = @{
            ManagementGroupId    = ($topLevelManagementGroupPrefix + $_.Name)
            Location             = $location
            locationFromTemplate = $location
            roleAssignments      = $roleAssignments
            managementGroupName  = ($topLevelManagementGroupPrefix + $_.Name)

        }
        ."$PSScriptRoot\035_DeployTemplate.ps1" `
            -deploymentType 'ManagementGroupDeployment' `
            -overrideParameters $policyAssignmentOverrideParameters `
            -templateFilePath "$PSScriptRoot\reference\armTemplates\policies\policyAssignmentSystemIdentityRoles.json" `
            -parametersFilePath "$PSScriptRoot\reference\armTemplates\policies\policyAssignmentSystemIdentityRoles.parameters.json" `
            -test $test
    }
}