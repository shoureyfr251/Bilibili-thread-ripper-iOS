<#
.SYNOPSIS
  Build an installable iOS IPA in one step.
.EXAMPLE
  .\ios\build.ps1 -Diagnostic 17          # diagnostic build v17 -> ios/release/diagnostic/
.EXAMPLE
  .\ios\build.ps1 -Release 1.1            # release build -> ios/release/ (previous release moves to history/)
.NOTES
  Steps: regenerate the embedded JS header, compile and link the dylib (diagnostics/build-windows.ps1),
  package it into the author's 8.89.0 app (diagnostics/prepare-test-ipa.py), move the inspection record
  to ios/release/checksums/, and print size and SHA256. Never signs: install with Sideloadly.
  A release also writes BiliAccel-v<version>.dylib, the public asset (the IPA stays local).
  Prerequisites: .tools/ at the project root (LLVM + iPhoneOS SDK), Python on PATH, and the source app
  at ios/.local/inputs/bili-universal_8.89.0.app.zip (local only, not in git).
#>
[CmdletBinding(DefaultParameterSetName = 'Diagnostic')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Diagnostic')][ValidateRange(1, 9999)][int]$Diagnostic,
    [Parameter(Mandatory, ParameterSetName = 'Release')][ValidatePattern('^\d+(\.\d+)+$')][string]$Release
)
$ErrorActionPreference = 'Stop'
$ios = $PSScriptRoot                                                   # ios/source/ios
$projectRoot = [IO.Path]::GetFullPath((Join-Path $ios '../../..'))
$releaseDir = Join-Path $projectRoot 'ios/release'
$sourceApp = Join-Path $ios '.local/inputs/bili-universal_8.89.0.app.zip'
if (-not (Test-Path -LiteralPath $sourceApp)) { throw "Missing source app: $sourceApp" }

if ($PSCmdlet.ParameterSetName -eq 'Release') {
    $name = "Bilibili-8.89.0-BTR-accel-$Release-unsigned"
    $buildDir = Join-Path $ios "build/release-$Release"
    $outputDir = $releaseDir
    $buildArgs = @{ Release = $true; Version = $Release }
    $packageArgs = @('--display-name', 'B站加速')   # end-user UI text, kept in Chinese
} else {
    $name = "Bilibili-8.89.0-BTR-diagnostic-v$Diagnostic-unsigned"
    $buildDir = Join-Path $ios "build/v$Diagnostic"
    $outputDir = Join-Path $releaseDir 'diagnostic'
    $buildArgs = @{ ProbeRevision = $Diagnostic }
    $packageArgs = @()
}
$ipa = Join-Path $outputDir "$name.ipa"
if (Test-Path -LiteralPath $ipa) { throw "Already exists, pick a new version: $ipa" }

Write-Host '1/4 Regenerating embedded JS header'
python -I (Join-Path $ios 'generate-scripts.py'); if ($LASTEXITCODE) { throw 'generate-scripts.py failed' }

Write-Host '2/4 Compiling and linking'
& (Join-Path $ios 'diagnostics/build-windows.ps1') -OutputDir $buildDir @buildArgs | Out-Null
$build = Get-Content -LiteralPath (Join-Path $buildDir 'build-windows.json') -Raw | ConvertFrom-Json

Write-Host '3/4 Packaging'
if ($PSCmdlet.ParameterSetName -eq 'Release') {
    # Exactly one current release at the top level; older ones go to history/.
    New-Item -ItemType Directory -Force -Path (Join-Path $releaseDir 'history') | Out-Null
    Get-ChildItem -LiteralPath $releaseDir -File | Where-Object Extension -in '.ipa', '.dylib' |
        Move-Item -Destination (Join-Path $releaseDir 'history')
}
python -I (Join-Path $ios 'diagnostics/prepare-test-ipa.py') --source-app-zip $sourceApp `
    --probe (Join-Path $buildDir 'libBTRProcessProbe.dylib') --output $ipa @packageArgs | Out-Null
if ($LASTEXITCODE) { throw 'prepare-test-ipa.py failed' }

Write-Host '4/4 Recording checksums'
$inspectionSource = Join-Path $outputDir "$name.inspection.json"
$inspection = Join-Path $releaseDir "checksums/$name.inspection.json"
New-Item -ItemType Directory -Force -Path (Split-Path $inspection) | Out-Null
Move-Item -LiteralPath $inspectionSource -Destination $inspection -Force
$record = Get-Content -LiteralPath $inspection -Raw | ConvertFrom-Json
if ($record.probe_sha256 -ne $build.dylib_sha256) { throw 'Packaged probe does not match the build' }
$dylib = $null
if ($PSCmdlet.ParameterSetName -eq 'Release') {
    # Public asset: users inject it into their own 8.89.0 IPA with Sideloadly (the app is never redistributed).
    $dylib = Join-Path $releaseDir "BiliAccel-v$Release.dylib"
    Copy-Item -LiteralPath (Join-Path $buildDir 'libBTRProcessProbe.dylib') -Destination $dylib
}

[pscustomobject]@{
    ipa = $ipa
    bytes = (Get-Item -LiteralPath $ipa).Length
    sha256 = $record.output_sha256
    probe_sha256 = $build.dylib_sha256
    dylib = $dylib
} | Format-List
