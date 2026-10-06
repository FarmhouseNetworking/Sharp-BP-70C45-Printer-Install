# Sharp BP-70C45 printers - silent driver and TCP/IP printer install for RMM
# Run as SYSTEM from SuperOps. Safe to re-run: anything already present is skipped.

Import-Module $SuperOpsModule

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # progress bar makes Invoke-WebRequest very slow in PS 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---- Settings ---------------------------------------------------------------
$SupportDir = 'C:\Support'

# Sharp PCL6/PS x64 driver package. It is a self-extractor that unpacks the driver files
# and then opens Sharp's own "Driver Installation" wizard - this script only wants the files.
$DriverUrl      = 'https://global.sharp/restricted/print/mfpdl/sites/default/files/Global_Download_Data/18128/SH_D33_PCL6_PS_2508a_EnglishUS_64bit.exe'
$DriverSha256   = 'C9F9CA502D26B49731077ED36B9DF97793C7AD4DB9DAB9163B1EC941709C11FA'
$PackageName    = 'SH_D33_PCL6_PS_2508a_EnglishUS_64bit'
$DriverName     = 'SHARP BP-70C45 PCL6'           # driver name exactly as written in the INF
$ExtractMinutes = 5                               # give up on the extractor after this long

# Printer IP addresses - REPLACE each placeholder below with that printer's IPv4 address.
# Change only the text between the quotes and keep the quotes. Each address must be
# static on the printer or reserved in DHCP. The script stops with an error while a
# placeholder is still in place. See "Set the printer IP addresses first" in README.md.
$MainPrinterIP     = 'MAIN-PRINTER-IP'
$ShippingPrinterIP = 'SHIPPING-PRINTER-IP'

# One line per printer. Name is what users see; PortName and IP come from the variables above.
$Printers = @(
    @{ Name = 'Main Sharp Printer';     PortName = $MainPrinterIP;     IP = $MainPrinterIP }
    @{ Name = 'Shipping Sharp Printer'; PortName = $ShippingPrinterIP; IP = $ShippingPrinterIP }
)
# -----------------------------------------------------------------------------

$Exe        = Join-Path $SupportDir "$PackageName.exe"
$ExtractDir = Join-Path $SupportDir $PackageName
$ExtractLog = Join-Path $SupportDir "$PackageName.log"

# Sharp's wizard (and anything else) running out of the unpacked folder
function Get-WizardProcesses {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -like "$ExtractDir\*" }
}

# The self-extractor itself, including the temp copy it runs from
function Get-ExtractorProcesses {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -eq $Exe -or $_.CommandLine -like "*$PackageName.exe*" -or $_.Name -eq "$PackageName.tmp" }
}

function Stop-Processes {
    param($Processes)
    foreach ($p in @($Processes)) {
        if ($p) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    }
}

function Find-DriverInf {
    if (-not (Test-Path $ExtractDir)) { return $null }
    Get-ChildItem -Path $ExtractDir -Recurse -Filter *.inf |
        Select-String -SimpleMatch -Pattern "`"$DriverName`"" -List |
        Select-Object -First 1
}

try {
    # ---- Stop early if a printer IP placeholder was not replaced ----
    foreach ($p in $Printers) {
        $parsedIp = $null
        if ($p.IP -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or -not [System.Net.IPAddress]::TryParse($p.IP, [ref]$parsedIp)) {
            throw "Printer IP for '$($p.Name)' is not set. Replace the placeholder '$($p.IP)' in the Settings block with that printer's IP address."
        }
    }

    # ---- Driver (skipped if already installed) ----
    if (Get-PrinterDriver -Name $DriverName -ErrorAction SilentlyContinue) {
        Write-Output "Driver '$DriverName' already installed - skipping download."
    }
    else {
        if (-not (Test-Path $SupportDir)) { New-Item -Path $SupportDir -ItemType Directory -Force | Out-Null }

        Write-Output "Downloading $DriverUrl"
        Invoke-WebRequest -Uri $DriverUrl -OutFile $Exe -UseBasicParsing

        if ($DriverSha256) {
            $actual = (Get-FileHash -Path $Exe -Algorithm SHA256).Hash
            if ($actual -ne $DriverSha256) { throw "Hash mismatch on $Exe. Expected $DriverSha256, got $actual." }
        }

        # Unpack silently. The package opens Sharp's wizard as its last step and waits on it,
        # so watch for the wizard and close it - by then every file is on disk.
        Write-Output "Extracting to $ExtractDir"
        $extractArgs = "/VERYSILENT /SUPPRESSMSGBOXES /SP- /NORESTART /NOCANCEL /DIR=`"$ExtractDir`" /LOG=`"$ExtractLog`""
        $proc     = Start-Process -FilePath $Exe -ArgumentList $extractArgs -PassThru
        $deadline = (Get-Date).AddMinutes($ExtractMinutes)

        while (-not $proc.HasExited) {
            $wizard = Get-WizardProcesses
            if ($wizard) {
                Write-Output "Closing Sharp's installer wizard (files are unpacked)."
                Stop-Processes $wizard
                break
            }
            if ((Get-Date) -gt $deadline) {
                Stop-Processes (Get-WizardProcesses)
                Stop-Processes (Get-ExtractorProcesses)
                throw "Sharp package did not finish extracting within $ExtractMinutes minutes. See $ExtractLog"
            }
            Start-Sleep -Milliseconds 500
        }

        # Let the extractor wind down, then make sure nothing is left behind
        if (-not $proc.WaitForExit(30000)) { Stop-Processes (Get-ExtractorProcesses) }
        Start-Sleep -Seconds 2
        Stop-Processes (Get-WizardProcesses)

        $hit = Find-DriverInf
        if (-not $hit) { throw "No INF under $ExtractDir defines '$DriverName'. See $ExtractLog" }

        Write-Output "Staging driver from $($hit.Path)"
        & pnputil.exe /add-driver $hit.Path /install | Out-String | Write-Output
        # 0 = added, 259 = already in the driver store, 3010 = added, reboot pending
        if ($LASTEXITCODE -notin 0, 259, 3010) { throw "pnputil failed with exit code $LASTEXITCODE" }

        Add-PrinterDriver -Name $DriverName
        Write-Output "Driver '$DriverName' installed."
        Remove-Item -Path $Exe -Force -ErrorAction SilentlyContinue
    }

    # ---- Ports and printers (each skipped if already present) ----
    $failed = 0
    foreach ($p in $Printers) {
        try {
            if (-not (Get-PrinterPort -Name $p.PortName -ErrorAction SilentlyContinue)) {
                Add-PrinterPort -Name $p.PortName -PrinterHostAddress $p.IP -PortNumber 9100
            }

            if (Get-Printer -Name $p.Name -ErrorAction SilentlyContinue) {
                Write-Output "Printer '$($p.Name)' already exists - skipping."
            }
            else {
                Add-Printer -Name $p.Name -DriverName $DriverName -PortName $p.PortName
                Write-Output "Printer '$($p.Name)' added on $($p.IP)."
            }
        }
        catch {
            $failed++
            Write-Output "FAILED: '$($p.Name)' ($($p.IP)) - $($_.Exception.Message)"
        }
    }
    if ($failed) { throw "$failed of $($Printers.Count) printers failed." }

    Write-Output 'Done.'
    exit 0
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    exit 1
}
