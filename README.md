# Optimize-VMwarePKS
This script organizes PKS cluster VMs in vSphere's inventory by folder, DRS rule (for multi-master K8s clusters), and tags and can also clean up these items. It may be run on a schedule.
It requires the PKS CLI tool be available and in PATH as well as PowerShell (core or Windows), VMware PowerCLI (11.x+), and connectivity and permissions to both vCenter and PKS.

Description
------------

This script is designed to bring organization to the K8s nodes deployed by VMware PKS into vSphere. It does this in three main areas: vSphere folders, tags, and DRS rules.
vSphere folders: This script will find all VMs part of the same K8s cluster, get the name of the cluster, and finally put them all into a new vSphere folder based on that name.
DRS rules: In the case of multi-master K8s clusters, the script will detect these masters and place them into an anti-affinity rule definition.
Tags: A tag category for PKS will be created and all cluster nodes identified and tagged with the name of that cluster.

Each of these functions are controlled in the Parameters section and may be turned on or off as desired. There is no requirement for any combination of parameters to be set.

Additionally, this script has the ability to clean-up after PKS by removing empty folders and tags from inventory. It will only do so if they were used by PKS deployments.

Notes
-----------

The script has been written in an idempotent way such that it is safe to schedule on a recurring basis.
The removal of DRS rules is not implemented because vCenter will auto-remove any DRS rules where all the VM membership is empty.

Requirements
------------

+ PowerShell (Core or Windows), 5.x+
+ PKS CLI tool
+ VMware PowerCLI modules, 11.x+


Examples
----------------

Process folders, tags, and DRS rules for all detected PKS machines and display verbose output.

```
$secvCPass = ConvertTo-SecureString -String 'VMware1!' -asPlainText -Force
$credvC = New-Object System.Management.Automation.PSCredential('administrator@vsphere.local',$secvCPass)
$secPKSPass = ConvertTo-SecureString -String 'VMware1!' -asPlainText -Force
$credPKS = New-Object System.Management.Automation.PSCredential('myuser',$secPKSPass)

./Optimize-VMwarePKS.ps1 -ProcessFolders -ProcessTags -ProcessDRSRules -vCenter $vc -vCenterCredential $credvC -PKSSever $pks -PKSCredential $credPKS -Verbose
```

Clean-up folders and tags from deleted PKS deployments.
```
./Optimize-VMwarePKS.ps1 -TidyFolders -TidyTags -vCenter $vc -vCenterCredential $credvC -PKSSever $pks -PKSCredential $credPKS
```
Combine both organize and clean-up into the same command.
```
./Optimize-VMwarePKS.ps1 -ProcessFolders -ProcessTags -ProcessDRSRules -TidyFolders -TidyTags -vCenter $vc -vCenterCredential $credvC -PKSSever $pks -PKSCredential $credPKS
```
License
-------

MIT

Author Information
------------------

Authors: Chip Zoller and Luc Dekens
Contact: @chipzoller and @LucD22


To Do
------------------
+ Add network folder organization
+ Scope operations down to specific vCenter Data center object
+ Update requirements