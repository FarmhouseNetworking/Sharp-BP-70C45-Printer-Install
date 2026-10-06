# Sharp BP-70C45 Printer Install

Silent, re-runnable RMM install of the Sharp BP-70C45 PCL6 driver plus one or more
TCP/IP printers. Written for the SuperOps agent running as `SYSTEM`, but it is plain
PowerShell and works from any RMM.

## What it does

1. Skips all driver work if the driver is already installed.
2. Downloads Sharp's driver package straight from `global.sharp` and checks its SHA256.
3. Unpacks the package silently into `C:\Support\<package name>`.
4. Closes the "Driver Installation" wizard that Sharp's package opens after unpacking
   (see below).
5. Finds the INF that defines the driver, stages it with `pnputil`, and registers it
   with `Add-PrinterDriver`.
6. Creates a Standard TCP/IP port (RAW, 9100) and a printer for each entry in
   `$Printers`. Ports and printers that already exist are left alone.

Exit code is `0` on success and `1` on any failure, with the reason written to the
script output so the RMM shows it.

## Why it does not just run Sharp's installer

Sharp's download is an Inno Setup self-extractor. Its silent switches
(`/VERYSILENT` and friends) only silence the unpacking. As its last step the package
opens Sharp's own wizard ("Choose an installation method") and waits on it. Under
`SYSTEM` that window is invisible, so a script that waits for the package to finish
hangs forever.

This script watches for that wizard, closes it as soon as it appears (every file is on
disk by then), and installs the driver directly from the unpacked INF.

## Set the printer IP addresses first

The script ships with placeholders where the printer IP addresses go. It stops with an
error until you replace them, so nothing is installed against a wrong address.

1. Find each printer's IPv4 address: print a network or configuration page at the
   printer, or look it up in your DHCP server. Make the address static on the printer,
   or reserve it in DHCP, so it never changes.
2. Open `Install-SharpPrinters.ps1` and find these two lines in the `Settings` block:

   ```powershell
   $MainPrinterIP     = 'MAIN-PRINTER-IP'
   $ShippingPrinterIP = 'SHIPPING-PRINTER-IP'
   ```

3. Replace only the text between the quotes with the address. Keep the quotes.
4. Leave the `$Printers` list alone unless you are adding, removing or renaming a
   printer. Each printer's `PortName` and `IP` are filled in from those variables.

To add a printer, add a variable for its address and a matching line in `$Printers`:

```powershell
$LobbyPrinterIP = 'LOBBY-PRINTER-IP'

$Printers = @(
    @{ Name = 'Main Sharp Printer';     PortName = $MainPrinterIP;     IP = $MainPrinterIP }
    @{ Name = 'Shipping Sharp Printer'; PortName = $ShippingPrinterIP; IP = $ShippingPrinterIP }
    @{ Name = 'Lobby Sharp Printer';    PortName = $LobbyPrinterIP;    IP = $LobbyPrinterIP }
)
```

To remove a printer, delete its line from `$Printers` and its variable.

Set real addresses only in the copy of the script you paste into your RMM. Do not
commit them to a public copy of this repository.

## Configuration

Everything is in the `Settings` block at the top of `Install-SharpPrinters.ps1`.

| Setting | Meaning |
|---|---|
| `$SupportDir` | Working folder on the endpoint. Default `C:\Support`. |
| `$DriverUrl` | Direct link to Sharp's driver package (`.exe`). |
| `$DriverSha256` | SHA256 of that package. Set to `''` to skip the check. |
| `$PackageName` | The package file name without `.exe`. Also used as the unpack folder name. |
| `$DriverName` | Driver name exactly as written in the INF, e.g. `SHARP BP-70C45 PCL6`. |
| `$ExtractMinutes` | How long to wait for unpacking before giving up. |
| `$MainPrinterIP`, `$ShippingPrinterIP` | IP address of each printer. **Placeholders - you must replace them.** |
| `$Printers` | One entry per printer: display `Name`, `PortName`, and `IP`. |

Printer IP addresses must be static or DHCP-reserved.

## Deployment

Add it as a SuperOps custom script and run it as `SYSTEM`. SuperOps injects
`$SuperOpsModule` at runtime, which the first line imports. On another RMM, delete
that `Import-Module` line.

## Using a different Sharp model or driver version

1. Download the package for your model from Sharp and copy its direct link into
   `$DriverUrl`.
2. Set `$PackageName` to the file name without `.exe`.
3. Get the hash and paste it into `$DriverSha256`:

   ```powershell
   (Get-FileHash .\<package>.exe -Algorithm SHA256).Hash
   ```

4. Set `$DriverName` to the exact model string from the INF. For this package the
   PCL6 INF is `EnglishA\PCL6\64bit\su3emenu.inf` and the names are in its
   `[Strings]` section.

## Troubleshooting

- **`Printer IP for '<name>' is not set`:** a placeholder is still in the `Settings`
  block, or the value is not a valid IPv4 address. See
  [Set the printer IP addresses first](#set-the-printer-ip-addresses-first).
- **Unpack log:** `C:\Support\<package name>.log`.
- **`Hash mismatch`:** Sharp replaced the file at that URL. Download it yourself,
  confirm it is what you expect, and update `$DriverSha256`.
- **`No INF under ... defines '<name>'`:** `$DriverName` does not match the INF, or the
  package did not unpack into `C:\Support\<package name>`. Check the unpack log.

## Requirements

- Windows 10 / 11 x64, Windows PowerShell 5.1
- Run elevated (`SYSTEM` or an administrator)
- Outbound HTTPS to `global.sharp`
