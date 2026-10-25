# Builds the ready-to-run edition: one folder with its own Python, the AI
# engine, ffmpeg and the vocal model inside, so buyers unzip it and start
# Gonilift with no installer and no downloads. Run it from a working install
# (after install.bat), on Windows:
#
#   powershell -ExecutionPolicy Bypass -File tools\build-portable.ps1 -Out C:\Builds
#
# Result: <Out>\Gonilift\ (the folder) and <Out>\Gonilift-<version>-Windows.zip
param(
    [Parameter(Mandatory)][string]$Out,
    [string]$Version = "1.0",
    [switch]$NoZip
)
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
$Root = (Resolve-Path "$PSScriptRoot\..").Path
$Model = "vocals_mel_band_roformer"

function Ok($text) { Write-Host "  $text" -ForegroundColor Green }
function Copy-Tree($from, $to, [string[]]$extra) {
    # robocopy: exit codes below 8 mean success
    robocopy $from $to /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 @extra | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copy failed: $from (robocopy $LASTEXITCODE)" }
}
trap { Write-Host "  Build stopped: $_" -ForegroundColor Red; exit 1 }

$pyHome = ((Get-Content (Join-Path $Root ".venv\pyvenv.cfg")) -match '^home\s*=' -replace '^home\s*=\s*', '').Trim()
if (-not (Test-Path "$pyHome\pythonw.exe")) { throw "Base Python not found at $pyHome" }
if ((Get-AuthenticodeSignature "$pyHome\pythonw.exe").Status -ne "Valid") { throw "Base Python is not the signed python.org build" }
foreach ($f in "$Model.ckpt", "$Model.yaml") {
    if (-not (Test-Path "$Root\models\$f")) { throw "models\$f missing: split one song first so it downloads" }
}

New-Item -ItemType Directory -Force $Out | Out-Null
$Dist = Join-Path (Resolve-Path $Out).Path "Gonilift"
if (Test-Path $Dist) { throw "$Dist already exists: remove it or pick another -Out" }

# 1. Gonilift itself, exactly as committed (no songs, logs or caches)
$archive = Join-Path $env:TEMP "gonilift-src.zip"
git -C $Root archive --format=zip -o $archive HEAD -- app gonilift.ico LICENSE THIRD-PARTY.md tools/make-shortcut.ps1
if ($LASTEXITCODE) { throw "git archive failed" }
Expand-Archive $archive $Dist
Remove-Item $archive
Ok "app files"

# 2. Python: the signed python.org build, made self-contained. The ._pth file
# fixes its search path to this folder only, ignoring any other Python on the PC.
$rt = Join-Path $Dist "runtime"
Copy-Tree $pyHome $rt @("/XD", "$pyHome\Lib\site-packages", "$pyHome\Lib\test", "$pyHome\Doc", "$pyHome\Tools", "$pyHome\Scripts", "$pyHome\include", "$pyHome\libs", "__pycache__")
Copy-Tree (Join-Path $Root ".venv\Lib\site-packages") "$rt\Lib\site-packages" @("/XD", "__pycache__", "include", "pip", "/XF", "*.lib", "*.pdb")
# python311.dll, not the python3.dll forwarder next to it (a wrongly named ._pth is ignored)
$pyDll = (Get-ChildItem $rt -Filter "python3*.dll" | Where-Object Name -match '^python3\d+\.dll$' | Select-Object -First 1).BaseName
if (-not $pyDll) { throw "python3XX.dll not found in the runtime" }
Set-Content "$rt\$pyDll._pth" "$pyDll.zip`r`nDLLs`r`nLib`r`nLib\site-packages`r`nimport site" -Encoding ascii
Ok "Python runtime ($pyDll)"

