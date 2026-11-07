param([switch]$SkipTests)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'Dependency resolution failed.' }
    if (-not $SkipTests) {
        $testFiles = @(Get-ChildItem -Path test -Filter '*_test.dart' |
            Where-Object { $_.Name -notlike '*_live_test.dart' } |
            Select-Object -ExpandProperty FullName)
        flutter test --no-pub @testFiles
        if ($LASTEXITCODE -ne 0) { throw 'Tests failed.' }
    }
    # The catalog relay key: without it there are no official songs, artist
    # pages or Discover (plain YouTube only). Read from relay/.dev.vars.
    $relayKey = $env:MUZIKA_RELAY_KEY
    $devVars = Join-Path $projectRoot 'relay\.dev.vars'
    if (-not $relayKey -and (Test-Path -LiteralPath $devVars)) {
        $line = Get-Content -LiteralPath $devVars | Where-Object { $_ -match '^\s*MUZIKA_KEY\s*=' } | Select-Object -First 1
        if ($line) { $relayKey = ($line -split '=', 2)[1].Trim().Trim('"') }
    }
    if (-not $relayKey) { throw 'MUZIKA_RELAY_KEY not found (set it or add MUZIKA_KEY to relay\.dev.vars).' }
    flutter build windows --release "--dart-define=MUZIKA_RELAY_KEY=$relayKey"
    if ($LASTEXITCODE -ne 0) { throw 'Windows build failed.' }

    $bundle = Join-Path $projectRoot 'build\windows\x64\runner\Release'
    # A debug run leaves its 120 MB kernel_blob.bin behind; release never uses it.
    Remove-Item -LiteralPath (Join-Path $bundle 'data\flutter_assets\kernel_blob.bin') -ErrorAction SilentlyContinue
    # Bundle Microsoft's redistributable C++ DLLs beside the executable.
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($visualStudio) {
            $redistRoot = Join-Path $visualStudio 'VC\Redist\MSVC'
            $crt = Get-ChildItem -LiteralPath $redistRoot -Filter 'Microsoft.VC*.CRT' -Directory -Recurse |
                Where-Object { $_.FullName -match '\\x64\\' } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($crt) {
                Get-ChildItem -LiteralPath $crt.FullName -Filter '*.dll' |
                    Copy-Item -Destination $bundle -Force
            }
        }
    }
    Copy-Item -LiteralPath (Join-Path $projectRoot 'LICENSE') -Destination $bundle
    Copy-Item -LiteralPath (Join-Path $projectRoot 'windows\PORTABLE.txt') -Destination $bundle
    $archive = Join-Path $projectRoot 'build\Muzika-Windows-x64.zip'
    Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $archive -Force
    Write-Output "Windows package: $archive"
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $launcher = Join-Path $projectRoot 'build\Muzika.exe'
    $launcherSource = Join-Path $projectRoot 'windows\portable_launcher.cs'
    $launcherIcon = Join-Path $projectRoot 'windows\runner\resources\app_icon.ico'
    & $compiler /nologo /target:winexe /platform:x64 /optimize+ "/out:$launcher" "/win32icon:$launcherIcon" /reference:System.IO.Compression.dll /reference:System.Windows.Forms.dll "/resource:$archive,MuzikaBundle.zip" $launcherSource
    if ($LASTEXITCODE -ne 0) { throw 'Single-file Windows packaging failed.' }
    Write-Output "Windows executable: $launcher"
} finally {
    Pop-Location
}
