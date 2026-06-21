# =============================================================================
#  EduScan — build both APKs (Academy + Parent) in one command.
#
#  Builds the arm64-v8a release APK for each flavor (fastest + smallest; the
#  build only compiles ONE CPU architecture, so it is much quicker than a
#  universal/all-ABI build which compiles three). Each APK is copied out with a
#  unique, role-identifying name so you never have to rename anything.
#
#  Usage (from the project root, in PowerShell):
#       .\build_apks.ps1
#
#  Output (same folder, ready to copy):
#       build\app\outputs\flutter-apk\EduScan-Academy.apk
#       build\app\outputs\flutter-apk\EduScan-Parent.apk
#
#  Nothing about the app/Firebase changes between the two — only which login
#  screen opens first (see lib/config/app_mode.dart).
# =============================================================================

$ErrorActionPreference = 'Stop'

# Folder Flutter writes APKs into, and where the named copies will land.
$OutDir = Join-Path $PSScriptRoot 'build\app\outputs\flutter-apk'
# The raw file Flutter produces for an arm64-only build.
$RawApk = Join-Path $OutDir 'app-arm64-v8a-release.apk'

# Each flavor: the APP_MODE define and the final, uniquely-named output file.
$Flavors = @(
    @{ Name = 'Academy'; Mode = 'academy'; Out = 'EduScan-Academy.apk' },
    @{ Name = 'Parent';  Mode = 'parent';  Out = 'EduScan-Parent.apk'  }
)

# Remove any stale Flutter-generated APKs from earlier runs (raw arm64 copy
# plus any multi-ABI / universal leftovers like app-release.apk). We only ship
# the two named EduScan-*.apk files, so everything else is dead weight that
# otherwise piles up and slows nothing but confuses the output folder.
if (Test-Path $OutDir) {
    Get-ChildItem $OutDir -Filter 'app-*.apk*' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

foreach ($f in $Flavors) {
    Write-Host ''
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host " Building $($f.Name) APK  (APP_MODE=$($f.Mode))" -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan

    # Build arm64-only release for this flavor.
    flutter build apk --release --target-platform android-arm64 --dart-define=APP_MODE=$($f.Mode)
    if ($LASTEXITCODE -ne 0) {
        Write-Host "BUILD FAILED for $($f.Name). Stopping." -ForegroundColor Red
        exit 1
    }

    if (-not (Test-Path $RawApk)) {
        Write-Host "Expected APK not found: $RawApk" -ForegroundColor Red
        exit 1
    }

    # Move (not copy) to the uniquely-named file: this both produces the named
    # APK and removes the raw app-arm64-v8a-release.apk in one step, so no
    # leftover intermediate file is left behind for the next flavor or at the end.
    $dest = Join-Path $OutDir $f.Out
    Move-Item -Path $RawApk -Destination $dest -Force

    $sizeMB = [math]::Round((Get-Item $dest).Length / 1MB, 1)
    Write-Host "  -> $($f.Out)  ($sizeMB MB)" -ForegroundColor Green
}

# Final safety sweep: drop any stray app-*.apk Flutter may have emitted
# (e.g. .sha1 sidecars) so the folder holds ONLY the two named APKs.
Get-ChildItem $OutDir -Filter 'app-*.apk*' -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "DONE. Both APKs are in:" -ForegroundColor Green
Write-Host "  $OutDir" -ForegroundColor Green
Get-ChildItem $OutDir -Filter 'EduScan-*.apk' |
    Select-Object Name, @{N='Size(MB)';E={[math]::Round($_.Length/1MB,1)}} |
    Format-Table -AutoSize
