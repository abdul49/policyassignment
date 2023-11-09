<#
 .SYNOPSIS
    Deploys a template to Azure

 .DESCRIPTION
    Deploys an Azure Resource Manager template, Management Group template or tenant template

 .NOTES
    [date]    [author]                    [notes]
    20201126  viliam.batka@accenture.com  - initial version

 .PARAMETER subscriptionId
    The subscription id where the template will be deployed.

 .PARAMETER resourceGroupName
    The resource group where the template will be deployed. Can be the name of an existing or a new resource group.

 .PARAMETER resourceGroupLocation
    Optional, a resource group location. If specified, will try to create a new resource group in this location. If not specified, assumes resource group is existing.

 .PARAMETER deploymentName
    The deployment name.

 .PARAMETER templateFilePath
    Optional, path to the template file. Defaults to template.json.

 .PARAMETER parametersFilePath
    Optional, path to the parameters file. Defaults to parameters.json. If file is not found, will prompt for parameter values based on template.
#>

param(
    [Parameter(Mandatory = $false)]
    [string]
    $subscriptionId,

    [Parameter(Mandatory = $false)]
    [string]
    $resourceGroupName,

    [string]
    $resourceGroupLocation,

    [string]
    $templateFilePath = "template.json",

    [string]
    $parametersFilePath = "parameters.json",

    $overrideParameters = @{ },

    # Register RPs
    $resourceProviders = @(),  # @("microsoft.storage", "microsoft.web", 'Microsoft.EventGrid');

    [string]

    [ValidateSet("ManagementGroupDeployment","TenantDeployment","SubscriptionDeployment","ResourceGroupDeployment")]
    $deploymentType = 'N/A',

    $test = $false,

    $deploymentName = ""
)

<#
.SYNOPSIS
    Registers resource providers in subscription
#>
function RegisterRP {
    Param(
        [string]$ResourceProviderNamespace
    )

    $providers = Get-AzResourceProvider  -ProviderNamespace $ResourceProviderNamespace
    if ($providers.RegistrationState -contains 'NotRegistered') {
        Write-Output "Registering resource provider '$ResourceProviderNamespace'";
        Register-AzResourceProvider -ProviderNamespace $ResourceProviderNamespace;
    }
    else {
        Write-Output "Resource provider '$ResourceProviderNamespace', already registered.";
    }
}

#******************************************************************************
# Script body
# Execution begins here
#******************************************************************************
$ErrorActionPreference = "Stop"

# select subscription
if ($subscriptionId) {
    Write-Output "Selecting subscription '$subscriptionId'";
    Select-AzSubscription -SubscriptionID $subscriptionId;
}

if ($resourceProviders.length) {
    Write-Output "Registering resource providers"
    foreach ($resourceProvider in $resourceProviders) {
        RegisterRP($resourceProvider);
    }
}

Write-Output "Parameters:";
$OptionalParameters = New-Object -TypeName Hashtable([StringComparer]::InvariantCultureIgnoreCase)
$overrideParameters.Keys | ForEach-Object {
    $OptionalParameters[$_] = $overrideParameters[$_]
}

Write-Output "Starting '$deploymentType' ... ";
$OptionalParameters
# deployment Name
$local:file = Get-Item -Path "$templateFilePath"
if (-not $local:file) {
    Write-Error "ALZP - deployment aborted. Template File '$templateFilePath' not found!"
}
if (-not $deploymentName) {
    $local:deploymentId = ""
    if ($env:BUILD_BUILDNUMBER) {
        $local:build_sourceversion = "-"
        if ($env:BUILD_SOURCEVERSION) {
            $local:build_sourceversion = ($env:BUILD_SOURCEVERSION).Substring(0,7)
        }
        $local:deploymentId = "B-$($env:BUILD_BUILDNUMBER)-S-$($local:build_sourceversion)"
    } else {

        $local:deploymentId = "T-$((get-Date).ToUniversalTime().ToString("yyMMddhhmmss"))"
    }

    $deploymentName = "ALZP-$($local:file.BaseName)-$($local:deploymentId)"

    if ($deploymentName.length -gt 64) {
        Write-Warning " ... DeploymentName '$deploymentName' will be truncated!"
        $maxFileNameLength = 63 - 6 - $local:deploymentId.length
        if ($maxFileNameLength -gt 0) {
            $deploymentName = "ALZP-$($local:file.BaseName.Substring(0,$maxFileNameLength))-$($local:deploymentId)"
        }
    }
}

