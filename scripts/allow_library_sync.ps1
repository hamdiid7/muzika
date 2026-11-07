$ErrorActionPreference = 'Stop'
$resultFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'build\library-sync-firewall-result.json'
try {
    $program = 'C:\Users\twinkle2\AppData\Local\Muzika\app-777BB5CC656DF8D2\Muzika.exe'
    if (-not (Test-Path -LiteralPath $program -PathType Leaf)) { throw 'Muzika executable was not found.' }
    $name = 'MuzikaLibrarySyncLocal'
    $rule = Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
    if ($rule) {
        $rule | Set-NetFirewallRule -Enabled True -Direction Inbound -Action Allow -Profile Private,Public
        $rule | Get-NetFirewallApplicationFilter | Set-NetFirewallApplicationFilter -Program $program
        $rule | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress LocalSubnet
        $rule | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter -Protocol TCP
    } else {
        New-NetFirewallRule -Name $name -DisplayName 'Muzika library sync (local network only)' -Description 'Allow the Muzika QR library-sync listener from this local subnet only.' -Program $program -Direction Inbound -Protocol TCP -RemoteAddress LocalSubnet -Profile Private,Public -Action Allow -Enabled True | Out-Null
    }
    @{ success = $true; program = $program; scope = 'LocalSubnet'; profiles = 'Private,Public' } | ConvertTo-Json | Set-Content -LiteralPath $resultFile
    exit 0
} catch {
    @{ success = $false; error = $_.Exception.Message } | ConvertTo-Json | Set-Content -LiteralPath $resultFile
    exit 1
}
