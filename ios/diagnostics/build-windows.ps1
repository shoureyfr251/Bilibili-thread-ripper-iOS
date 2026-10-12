[CmdletBinding()]
param(
    [string]$LLVMRoot,
    [string]$SDKPath,
    [string]$OutputDir = (Join-Path $PSScriptRoot '../build'),
    [switch]$Release, # Built-in acceleration, no diagnostic button/menu.
    [int]$ProbeRevision = 0 # Diagnostic version shown in the menu and reports.
)
$ErrorActionPreference = 'Stop'

# Tools and SDK are local prerequisites; this script never downloads or signs.
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../..'))
if (-not $LLVMRoot) { $LLVMRoot = Join-Path $projectRoot '.tools/llvm-20.1.8-portable' }
if (-not $SDKPath) { $SDKPath = Join-Path $projectRoot '.tools/ios-sdks/iPhoneOS16.5.sdk' }
$LLVMRoot = [IO.Path]::GetFullPath($LLVMRoot)
$SDKPath = [IO.Path]::GetFullPath($SDKPath)
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
if (-not $OutputDir.StartsWith('D:\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Build output must be on D: per project instructions.'
}
$clang = Join-Path $LLVMRoot 'bin/clang.exe'
$linker = Join-Path $LLVMRoot 'bin/ld64.lld.exe'
$objdump = Join-Path $LLVMRoot 'bin/llvm-objdump.exe'
foreach ($required in @($clang, $linker, $objdump,
    (Join-Path $SDKPath 'usr/lib/libSystem.tbd'), (Join-Path $SDKPath 'usr/lib/libobjc.tbd'))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf) -or
        (Get-Item -LiteralPath $required).Length -eq 0) { throw "Missing prerequisite: $required" }
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$source = Join-Path $PSScriptRoot 'BTRProcessProbe.m'
$iosRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sources = @($source, (Join-Path $PSScriptRoot 'BTRSelfTest.m'), (Join-Path $iosRoot 'BTRRangeDownloader.m'), (Join-Path $iosRoot 'BTRJSEngine.m'),
    (Join-Path $iosRoot 'BTRLoopbackRangeAdapter.m'))
$inputs = $sources + @((Join-Path $PSScriptRoot 'BTRProcessProbe.h'), (Join-Path $PSScriptRoot 'BTRSelfTest.h'),
    (Join-Path $iosRoot 'BTRRangeDownloader.h'), (Join-Path $iosRoot 'BTRLoopbackRangeAdapter.h'),
    (Join-Path $iosRoot 'BTRScripts.generated.h'), (Join-Path $iosRoot 'policy.js'),
    (Join-Path $iosRoot 'loopback-http.js'), (Join-Path $iosRoot '../src/range-core.js'),
    (Join-Path $iosRoot 'BTRJSEngine.h'), (Join-Path $iosRoot 'js/shims.js'), (Join-Path $iosRoot 'js/engine-prelude.js'),
    (Join-Path $iosRoot 'js/engine.js'), (Join-Path $iosRoot 'js/desktop/range-core.js'), (Join-Path $iosRoot 'js/desktop/cdn-resolver.js'),
    (Join-Path $iosRoot 'js/desktop/idm-downloader.js'))
foreach ($inputPath in $inputs) {
    if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) { throw "Missing source input: $inputPath" }
}
$objects = @()
$dylib = Join-Path $OutputDir 'libBTRProcessProbe.dylib'
$log = Join-Path $OutputDir 'build-windows.log'
Set-Content -LiteralPath $log -Value '' -Encoding utf8
foreach ($sourcePath in $sources) {
    $object = Join-Path $OutputDir ([IO.Path]::GetFileNameWithoutExtension($sourcePath) + '.o')
    $objects += $object
    $compileArgs = @('-target', 'arm64-apple-ios15.0', '-isysroot', $SDKPath,
        '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Wno-unused-parameter', "-DBTR_RELEASE=$([int][bool]$Release)", "-DBTR_PROBE_REVISION=$ProbeRevision",
        '-c', $sourcePath, '-o', $object)
    & $clang @compileArgs 2>&1 | Tee-Object -FilePath $log -Append
    if ($LASTEXITCODE -ne 0) { throw "Clang failed; see $log" }
}
$linkArgs = @('-arch', 'arm64', '-platform_version', 'ios', '15.0', '16.5',
    '-dylib', '-syslibroot', $SDKPath, '-framework', 'Foundation',
    '-framework', 'UIKit', '-framework', 'AVFoundation', '-framework', 'JavaScriptCore', '-lobjc', '-lSystem',
    '-install_name', '@rpath/libBTRProcessProbe.dylib') + $objects + @('-o', $dylib)
& $linker @linkArgs 2>&1 | Tee-Object -FilePath $log -Append
if ($LASTEXITCODE -ne 0) { throw "LLD failed; see $log" }
$headers = (& $objdump --macho --private-headers $dylib 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'Mach-O inspection failed.' }
if ($headers -notmatch 'MH_MAGIC_64\s+ARM64.*DYLIB' -or
    $headers -notmatch 'platform ios' -or $headers -notmatch 'minos 15\.0' -or
    $headers -notmatch 'sdk 16\.5' -or $headers -match 'LC_CODE_SIGNATURE') {
    throw 'Unexpected architecture, platform, deployment target, SDK, or signature.'
}
$names = [regex]::Matches($headers, '(?m)^\s+name (.+) \(offset') |
    ForEach-Object { $_.Groups[1].Value }
foreach ($name in $names) {
    if ($name -notmatch '^(@rpath/libBTRProcessProbe\.dylib|/System/Library/|/usr/lib/)') {
        throw "Unexpected dylib load path: $name"
    }
}
$headers | Set-Content -LiteralPath (Join-Path $OutputDir 'macho-headers.txt') -Encoding utf8
& $objdump --macho --chained-fixups $dylib |
    Set-Content -LiteralPath (Join-Path $OutputDir 'macho-bindings.txt') -Encoding utf8
if ($LASTEXITCODE -ne 0) { throw 'Import inspection failed.' }
$inputHashes = @{}
foreach ($inputPath in $inputs) {
    $inputHashes[[IO.Path]::GetRelativePath($iosRoot, $inputPath)] =
        (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash.ToLowerInvariant()
}
@{
    source_sha256 = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    source_hashes = $inputHashes
    dylib_sha256 = (Get-FileHash -LiteralPath $dylib -Algorithm SHA256).Hash.ToLowerInvariant()
    bytes = (Get-Item -LiteralPath $dylib).Length
    target = 'arm64-apple-ios15.0'; sdk = '16.5'; signed = $false; release = [bool]$Release; probe_revision = $ProbeRevision
    llvm = (& $linker --version) -join ' '; dependencies = @($names)
    validation = 'Compiled and statically inspected on Windows; device loading and behavior untested.'
} | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $OutputDir 'build-windows.json') -Encoding utf8
Write-Output "$dylib (unsigned; requires signing and iPhone validation)"