# 3. ffmpeg with Rubber Band: the copy install.bat put in tools\ffmpeg, else
# the newest stable BtbN build, checked against its published checksum.
$ff = Join-Path $Dist "tools\ffmpeg\bin"
if (Test-Path "$Root\tools\ffmpeg\bin\ffmpeg.exe") {
    Copy-Tree "$Root\tools\ffmpeg\bin" $ff @()
} else {
    $rel = Invoke-RestMethod "https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/latest" -Headers @{ "User-Agent" = "Gonilift-build" } -ErrorAction Stop
    $asset = $rel.assets | Where-Object { $_.name -match '^ffmpeg-n(\d+)\.(\d+)-latest-win64-gpl-[\d.]+\.zip$' } |
        Sort-Object { [int]($_.name -replace '^ffmpeg-n(\d+)\.(\d+).*', '$1') }, { [int]($_.name -replace '^ffmpeg-n\d+\.(\d+).*', '$1') } |
        Select-Object -Last 1
    $sums = $rel.assets | Where-Object name -eq "checksums.sha256"
    if (-not $asset -or -not $sums) { throw "No ffmpeg download found on GitHub" }
    $tmp = Join-Path $env:TEMP "gonilift-build-ffmpeg"
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $zip = Join-Path $tmp $asset.name
    Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing -ErrorAction Stop
    $raw = (Invoke-WebRequest $sums.browser_download_url -UseBasicParsing -ErrorAction Stop).Content
    $sumsText = if ($raw -is [byte[]]) { [Text.Encoding]::UTF8.GetString($raw) } else { [string]$raw }
    $expected = (@($sumsText -split "`n" | Where-Object { $_ -match [regex]::Escape($asset.name) + '\s*$' })[0]) -replace '\s.*$', ''
    if (-not $expected -or (Get-FileHash $zip -Algorithm SHA256).Hash -ne $expected.ToUpper()) { throw "ffmpeg failed its checksum check" }
    Expand-Archive $zip -DestinationPath $tmp -Force -ErrorAction Stop
    $bin = Get-ChildItem $tmp -Recurse -Filter ffmpeg.exe | Select-Object -First 1
    New-Item -ItemType Directory -Force $ff | Out-Null
    Copy-Item "$($bin.Directory.FullName)\*" $ff -ErrorAction Stop
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Ok "ffmpeg $($asset.name) (checksum OK)"
}
if (-not ((& "$ff\ffmpeg.exe" -hide_banner -filters 2>$null) -match "\brubberband\b")) { throw "ffmpeg has no Rubber Band filter" }

# 4. The vocal model (MIT, Kimberley Jensen), so the first split needs no internet
New-Item -ItemType Directory -Force "$Dist\models" | Out-Null
foreach ($f in "$Model.ckpt", "$Model.yaml", "download_checks.json") {
    if (Test-Path "$Root\models\$f") { Copy-Item "$Root\models\$f" "$Dist\models\" }
}
Ok "vocal model"

# 5. How to start it
Set-Content "$Dist\Gonilift.bat" -Encoding ascii @'
@echo off
rem Starts Gonilift. Double-click this file.
start "" "%~dp0runtime\pythonw.exe" "%~dp0app\desktop.py"
'@
Set-Content "$Dist\Add Gonilift to Desktop and Start menu.bat" -Encoding ascii @'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\make-shortcut.ps1" -StartMenu
echo.
echo Done. You can now start Gonilift from the Desktop or the Start menu.
pause
'@
Set-Content "$Dist\READ ME FIRST.txt" -Encoding utf8 @"
Gonilift $Version - ready-to-run edition for Windows 10 and 11

1. Keep this whole folder somewhere permanent, for example C:\Gonilift
   (not inside OneDrive, and not in Downloads if you clean that out).
2. Double-click "Gonilift.bat" to start.
3. Optional: double-click "Add Gonilift to Desktop and Start menu.bat"
   for a normal app icon you can pin to the taskbar.

Everything is already inside: no installer, no account, no internet needed.
An NVIDIA graphics card makes splitting fast (about 40 seconds a song);
without one it still works, just slower (several minutes a song).

Your songs are kept in the "songs" folder here. To uninstall, delete this
folder and the shortcuts.

Help: https://github.com/MarkBasa96/gonilift/issues
Website: https://markbasa96.github.io/gonilift/
Licences: LICENSE (Gonilift, MIT) and THIRD-PARTY.md (the AI model and other parts).
"@
Ok "launcher and read-me"

$size = (Get-ChildItem $Dist -Recurse -File | Measure-Object Length -Sum).Sum
Ok ("folder ready: {0} ({1:N1} GB)" -f $Dist, ($size / 1GB))

if (-not $NoZip) {
    $zipOut = Join-Path (Split-Path $Dist) "Gonilift-$Version-Windows.zip"
    Remove-Item $zipOut -ErrorAction SilentlyContinue
    tar.exe -a -c -f $zipOut -C (Split-Path $Dist) Gonilift
    if ($LASTEXITCODE) { throw "zip failed" }
    Ok ("zip ready: {0} ({1:N1} GB)" -f $zipOut, ((Get-Item $zipOut).Length / 1GB))
}
