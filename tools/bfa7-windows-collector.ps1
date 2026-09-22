param(
    [string]$OutputRoot = "$env:USERPROFILE\Desktop\BFA7-Windows-Report",
    [switch]$IncludeFileTree
)

$ErrorActionPreference = "Continue"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outDir = Join-Path $OutputRoot $timestamp
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

function Write-Section {
    param([string]$Name)
    "`r`n===== $Name =====`r`n"
}

function Save-Text {
    param(
        [string]$Name,
        [scriptblock]$Block
    )
    $path = Join-Path $outDir $Name
    try {
        & $Block | Out-String -Width 240 | Set-Content -Encoding UTF8 -Path $path
    } catch {
        "ERROR: $($_.Exception.Message)" | Set-Content -Encoding UTF8 -Path $path
    }
}

function Save-Json {
    param(
        [string]$Name,
        [scriptblock]$Block
    )
    $path = Join-Path $outDir $Name
    try {
        & $Block | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -Path $path
    } catch {
        @{ error = $_.Exception.Message } | ConvertTo-Json | Set-Content -Encoding UTF8 -Path $path
    }
}

$summary = New-Object System.Collections.Generic.List[string]
$summary.Add("BFA7 Windows Collector")
$summary.Add("Generated: $((Get-Date).ToUniversalTime().ToString("o"))")
$summary.Add("Computer: $env:COMPUTERNAME")
$summary.Add("User: $env:USERNAME")
$summary.Add("PowerShell: $($PSVersionTable.PSVersion)")
$summary.Add("")
$summary.Add("Goal: identify how Xiaomi AI Glasses BFA7 expose USB/Bluetooth/network interfaces on Windows.")
$summary.Add("Privacy: this script reads device metadata and does not copy personal media by default.")
$summary | Set-Content -Encoding UTF8 -Path (Join-Path $outDir "summary.txt")

Save-Text "pnp-present.txt" {
    Get-PnpDevice -PresentOnly |
        Sort-Object Class, FriendlyName |
        Format-Table -AutoSize Status, Class, FriendlyName, InstanceId
}

Save-Text "pnp-xiaomi-bfa7-filtered.txt" {
    Get-PnpDevice -PresentOnly |
        Where-Object {
            ($_.FriendlyName -match "Xiaomi|BFA7|Glasses|MI|MTP|Camera|ADB|Android|Bluetooth|USB") -or
            ($_.InstanceId -match "VID_|MI_|BFA7|XIAOMI|ANDROID|ADB|BTH|USB")
        } |
        Sort-Object Class, FriendlyName |
        Format-List *
}

Save-Json "pnp-xiaomi-bfa7-filtered.json" {
    Get-PnpDevice -PresentOnly |
        Where-Object {
            ($_.FriendlyName -match "Xiaomi|BFA7|Glasses|MI|MTP|Camera|ADB|Android|Bluetooth|USB") -or
            ($_.InstanceId -match "VID_|MI_|BFA7|XIAOMI|ANDROID|ADB|BTH|USB")
        } |
        Select-Object Status, Class, FriendlyName, InstanceId, Problem, ConfigManagerErrorCode
}

Save-Text "usb-controllers-and-devices.txt" {
    Get-CimInstance Win32_USBControllerDevice |
        ForEach-Object {
            $dep = $_.Dependent
            if ($dep -is [string]) {
                $dep = [wmi]$dep
            }
            [pscustomobject]@{
                Name = $dep.Name
                DeviceID = $dep.DeviceID
                PNPClass = $dep.PNPClass
                Manufacturer = $dep.Manufacturer
                Service = $dep.Service
            }
        } |
        Sort-Object Name |
        Format-Table -AutoSize
}

Save-Text "disk-drives.txt" {
    Get-CimInstance Win32_DiskDrive |
        Format-List Model, InterfaceType, MediaType, Size, DeviceID, PNPDeviceID, SerialNumber
}

Save-Text "portable-devices.txt" {
    Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.Class -eq "WPD" -or $_.FriendlyName -match "MTP|PTP|Portable|Xiaomi|Glasses|BFA7" } |
        Format-List *
}

Save-Text "cameras-and-images.txt" {
    Get-PnpDevice -PresentOnly |
        Where-Object { $_.Class -match "Camera|Image|WPD|Media" -or $_.FriendlyName -match "Camera|MTP|PTP|Xiaomi|Glasses|BFA7" } |
        Format-List *
}

Save-Text "bluetooth.txt" {
    Get-PnpDevice -PresentOnly -Class Bluetooth |
        Sort-Object FriendlyName |
        Format-List *
}

Save-Text "serial-ports.txt" {
    Get-CimInstance Win32_SerialPort |
        Format-List Name, DeviceID, PNPDeviceID, Description, ProviderType
}

Save-Text "network-adapters.txt" {
    Get-NetAdapter |
        Sort-Object Name |
        Format-List Name, InterfaceDescription, Status, MacAddress, LinkSpeed, ifIndex
}

Save-Text "ip-config.txt" {
    Get-NetIPConfiguration |
        Format-List InterfaceAlias, InterfaceDescription, IPv4Address, IPv4DefaultGateway, DNSServer
}

Save-Text "arp.txt" {
    arp -a
}

Save-Text "routes.txt" {
    route print
}

Save-Text "processes-xiaomi-android.txt" {
    Get-Process |
        Where-Object { $_.ProcessName -match "xiaomi|mi|android|adb|mtp|phone|glasses" } |
        Sort-Object ProcessName |
        Format-Table -AutoSize Id, ProcessName, Path
}

if (Get-Command adb -ErrorAction SilentlyContinue) {
    Save-Text "adb-devices.txt" { adb devices -l }
    Save-Text "adb-shell-props.txt" { adb shell getprop }
} else {
    "adb not found in PATH." | Set-Content -Encoding UTF8 -Path (Join-Path $outDir "adb-devices.txt")
}

if ($IncludeFileTree) {
    Save-Text "drive-roots.txt" {
        Get-PSDrive -PSProvider FileSystem |
            Format-Table -AutoSize Name, Root, DisplayRoot, Used, Free
    }
}

$zipPath = "$outDir.zip"
Compress-Archive -Path $outDir -DestinationPath $zipPath -Force

Write-Host "BFA7 Windows report saved:"
Write-Host $outDir
Write-Host "ZIP:"
Write-Host $zipPath
