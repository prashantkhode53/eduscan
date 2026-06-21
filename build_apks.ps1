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

    # Copy (not move) to the uniquely-named file. Copy means the raw file is
    # free to be overwritten by the next flavor's build.
    $dest = Join-Path $OutDir $f.Out
    Copy-Item -Path $RawApk -Destination $dest -Force

    $sizeMB = [math]::Round((Get-Item $dest).Length / 1MB, 1)
    Write-Host "  -> $($f.Out)  ($sizeMB MB)" -ForegroundColor Green
}

Write-Host ''
Write-Host "DONE. Both APKs are in:" -ForegroundColor Green
Write-Host "  $OutDir" -ForegroundColor Green
Get-ChildItem $OutDir -Filter 'EduScan-*.apk' |
    Select-Object Name, @{N='Size(MB)';E={[math]::Round($_.Length/1MB,1)}} |
    Format-Table -AutoSize
