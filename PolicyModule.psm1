<#
.SYNOPSIS

Collection of functions that need to be reused (eg in deployment and diff)
#>

Function Convert-HexToByteArray {

    [cmdletbinding()]

    param(
        [parameter(Mandatory = $true)]
        [String]
        $HexString
    )

    if ($HexString.Length % 2 -eq 0) {
        $bytes = [byte[]]::new($HexString.Length / 2)
    }
    else {
        $bytes = [byte[]]::new([int]($HexString.Length / 2) + 1)
    }

    For ($i = 0; $i -lt $HexString.Length; $i += 2) {
        if ($i + 2 -gt $HexString.Length) {
            $bytes[$i / 2] = [convert]::ToByte($HexString.Substring($i, 1), 16)
        }
        else {
            $bytes[$i / 2] = [convert]::ToByte($HexString.Substring($i, 2), 16)
        }
    }

    $bytes
}

Function Encode-Sha1Base64 {
    <#
    .SYNOPSIS
        - Generate the longest hash possible using SHA1 encoded in base64 for the number of characters supplied for Azure Resource Naming.
        It generates a hash from the string supplied in hexadecimal, then truncate it and encode in base64 to profit space in cases where all base64 are valid
        1 bytes  -> 2 hex characters
        3 bytes -> 4 base64 characters

        It replaces "/" valid base64 character for "_" invalid base64 character to be compatible with Azure resource names.
        It replaces "+" valid base64 character for "." invalid base64 character to be compatible with Azure resource names.


    .NOTES
        [date]    [author]                        [notes]
        20210205  f.palomino.benito@avanade.com - Create to generate policyassingment name that only allows 24 characters
    .PARAMETER String
        The String which hash is calculated

    .PARAMETER Ncharacters
        Nº of characters in base64 that will be generated for the hash. Only allow even values and limited from 2 to 26 (Because SHA1 generates a 40 hexcharacter hash)

    .EXAMPLE
        # Generate a 8 character in base64 hash from "Loremipsum" string
        Encode-Sha1Base64 -String "Loremipsum" -Ncharacters 8
    #>

    [cmdletbinding()]
    param(
        [parameter(Mandatory = $true)]
        [String]
        $String,
        [parameter(Mandatory = $true)]
        [int]
        [ValidateRange(2, 26)]
        [ValidateScript( { $_ % 2 -eq 0 })] # Even number
        $Ncharacters
    )
    [int]$nhexcharacters = $Ncharacters * 1.5

    if ($Ncharacters % 4 -ne 0) {
        $nhexcharacters = $nhexcharacters - 1
    }
    $hexstring = (Get-FileHash -InputStream ([IO.MemoryStream]::new([byte[]][char[]]$String)) -Algorithm SHA1).Hash.Substring(0, $nhexcharacters)
    $bytes = Convert-HexToByteArray -HexString $hexstring
    $result = [Convert]::ToBase64String($bytes)
    $result = $result.Replace('=', '')  #Remove padding
    $result = $result.Replace('/', '_') #/ character is not allowed in azure resource name.
    $result = $result.Replace('+', '.') #+ character is not allowed in azure resource name.
    $result
}

Function Generate-PolicyAssignmentName {
    <#
    .SYNOPSIS
        - Generate name for policy assignment based on policy definition, scope and displayName in format
        It replaces "/" valid base64 character for "_" invalid base64 character to be compatible with Azure resource names.
        It replaces "+" valid base64 character for "." invalid base64 character to be compatible with Azure resource names.

    .NOTES
        [date]    [author]                        [notes]
        20210209  patrik.kadlcik@accenture.com    - Create to generate policyassingment name that only allows 24 characters

    .PARAMETER PolicyAssignmentObject
        The object of policyAssignment from PolicyAssignments.json

    .PARAMETER topLevelManagementGroupPrefix
        Prefix for

    .EXAMPLE
        # Generate a 8 character in base64 hash from "Loremipsum" string
        .\Encode-Sha1Base64 -String "Loremipsum"-Ncharacters 8
#>

[CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        $policyAssignmentObject
    )

    if ($null -eq $policyAssignmentObject.scope) {
        Write-Error "Scope property is missing in policyAssignment object, add it, for example by using Select-Object"
    }

    $definition = "";
    if ($null -ne $policyAssignmentObject.policyDefinition) {
        $definition = $definition + $policyAssignmentObject.policyDefinition
    }
    elseif ($null -ne $policyAssignmentObject.policySetDefinition) {
        $definition = $definition + $policyAssignmentObject.policySetDefinition
    }

    $scopeHash = Encode-Sha1Base64 $policyAssignmentObject.Scope 6;
    $definitionHash = Encode-Sha1Base64 $definition 6
    $displayNameHash = Encode-Sha1Base64 $policyAssignmentObject.displayName 6

    Write-Output "ALZ-$scopeHash-$definitionHash-$displayNameHash"
}

