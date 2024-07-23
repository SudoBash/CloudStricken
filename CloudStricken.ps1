#UNTESTED
param (
    [string]$hypervisor = "10.10.10.10",
    [string]$user = "Hypervisor Username", 
    [string]$pass = "Hypervisor Password", 
    [string]$datastore = "ISO",
    [string]$ISO = "CloudStricken.iso", #Standard Alpine with root password set to alpine (must have a password, but alpine defaults to blank, which won't work I don't think #unconfirmed)
    [switch]$vmware,
    [switch]$hyperv,
    [switch]$proxmox,
    [switch]$xen
)

Set-StrictMode -Off

$defaultAutoLoad = $PSMmoduleAutoloadingPreference
$PSMmoduleAutoloadingPreference = "none"

if($vmware){
    if (Get-Module -ListAvailable -Name VMware*) {
        Import-Module VMware.VimAutomation.Core 2>&1 | out-null
        Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false | Out-Null
    }
}
elseif ($hyperv){}
elseif($proxmox){}
elseif($xen){}

function Connect-Hypervisor {
    $session = Connect-VIServer -Server $hypervisor -User:$user -Pass:$pass 2>&1 | out-null
    Write-Host "Connecting to Hypervisor"
    if($global:DefaultVIServer.name -like $hypervisor){
        Write-Host "Established Connection to $session"
    } else {
        Write-Host "Couldn't Connect to $hypervisor"
        exit
    }
    return $session
}

function Close-Hypervisor {
    if($global:DefaultVIServer.name -like $hypervisor){
        Write-Host "Disconnecting from Hypervisor and Cleaning Up..."
        Remove-PSDrive -Name DS -Confirm:$false 2>&1 | out-null
        Disconnect-VIServer $hypervisor -Confirm:$false 2>&1 | out-null
    }
}

#Bash ScriptBlock that gets executed on each VM Guest through Invoke-VMScript (by the Hypervisor)

$repair_script = @"
!/bin/bash
mkdir -p /media/drive
mapfile -t devices < <(blkid -o list)

for device_info in "${devices[@]}"; do
    device_path=$(echo "$device_info" | awk '{print $1}')
    device_type=$(echo "$device_info" | awk '{print $2}')

    if [[ "$device_type" == "ntfs" || "$device_type" == "vfat" ]]; then
        echo "Windows drive detected: $device_path"
        break
    fi
done

#RFC: Could move the fix below into the above loop to attempt the fix on all discovered NTFS / VFAT partitions instead of first discovered since it searches for the file.

echo "Attempting to mount suspected Windows Partition: $device_path"

mount -t $device_type $device_path /media/drive

if [ "$(find /media/drive/Windows/System32/drivers/CrowdStrike/ -maxdepth 1 -name 'C-00000291*.sys')" ]; then
    echo "Faulty Cloudstrike Driver Found! Deleting..."
    rm /media/drive/Windows/System32/drivers/CrowdStrike/C-00000291*.sys
else
    echo "Faulty Cloudstrike Driver NOT Found! Doing Nothing!"
fi
"@

    $session = Connect-Hypervisor   
    
    $machines = Get-VM -Name *
    
    foreach ($machine in $machines) {
        Write-Host "Repairing $machine"
        $vm = Get-VM -name $machine -ErrorAction SilentlyContinue
        $cd = Get-CDDrive -VM $vm
        Set-CDDrive -CD $cd -ISOPath "[$datastore]\$ISO" -Confirm:$false -StartConnected $true
        
        Start-Sleep -Seconds 1
        $power = Start-VM -VM $vm -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 10
		
        while ($Power_Task.ExtensionData.Info.State -eq "running") {
			Start-Sleep 1
			$Power_Task.ExtensionData.UpdateViewData('Info.State')
		}

        $repair = Invoke-VMScript -VM $vm -GuestUser "root" -GuestPass "alpine" -ScriptType "Bash" -ScriptText $repair_script
        $shutdown = Shutdown-VMGuest -VM $machine -Confirm:$false -Server $session -ErrorAction SilentlyContinue
        Start-Sleep 1
        Set-CDDrive -CD $cd -ISOPath "" -Confirm:$false -StartConnected $false
    }

    Close-Hypervisor
