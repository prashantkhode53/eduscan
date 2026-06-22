# =============================================================================
#  EduScan — build ONLY the Academy APK (arm64), in one command.
#
#  Builds the arm64-v8a release APK for the Academy flavor (~39 MB; the build
#  compiles a single CPU architecture, so it is fast and small) and writes it
#  out as EduScan-Academy.apk. Use this when you only need the Academy app.
#  For both Academy + Parent in one go, use build_apks.ps1 instead.
#
#  Usage (from the project root, in PowerShell):
#       .\build_academy_apk.ps1
#
#  Output (ready to copy):
#       build\app\outputs\flutter-apk\EduScan-Academy.apk
# =============================================================================

$ErrorActionPreference = 'Stop'

# Folder Flutter writes APKs into, and where the named copy will land.
$OutDir = Join-Path $PSScriptRoot 'build\app\outputs\flutter-apk'
# The raw file Flutter produces for an arm64-only build.
$RawApk = Join-Path $OutDir 'app-arm64-v8a-release.apk'
# Final, uniquely-named output.
$OutName = 'EduScan-Academy.apk'

# Remove any stale Flutter-generated APKs from earlier runs (raw arm64 copy
# plus any multi-ABI / universal leftovers like app-release.apk) so the folder
# isn't cluttered with dead weight from previous builds.
if (Test-Path $OutDir) {
    Get-ChildItem $OutDir -Filter 'app-*.apk*' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " Building Academy APK  (APP_MODE=academy)" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

# Build arm64-only release for the Academy flavor.
flutter build apk --release --target-platform android-arm64 --dart-define=APP_MODE=academy
if ($LASTEXITCODE -ne 0) {
    Write-Host "BUILD FAILED for Academy. Stopping." -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $RawApk)) {
    Write-Host "Expected APK not found: $RawApk" -ForegroundColor Red
    exit 1
}

# Move (not copy) to the uniquely-named file: this both produces the named APK
# and removes the raw app-arm64-v8a-release.apk in one step.
$dest = Join-Path $OutDir $OutName
Move-Item -Path $RawApk -Destination $dest -Force

$sizeMB = [math]::Round((Get-Item $dest).Length / 1MB, 1)
Write-Host "  -> $OutName  ($sizeMB MB)" -ForegroundColor Green

# Final safety sweep: drop any stray app-*.apk Flutter may have emitted
# (e.g. .sha1 sidecars) so only the named APK remains.
Get-ChildItem $OutDir -Filter 'app-*.apk*' -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "DONE. Academy APK is in:" -ForegroundColor Green
Write-Host "  $OutDir" -ForegroundColor Green
Get-ChildItem $OutDir -Filter 'EduScan-Academy.apk' |
    Select-Object Name, @{N='Size(MB)';E={[math]::Round($_.Length/1MB,1)}} |
    Format-Table -AutoSize
