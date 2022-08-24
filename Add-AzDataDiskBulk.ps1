###########################################################
# AUTHOR  : Filip Vagner
# EMAIL   : filip.vagner@hotmail.com
# DATE    : 12-01-2021 (dd-mm-yyyy)
# COMMENT : This script adds new data disk to Azure virtual machine.
#           It checks, if data disk name is available (in vm's current RG
#           and also connected disks to that vm).
#
#TODO Create report at the of script (vmname, diskname, attached [yes,no,n/a])
###########################################################

# Creating objects
$ErrorActionPreference = 'Continue'
$diskTags = New-Object "System.Collections.Generic.Dictionary[string,string]"
$vmsArray = New-Object -TypeName "System.Collections.ArrayList"
$vmsList = Import-Csv -Path "$env:USERPROFILE\<path>\serverlist.csv"
$vmsList | ForEach-Object {
    $vmObject = [PSCustomObject]@{
        Name = $_.name
        ResourceGroup = $_.resourcegroup
        SubscriptionId = $_.subscriptionid
    }
    $vmsArray.Add($vmObject)
}

# Setting variables
$createdBy = 'Filip Vagner'
$creationDate = Get-Date -Format 'dd.MM.yyyy'
$diskSkuName = 'Premium_LRS'
$diskSizeGb = 512
$diskEncryptionType = 'EncryptionAtRestWithPlatformKey'
$diskNetworkAccessPolicy = 'AllowAll'
$diskCreationOption = 'Empty'

$diskTags.Add("CreatedBy", $createdBy)
$diskTags.Add("CreationDate", $CreationDate)

foreach ($vmItem in $vmsArray) {
    $null = Set-AzContext -Subscription $vmItem.SubscriptionId
    $targetVm = Get-AzVM -Name $vmItem.Name -ResourceGroupName $vmItem.ResourceGroup
    $targetVmDisks = ($targetVm | Select-Object -ExpandProperty StorageProfile).DataDisks
    $rgDisksList = (Get-AzDisk -ResourceGroupName $vmItem.ResourceGroup).Name
    $diskIdNum = 1
    $diskLunNum = 0
    
    if (([System.String]::IsNullOrEmpty($targetVmDisks)) -and (!$rgDisksList.Contains("$($targetVm.Name)-DataDisk-$diskIdNum"))) {
        $diskName = "$($targetVm.Name)-DataDisk-$diskIdNum"
        $diskLun = $diskLunNum
    } else {
        do {
            $diskName = "$($targetVm.Name)-DataDisk-$diskIdNum"
            $diskIdNum++
        } while ($targetVmDisks.Name.Contains($diskName) -or ($rgDisksList.Contains($diskName)))
        
        do {
            $diskLun = ++$diskLunNum
        } until ($diskLunNum -gt $targetVmDisks.Lun[-1])
    }

    $diskConfigParams = @{
        SkuName = $diskSkuName
        Location = $targetVm.Location
        DiskSizeGB = $diskSizeGb
        EncryptionType = $diskEncryptionType
        NetworkAccessPolicy = $diskNetworkAccessPolicy
        CreateOption = $diskCreationOption
        Tag = $diskTags
    }

    if (![System.String]::IsNullOrEmpty($targetVm.Zones)) {
        $diskConfigParams.Add("Zone", $targetVm.Zones)
    }

    $diskConfig = New-AzDiskConfig @diskConfigParams
    $dataDisk = New-AzDisk -ResourceGroupName $targetVm.ResourceGroupName -DiskName $diskName -Disk $diskConfig
    $targetVm = Add-AzVMDataDisk -VM $targetVm -Name $diskName -Caching 'None' -CreateOption 'Attach' -Lun $diskLun -ManagedDiskId $dataDisk.Id
    Update-AzVM -ResourceGroupName $targetVm.ResourceGroupName -VM $targetVm

    # Clear variables
    Clear-Variable -Name targetVm
    Clear-Variable -Name targetVmDisks
    Clear-Variable -Name diskConfigParams
    Clear-Variable -Name rgDisksList
    Clear-Variable -Name diskIdNum
    Clear-Variable -Name diskLunNum
    Clear-Variable -Name diskName
    Clear-Variable -Name diskLun
    Clear-Variable -Name diskConfig
    Clear-Variable -Name dataDisk
}
# End of script