function Initialize-PolicyArrays {
    [CmdletBinding()]
    param (
        $topLevelManagementGroupPrefix
    )
    $policiesBuiltin = Get-AzPolicyDefinition -Builtin
    $policiesCustom = Get-AzPolicyDefinition -ManagementGroupName $topLevelManagementGroupPrefix -Custom

    $policiesSetBuiltin = Get-AzPolicySetDefinition -Builtin
    $policiesSetCustom = Get-AzPolicySetDefinition -ManagementGroupName $topLevelManagementGroupPrefix -Custom

    New-Variable -Name AllPolicies -Value ($policiesBuiltin + $policiesCustom) -Scope Script -Force
    New-Variable -Name AllPolicySets -Value ($policiesSetBuiltin + $policiesSetCustom) -Scope Script -Force
}

function Get-ManagedIdentitiesRequiredRoles {
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline, Mandatory)]$PolicyAssignments,
        $ManagementGroupId
    )

    if ($null -eq $AllPolicies) {
        Write-Error "No policies loaded. Run 'Initialize-PolicyArrays `$topLevelManagementGroupPrefix' First"
        return
    }

    $roleAssignments = @()

    $PolicyAssignments
    | Where-Object { ($_.useIdentity -eq $true) -and ($_.uami -eq '') }
    | ForEach-Object {
        $policyAssignmentName = $_.name
        $policyId = $_.policyDefinitionId


        #if it is a policy, read the definition and add all required roles
        if ($null -ne $_.policyDefinition -or $_.type -eq "PolicyDefinition") {

            $policyDefinition = $AllPolicies  | Where-Object { $_.policyDefinitionId -eq $policyId }
            if ($null -ne $policyDefinition.Properties.PolicyRule.then.details.roleDefinitionIds) {
                foreach ($role in $policyDefinition.Properties.PolicyRule.then.details.roleDefinitionIds) {
                    $roleAssignment = @{
                        roleDefinitionId = $role;
                        name             = $policyAssignmentName;
                    }
                    $roleAssignments += $roleAssignment
                }
            }
        }
        else {
            #if it is a policySet/initiative, read the definition of all policies and add required roles checking that they have not been already added to $roleAssignments
            $policySetId = $_.policyDefinitionId
            $policyDefinitionSet = $AllPoliciesSets  | Where-Object { $_.PolicySetDefinitionId -eq $policySetId }
            foreach ($policy in $policyDefinitionSet.Properties.PolicyDefinitions) {
                $policyDefinition = $AllPolicies  | Where-Object { $_.PolicyDefinitionId -eq $policy.policyDefinitionId }
                if ($null -ne $policyDefinition.Properties.PolicyRule.then.details.roleDefinitionIds) {
                    foreach ($role in $policyDefinition.Properties.PolicyRule.then.details.roleDefinitionIds) {

                        if ($null -eq ($roleAssignments | Where-Object { ($_.roleDefinitionId -eq $role) -and ($_. name -eq $policyAssignmentName) })) {
                            $roleAssignment = @{
                                roleDefinitionId = $role;
                                name             = $policyAssignmentName;
                            }
                            $roleAssignments += $roleAssignment
                        }

                    }
                }
            }

        }
    }
    return $roleAssignments
    <#
    $roleAssignmentOverrideParameters = @{
        ManagementGroupId    = $ManagementGroupId
        Location             = $Location
        locationFromTemplate = $Location
        roleAssignments      = $roleAssignments
    }

    ."$PSScriptRoot\035_DeployTemplate.ps1" `
        -deploymentType 'ManagementGroupDeployment' `
        -overrideParameters $roleAssignmentOverrideParameters `
        -templateFilePath ".\reference\armTemplates\policies\policyAssignment.json" `
        -parametersFilePath ".\reference\armTemplates\policies\policyAssignment.parameters.json" `
        -test $test
#>
}

Export-ModuleMember -Function *