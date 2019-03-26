<#

.SYNOPSIS
This script organizes PKS cluster VMs in vSphere's inventory by folder, DRS rule (for multi-master K8s clusters), and tags and can also clean up these items. It may be run on a schedule.
It requires the PKS CLI tool be available and in PATH as well as PowerShell (core or Windows), VMware PowerCLI (11.x+), and connectivity and permissions to both vCenter and PKS.

.DESCRIPTION
This script is designed to bring organization to the K8s nodes deployed by VMware PKS into vSphere. It does this in three main areas: vSphere folders, tags, and DRS rules.
vSphere folders: This script will find all VMs part of the same K8s cluster, get the name of the cluster, and finally put them all into a new vSphere folder based on that name.
DRS rules: In the case of multi-master K8s clusters, the script will detect these masters and place them into an anti-affinity rule definition.
Tags: A tag category for PKS will be created and all cluster nodes identified and tagged with the name of that cluster.

Each of these functions are controlled in the Parameters section and may be turned on or off as desired. There is no requirement for any combination of parameters to be set.

Additionally, this script has the ability to clean-up after PKS by removing empty folders and tags from inventory. It will only do so if they were used by PKS deployments.

.PARAMETER ProcessFolders
Asks for a parent folder ($RootFolder) under which any new sub-folders per PKS deployment are created. PKS clusters are identified and the VMs matched up. A new folder is created with the PKS name under the parent.

.PARAMETER ProcessTags
A tag category is specified ($TagCategory) under which a new tag is created with the name set to the PKS cluster name. This tag is written to every node in the same PKS deployment. The cardinality of the category will be single, but the tags themselves can be applied to all object types.

.PARAMETER ProcessDRSRules
In cases where PKS deploys a multi-master cluster, this parameter will find those masters and create an anti-affinity DRS rule for you. It will also update any DRS rule if, in the future, a cluster is scaled out to include more masters. It does not assume you have an appropriate number of ESXi hosts in the cluster to satisfy the rule, however.

.PARAMETER TidyFolders
Looks for empty sub-folders inside the parent ($RootFolder) and, if found, removes them. It will not look anywhere outside the parent folder.

.PARAMETER vCenter
Name of the vCenter Server where PKS deployments can be found.

.PARAMETER vCenterCredential
Credentials to connect to the vCenter. Must be a PSCredential.

.PARAMETER PKSServer
Name of the PKS server.

.PARAMETER PKSCredential
Credential to connect to the PKS server. Must be a PSCredential.

.PARAMETER PKSCert
Full path to certificate. Leave blank (i.e.: '') to use an unsecured connection.

.PARAMETER RootFolder
Name of the 'VM and Template' folder to which the VMs will be moved. Default foldername is 'PKS'.

.PARAMETER TagCategory
Name of the Tag Category under which all Tags will be created. Default name is 'PKS'.

.PARAMETER DRSNameSuffix
Suffix for all DRS rules that will be created. Default value is 'PKS cluster'.

.EXAMPLE
Process folders, tags, and DRS rules for all detected PKS machines and display verbose output.

$secvCPass = ConvertTo-SecureString -String 'VMware1!' -asPlainText -Force
$credvC = New-Object System.Management.Automation.PSCredential('administrator@vsphere.local',$secvCPass)
$secPKSPass = ConvertTo-SecureString -String 'VMware1!' -asPlainText -Force
$credPKS = New-Object System.Management.Automation.PSCredential('myuser',$secPKSPass)

./Optimize-VMwarePKS.ps1 -ProcessFolders -ProcessTags -ProcessDRSRules -vCenter $vc -vCenterCredential $credvC -PKSSever $pks -PKSCredential $credPKS -Verbose

.EXAMPLE
Clean-up folders and tags from deleted PKS deployments.

./Optimize-VMwarePKS.ps1 -TidyFolders -TidyTags -vCenter $vc -vCenterCredential $credvC -PKSSever $pks -PKSCredential $credPKS

.EXAMPLE
Combine both organize and clean-up into the same command.

./Optimize-VMwarePKS.ps1 -ProcessFolders -ProcessTags -ProcessDRSRules -TidyFolders -TidyTags -vCenter $vc -vCenterCredential $credvC -PKSSever $pks -PKSCredential $credPKS

.NOTES
The script has been written in an idempotent way such that it is safe to schedule on a recurring basis.
The removal of DRS rules is not implemented because vCenter will auto-remove any DRS rules where all the VM membership is empty.

Authors: Chip Zoller and Luc Dekens
Contact: @chipzoller and @LucD22

.LINK
https://github.com/chipzoller/Optimize-VMwarePKS

.COMPONENT
PowerShell (Core or Windows), 5.x+
PKS CLI tool
VMware PowerCLI modules, 11.x+

#>

#Requires -Modules VMware.VimAutomation.Core

