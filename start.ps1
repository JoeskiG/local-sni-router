# Define the proxy registry paths
$RegistryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"

# 1. Save original proxy states to restore later
$OriginalProxyEnable = (Get-ItemProperty -Path $RegistryPath).ProxyEnable
$OriginalProxyServer = (Get-ItemProperty -Path $RegistryPath).ProxyServer
$OriginalAutoConfigURL = (Get-ItemProperty -Path $RegistryPath).AutoConfigURL

# Function to clean up settings on exit
function Cleanup {
    Write-Host "`nStopping servers and restoring original proxy settings..." -ForegroundColor Yellow
    
    # Stop the background processes
    Stop-Process -Id $HttpServer.Id -ErrorAction SilentlyContinue
    Stop-Process -Id $MitmDump.Id -ErrorAction SilentlyContinue
    
    # Restore original registry keys (or delete them if they didn't exist)
    Set-ItemProperty -Path $RegistryPath -Name "ProxyEnable" -Value $OriginalProxyEnable
    if ($OriginalProxyServer) { Set-ItemProperty -Path $RegistryPath -Name "ProxyServer" -Value $OriginalProxyServer } else { Remove-ItemProperty -Path $RegistryPath -Name "ProxyServer" -ErrorAction SilentlyContinue }
    if ($OriginalAutoConfigURL) { Set-ItemProperty -Path $RegistryPath -Name "AutoConfigURL" -Value $OriginalAutoConfigURL } else { Remove-ItemProperty -Path $RegistryPath -Name "AutoConfigURL" -ErrorAction SilentlyContinue }
    
    # Refresh Windows proxy settings globally
    $RefreshCode = '[DllImport("wininet.dll")] public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);'
    $WinInet = Add-Type -MemberDefinition $RefreshCode -Name "WinInet" -PassThru
    $WinInet::InternetSetOption(0, 39, 0, 0) | Out-Null # 39 = INTERNET_OPTION_SETTINGS_CHANGED
    $WinInet::InternetSetOption(0, 37, 0, 0) | Out-Null # 37 = INTERNET_OPTION_REFRESH

    Write-Host "Cleanup complete. Goodbye!" -ForegroundColor Green
    Exit
}

# Trap Ctrl+C or unexpected script termination to force cleanup
trap { Cleanup }

# 2. Start the background servers
Write-Host "Starting HTTP server and mitmdump..." -ForegroundColor Cyan
$HttpServer = Start-Process python -ArgumentList "-m http.server 8000 --bind 127.0.0.1" -WorkingDirectory "pac" -NoNewWindow -PassThru
$MitmDump = Start-Process mitmdump -ArgumentList "-s main.py --ssl-insecure" -NoNewWindow -PassThru

# 3. Apply the new PAC and Proxy settings
Write-Host "Applying Windows Proxy and PAC configuration..." -ForegroundColor Cyan
Set-ItemProperty -Path $RegistryPath -Name "ProxyEnable" -Value 1
Set-ItemProperty -Path $RegistryPath -Name "ProxyServer" -Value "127.0.0.1:8080" # Standard mitmdump port (adjust if your main.py overrides this)
Set-ItemProperty -Path $RegistryPath -Name "AutoConfigURL" -Value "http://127.0.0.1:8000/proxy.pac"

# Refresh system settings so Windows notices the change immediately
$RefreshCode = '[DllImport("wininet.dll")] public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);'
$WinInet = Add-Type -MemberDefinition $RefreshCode -Name "WinInet" -PassThru
$WinInet::InternetSetOption(0, 39, 0, 0) | Out-Null
$WinInet::InternetSetOption(0, 37, 0, 0) | Out-Null

Write-Host "Proxy active. Press 'Ctrl + C' in this window to stop and revert settings." -ForegroundColor Green

# Keep the script alive monitoring the processes
try {
    while ($true) {
        Start-Sleep -Seconds 1
    }
}
finally {
    # Handles normal closure / closure via breaking the loop
    Cleanup
}