Write-Output "... DeploymentName '$deploymentName'";
if ($deploymentName.length -gt 64) {
    $deploymentName = $deploymentName.Substring(0,63)
    Write-Warning " ... truncating long DeploymentName to '$deploymentName'"
}
Write-Output "... TemplateFile: '$templateFilePath'";
Write-Output "... TemplateParameterFile: '$parametersFilePath'";
Write-Output "... test: '$test'";
$ErrorMessages=$null

if ($deploymentType -eq 'ManagementGroupDeployment') {
    # Start manamemeng group deployment
    # https://docs.microsoft.com/en-us/azure/azure-resource-manager/templates/deploy-to-management-group?tabs=azure-powershell

    if ($test) {
        Test-AzManagementGroupDeployment `
            -TemplateFile $templateFilePath `
            -TemplateParameterFile $parametersFilePath `
            @OptionalParameters `
            -Verbose
    }
    else {
        New-AzManagementGroupDeployment `
            -Name $deploymentName `
            -TemplateFile $templateFilePath `
            -TemplateParameterFile $parametersFilePath `
            @OptionalParameters `
            -Verbose `
            -ErrorVariable ErrorMessages
    }
}
elseif( $deploymentType -eq 'TenantDeployment'){
    # Start manamemeng group deployment
    # https://docs.microsoft.com/en-us/azure/azure-resource-manager/templates/deploy-to-management-group?tabs=azure-powershell

    # NOTE $ManagementGroupId supplied in OptionalParameters

    if ($test) {
        Test-AzTenantDeployment `
            -TemplateFile $templateFilePath `
            -TemplateParameterFile $parametersFilePath `
            @OptionalParameters `
            -Verbose
    }
    else {
        New-AzTenantDeployment `
            -Name $deploymentName `
            -TemplateFile $templateFilePath `
            -TemplateParameterFile $parametersFilePath `
            @OptionalParameters `
            -Verbose `
            -ErrorVariable ErrorMessages
    }
}
elseif( $deploymentType -eq 'SubscriptionDeployment'){
    # Start subscription deployment
    # https://docs.microsoft.com/en-us/azure/azure-resource-manager/templates/deploy-to-management-group?tabs=azure-powershell

    if ($test) {
        Test-AzSubscriptionDeployment `
            -TemplateFile $templateFilePath `
            -TemplateParameterFile $parametersFilePath `
            @OptionalParameters `
            -Verbose
    }
    else {
        New-AzSubscriptionDeployment `
            -Name $deploymentName `
            -TemplateFile $templateFilePath `
            -TemplateParameterFile $parametersFilePath `
            @OptionalParameters `
            -Verbose `
            -ErrorVariable ErrorMessages
    }
}
else {
    #Create or check for existing resource group
    $resourceGroup = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
    if (!$resourceGroup) {
        Write-Output "Resource group '$resourceGroupName' does not exist. To create a new resource group, please enter a location.";
        if (!$resourceGroupLocation) {
            if ([bool]([Environment]::GetCommandLineArgs() -Contains '-NonInteractive')) {
                Write-Error "Operating in non interactive mode. 'resourceGroupLocation' paremater required!"
                return;
            }
            else {
                Write-Warning "Location not supply, please enter a location.";
                $resourceGroupLocation = Read-Host "resourceGroupLocation";
            }
        }

        Write-Output "Creating resource group '$resourceGroupName' in location '$resourceGroupLocation'";
        New-AzResourceGroup -Name $resourceGroupName -Location $resourceGroupLocation
    }
    else {
        Write-Output "Using existing resource group '$resourceGroupName'";
    }

    # Start resource group deployment
    if ($test) {
        Test-AzResourceGroupDeployment `
            -ResourceGroupName $resourceGroupName `
            -TemplateFile $templateFilePath `
            -TemplateParameterFile $parametersFilePath `
            @OptionalParameters `
            -Verbose
    }
    else {
        New-AzResourceGroupDeployment `
            -Name $deploymentName `
            -ResourceGroupName $resourceGroupName `
            -TemplateFile $templateFilePath `
            -TemplateParameterFile $parametersFilePath `
            @OptionalParameters `
            -Force -Verbose `
            -ErrorVariable ErrorMessages `
            -Mode Incremental 
    }

    if ($ErrorMessages) {
        Write-Output "ERROR: $ErrorMessages"
    }
}