[CmdletBinding()]
param(
    [switch]$ProcessFolders,
    [switch]$ProcessTags,
    [switch]$ProcessDRSRules,
    [switch]$TidyFolders,
    [switch]$TidyTags,
    [string]$vCenter,
    [PSCredential]$vCenterCredential,
    [string]$PKSServer,
    [PSCredential]$PKSCredential,
    [string]$PKSCert, # Must be full path to cert. Leave blank (i.e.: '') to use an unsecured connection.
    [string]$RootFolder = 'PKS',
    [string]$TagCategory = 'PKS',
    [string]$DRSNameSuffix = 'PKS cluster'
)

#region Local functions
function Get-PksCluster {
    <#
.SYNOPSIS
        This function will get all the provisioned PKS clusters using the CLI tool and return them as PS Objects.
.DESCRIPTION
        This function will get the output of `pks clusters` and parse the output.
.LINK
        https://github.com/chipzoller/Get-PksCluster
.NOTES
        Chip Zoller
        @chipzoller
#>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]
        [string]$Line
    )

    Process {
        if ($Line -match "error") {
            throw "error"
        }
        if ($Line.Length -ne 0 -and $Line -notmatch "Name\s+Plan") {
            $fields = $Line.Trim(' ') -split '\s+'
            $properties = @{
                Name   = $fields[0]
                Plan   = $fields[1]
                UUID   = $fields[2]
                Status = $fields[3]
                Action = $fields[4]
            }
            New-Object -TypeName PSObject -Property $properties
        }
    }
}
#endregion

#region Constants
# Name of the vSphere custom attribute containing the deployment UUID. This is the default.
New-Variable -Name caDeployment -Value deployment -Option ReadOnly
# Name of the vSphere custom attribute containing the K8s node role. The is the default.
New-Variable -Name caJob -Value job -Option ReadOnly
#endregion

#region Preamble
# Halt processing if all actions are $false.
$present = $ProcessFolders.IsPresent, $ProcessTags.IsPresent, $ProcessDRSRules.IsPresent, $TidyFolders.IsPresent, $TidyTags.IsPresent
$set = $ProcessFolders, $ProcessTags, $ProcessDRSRules, $TidyFolders, $TidyTags
If ($present -notcontains $true -or $set -notcontains $true) {
    Write-Verbose "The script requires at least one switch to be selected."
    return
}
# Check and ensure command `pks` is available.
if (-not (Get-Command -Name pks -ErrorAction SilentlyContinue)) {
    throw "pks command not found."
}
#endregion

#region Connect to PKS & check PKS cluster
$pksUser = $PKSCredential.UserName
$pksPass = $PKSCredential.GetNetworkCredential().password

# Use correct login method with/without cert.
if (-NOT $PKSCert -or -NOT $PKSCert.IsPresent) {
    pks login -a $PKSServer -u $PKSUser -p $PKSPass -k
}
else {pks login -a $PKSServer -u $PKSUser -p $PKSPass --ca-cert $PKSCert}

try {$AllPKSClusters = pks clusters | Get-PksCluster | Select-Object Name, UUID}
catch {$error[0]}
if ($AllPKSClusters -contains 'error') {
    Throw "Error encountered getting list of clusters from PKS. Script will terminate."
}
#endregion

#region Connect to vCenter
# Validate connection to vCenter is successful.
try {Connect-VIServer -Server $vCenter -Credential $vCenterCredential -ErrorAction Stop}
catch {throw "Connection to vCenter failed. $($_.Exception.InnerException)"}
#endregion

#region Get PKS VMs and organize them in groups.
$PKSGroupObjects = Get-VM -Name vm-* | Group-Object -Property {$_.CustomFields[$caDeployment]} | Where-Object {$_.Name -Like 'service-instance_*'}
#endregion

#region Process Folders
if ($ProcessFolders) {
    $folder = Get-Folder -Name $RootFolder
    foreach ($item in $PKSGroupObjects) {
        $deployment = $item.Name
        # Match UUID from Deployment CA to PKS cluster name.
        $UUID = $deployment.Split('_') | Select-Object -Last 1
        $PKSClusterName = $AllPKSClusters | Where-Object {$_.UUID -like $UUID}
        $PKSClusterFolderName = $PKSClusterName.Name
        try {
            $targetFolder = Get-Folder -Name $PKSClusterFolderName -Location $RootFolder -ErrorAction Stop
            $targetFolderCount = ($targetFolder | Get-VM).Count
            if ($targetFolderCount -lt $item.Count) {
                Write-Verbose "Additional deployment VMs found. Moving into $PKSClusterFolderName."
                $item.Group | Move-VM -InventoryLocation $targetFolder -Confirm:$false | Out-Null
            }
        }
        catch {
            Write-Verbose "New PKS deployment found. Creating folder for $PKSClusterFolderName."
            $targetFolder = New-Folder -Name $PKSClusterFolderName -Location $folder -Confirm:$false
            Write-Verbose "Moving VMs to $PKSClusterFolderName."
            $item.Group | Move-VM -InventoryLocation $targetFolder -Confirm:$false | Out-Null
        }
    }
}
#endregion

