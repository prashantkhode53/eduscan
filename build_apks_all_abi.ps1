# =============================================================================
#  EduScan — build BOTH apps (Academy + Parent) for ALL ABIs + the UNIVERSAL
#  APK, in one command.
#
#  For each flavor this produces:
#    * three per-ABI APKs (arm64-v8a, armeabi-v7a, x86_64)
#    * one universal APK (all ABIs in a single ~98 MB file that installs on
#      any device)
#  each copied out with a unique, role-identifying name so nothing is
#  overwritten and you never rename anything.
#
#  This is the SLOWER build (it compiles all three CPU architectures, twice —
#  once split, once universal). For the fast, smallest build that covers 99%
#  of modern phones, use build_apks.ps1 (arm64 only) instead.
#
#  Usage (from the project root, in PowerShell):
#       .\build_apks_all_abi.ps1
#
#  Output (same folder, ready to copy):
#       EduScan-Academy-arm64-v8a.apk
#       EduScan-Academy-armeabi-v7a.apk
#       EduScan-Academy-x86_64.apk
#       EduScan-Academy-universal.apk
#       EduScan-Parent-arm64-v8a.apk
#       EduScan-Parent-armeabi-v7a.apk
#       EduScan-Parent-x86_64.apk
#       EduScan-Parent-universal.apk
#
#  Only the login that opens differs between Academy and Parent; Firebase,
#  applicationId and every feature are identical (see lib/config/app_mode.dart).
# =============================================================================

$ErrorActionPreference = 'Stop'

$OutDir = Join-Path $PSScriptRoot 'build\app\outputs\flutter-apk'

# The per-ABI files Flutter produces from a split build (no --target-platform).
$Abis = @('arm64-v8a', 'armeabi-v7a', 'x86_64')

# Each flavor: APP_MODE define + the role label used in output file names.
$Flavors = @(
    @{ Name = 'Academy'; Mode = 'academy' },
    @{ Name = 'Parent';  Mode = 'parent'  }
)

foreach ($f in $Flavors) {
    Write-Host ''
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host " Building $($f.Name) APKs (ALL ABIs)  APP_MODE=$($f.Mode)" -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan

    # ── 1) Per-ABI split APKs ────────────────────────────────────────────────
    flutter build apk --release --split-per-abi --dart-define=APP_MODE=$($f.Mode)
    if ($LASTEXITCODE -ne 0) {
        Write-Host "BUILD FAILED (split) for $($f.Name). Stopping." -ForegroundColor Red
        exit 1
    }

    foreach ($abi in $Abis) {
        $raw = Join-Path $OutDir "app-$abi-release.apk"
        if (-not (Test-Path $raw)) {
            Write-Host "  Expected APK not found: $raw" -ForegroundColor Red
            exit 1
        }
        $dest = Join-Path $OutDir "EduScan-$($f.Name)-$abi.apk"
        Copy-Item -Path $raw -Destination $dest -Force
        $sizeMB = [math]::Round((Get-Item $dest).Length / 1MB, 1)
        Write-Host "  -> EduScan-$($f.Name)-$abi.apk  ($sizeMB MB)" -ForegroundColor Green
    }

    # ── 2) Universal APK (all ABIs in one file) ──────────────────────────────
    # A plain build (no --split-per-abi) yields the single fat app-release.apk.
    flutter build apk --release --dart-define=APP_MODE=$($f.Mode)
    if ($LASTEXITCODE -ne 0) {
        Write-Host "BUILD FAILED (universal) for $($f.Name). Stopping." -ForegroundColor Red
        exit 1
    }

    $rawUniversal = Join-Path $OutDir 'app-release.apk'
    if (-not (Test-Path $rawUniversal)) {
        Write-Host "  Expected universal APK not found: $rawUniversal" -ForegroundColor Red
        exit 1
    }
    $destUniversal = Join-Path $OutDir "EduScan-$($f.Name)-universal.apk"
    Copy-Item -Path $rawUniversal -Destination $destUniversal -Force
    $sizeMB = [math]::Round((Get-Item $destUniversal).Length / 1MB, 1)
    Write-Host "  -> EduScan-$($f.Name)-universal.apk  ($sizeMB MB)" -ForegroundColor Green
}

Write-Host ''
Write-Host "DONE. All-ABI APKs are in:" -ForegroundColor Green
Write-Host "  $OutDir" -ForegroundColor Green
Get-ChildItem $OutDir -Filter 'EduScan-*.apk' |
    Select-Object Name, @{N='Size(MB)';E={[math]::Round($_.Length/1MB,1)}} |
    Format-Table -AutoSize