#region Process Tags
if ($ProcessTags) {
    # Check if tag category exists and otherwise create.
    try {
        Get-TagCategory -Name $TagCategory -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Verbose "Creating new tag category: $TagCategory"
        New-TagCategory -Name $TagCategory -Cardinality Single -Description "Category for all PKS cluster name tags." | Out-Null
    }
    foreach ($item in $PKSGroupObjects) {
        $deployment = $item.Name
        # Match UUID from Deployment CA to PKS cluster name.
        $UUID = $deployment.Split('_') | Select-Object -Last 1
        $PKSClusterName = $AllPKSClusters | Where-Object {$_.UUID -like $UUID}
        $TagName = $PKSClusterName.Name
        try {
            Get-Tag -Name $TagName -Category $TagCategory -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Verbose "Creating new tag: $TagName"
            New-Tag -Name $TagName -Category $TagCategory | Out-Null
        }
        # Check if tag is assigned to VMs in deployment.
        $HasTag = $item.Group | Get-TagAssignment | Where-Object Tag -match $TagName -ErrorAction SilentlyContinue
        if (-NOT $HasTag) {
            Write-Verbose "Writing tag $TagName to nodes."
            $item.Group | New-TagAssignment -Tag $TagName | Out-Null
        }
    }
}
#endregion

#region Process DRS rules
if ($ProcessDRSRules) {
    foreach ($item in $PKSGroupObjects) {
        $deployment = $item.Name
        # Group the VMs in a deployment on job type
        $item.Group | Group-Object -Property {$_.CustomFields[$caJob]} | ForEach-Object -Process {
            # Handling the masters
            if ($_.Name -eq 'master') {
                $_.Group | Select-Object Name, @{N = 'Cluster'; E = {Get-Cluster -VM $_ }} | Group-Object -Property Cluster | ForEach-Object -Process {
                    $UUID = $deployment.Split('_') | Select-Object -Last 1
                    $PKSClusterName = $AllPKSClusters | Where-Object {$_.UUID -like $UUID}
                    $PKSClusterDRSName = $PKSClusterName.Name
                    # More than 1 master
                    if ($_.Group.Count -gt 1) {
                        # Check if DRS rule already exists.
                        $DRSRuleExists = Get-DrsRule -Name "$PKSClusterDRSName $DRSNameSuffix" -Cluster $_.Name -ErrorAction SilentlyContinue
                        if (-NOT $DRSRuleExists) {
                            # Create DRS properties for rule later.
                            $drsRule = @{
                                Cluster      = $_.Name
                                Name         = "$PKSClusterDRSName $DRSNameSuffix"
                                VM           = $_.Group.Name
                                KeepTogether = $false
                                Confirm      = $false
                            }
                            # Create the anti-affinity rule. Not taking into account when there are more masters than ESXi hosts in a cluster.
                            Write-Verbose "Creating new DRS rule for $PKSClusterDRSName"
                            New-DrsRule @drsRule | Out-Null
                            return
                        }
                        # Check if more masters exist and re-create DRS rule if necessary.
                        $DRSRuleVMCount = ($DRSRuleExists | Select-Object -ExpandProperty VMIDs).Count
                        if ($_.Group.Count -gt $DRSRuleVMCount) {
                            $DRSRuleExists | Remove-DrsRule -Confirm:$false
                            # Create DRS properties for rule later.
                            $drsRule = @{
                                Cluster      = $_.Name
                                Name         = "$PKSClusterDRSName $DRSNameSuffix"
                                VM           = $_.Group.Name
                                KeepTogether = $false
                                Confirm      = $false
                            }
                            Write-Verbose "Creating updated DRS rule for $PKSClusterDRSName"
                            New-DrsRule @drsRule | Out-Null
                        }
                    }
                }
            }
        }
    }
}
#endregion

#region Clean up Tags
if ($TidyTags) {
    # Get all tag names within the specified category.
    $AllTagNames = Get-TagCategory $TagCategory | Get-Tag | Select-Object -ExpandProperty Name
    # Loop through each tag getting the number of objects to which it is assigned.
    foreach ($InvTagName in $AllTagNames) {
        $TagNameCount = (Get-TagAssignment -Category $TagCategory | Where-Object Tag -like "*$InvTagName*").Count
        # If any tag has zero objects to which it is assigned, delete it.
        if ($TagNameCount -lt 1) {
            Write-Verbose "Deleting tag $InvTagName since unused."
            Remove-Tag -Tag $InvTagName -Confirm:$false
        }
    }
}
#endregion

#region Clean up folders
if ($TidyFolders) {
    # Get all the folders under the specified $RootFolder variable.
    Get-Folder -Location $RootFolder | ForEach-Object -Process {
        if ((Get-VM -Location $_).Count -lt 1) {
            Write-Verbose "Deleting folder $($_.Name) since it is empty."
            Remove-Folder -Folder $_ -Confirm:$false
        }
    }
}
#endregion

#region Disconnect
pks logout
Disconnect-VIServer $vCenter -Confirm:$false | Out-Null
#endregion
