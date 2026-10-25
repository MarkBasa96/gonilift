# Gonilift installer for Windows. Run by install.bat; safe to run again (it
# skips what is already done).
#
# What it sets up, all inside this folder unless noted:
#   1. uv (Astral's Python manager)      - via winget, or Astral's official script
#   2. Python 3.11 + a private .venv     - by uv
#   3. PyTorch                           - CUDA build with an NVIDIA card, CPU build otherwise
#   4. Gonilift's packages               - from requirements.txt (pinned versions)
#   5. ffmpeg with Rubber Band           - your own if it has Rubber Band, else BtbN's
#                                          GitHub build into tools\ffmpeg, checksum-verified
#   6. "Gonilift" on the Desktop and Start menu (your user only)
param(
    [switch]$Cpu,                  # force the CPU build of PyTorch
    [switch]$ForceFfmpegDownload,  # ignore an ffmpeg already on PATH
    [switch]$NoShortcut            # skip step 6 (used for testing)
)
# Not "Stop": Windows PowerShell 5.1 treats any text a program prints on stderr
# (uv's friendly notes, for example) as a fatal error. Each step checks the
# real exit code instead, via Run.
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"   # makes Invoke-WebRequest much faster
$Root = (Resolve-Path "$PSScriptRoot\..").Path
Set-Location $Root
$TorchVersion = "2.14.1"

function Step($n, $text) { Write-Host ""; Write-Host "[$n/6] $text" -ForegroundColor Magenta }
function Ok($text) { Write-Host "      $text" -ForegroundColor Green }
function Note($text) { Write-Host "      $text" -ForegroundColor DarkGray }
function Run([string]$what, [scriptblock]$cmd) {
    & $cmd
    if ($LASTEXITCODE) { throw "$what failed (exit code $LASTEXITCODE)" }
}
trap { Write-Host ""; Write-Host "  Install stopped: $_" -ForegroundColor Red; Write-Host "  Fix the problem above and run install.bat again; finished steps are skipped." -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "  Gonilift installer" -ForegroundColor Cyan
Write-Host "  Folder: $Root"
$oneDrives = @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial) | Where-Object { $_ }
if ($oneDrives | Where-Object { $Root.StartsWith($_.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) }) {
    Write-Host ""
    Write-Host "  Heads-up: this folder is inside OneDrive. The install is ~5 GB of small files" -ForegroundColor Yellow
    Write-Host "  that OneDrive will try to sync. A folder like C:\Apps\Gonilift works better." -ForegroundColor Yellow
    if ((Read-Host "  Continue here anyway? (y/N)") -notmatch "^[yY]") { exit 1 }
}

# ---- 1. uv -------------------------------------------------------------------
Step 1 "Python manager (uv)"
$uv = (Get-Command uv -ErrorAction SilentlyContinue).Source
if (-not $uv) {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        winget install --id astral-sh.uv -e --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
    } else {
        Note "winget not found; using Astral's official install script"
        Invoke-RestMethod https://astral.sh/uv/install.ps1 -ErrorAction Stop | Invoke-Expression
    }
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "User") + ";" + [Environment]::GetEnvironmentVariable("Path", "Machine") + ";$env:Path"
    $uv = (Get-Command uv -ErrorAction SilentlyContinue).Source
    if (-not $uv) { $uv = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages", "$env:USERPROFILE\.local\bin" -Recurse -Filter uv.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
    if (-not $uv) { throw "Could not install uv. Install it from https://docs.astral.sh/uv/ and run install.bat again." }
}
Ok "uv: $(& $uv --version)"

# ---- 2. Python + .venv -------------------------------------------------------
# The official python.org Python is digitally signed by the Python Software
# Foundation. Antivirus ransomware shields (Trend Micro on a test PC) were far
# harsher on the unsigned Python builds uv installs, so the official one is
# preferred: installed for this user only, without the all-users launcher, so
# no admin prompt appears.
Step 2 "Python 3.11 (official, signed) and a private environment"
$official = Join-Path $env:LOCALAPPDATA "Programs\Python\Python311\python.exe"
if (-not (Test-Path $official) -and (Get-Command winget -ErrorAction SilentlyContinue)) {
    winget install --id Python.Python.3.11 -e --scope user --accept-package-agreements --accept-source-agreements --disable-interactivity `
        --override "/quiet InstallAllUsers=0 Include_launcher=0 InstallLauncherAllUsers=0 PrependPath=0 Include_test=0 Shortcuts=0" | Out-Null
}
if (-not (Test-Path ".venv\Scripts\python.exe")) {
    if ((Test-Path $official) -and (Get-AuthenticodeSignature $official).Status -eq "Valid") {
        Run "Creating .venv" { & $official -m venv .venv }
    } else {
        Note "official Python not available; using uv's Python (works, but some antivirus may be stricter)"
        Run "Installing Python" { & $uv python install 3.11 --quiet }
        Run "Creating .venv" { & $uv venv --python 3.11 --quiet .venv }
    }
}
$env:VIRTUAL_ENV = Join-Path $Root ".venv"
$signed = (Get-AuthenticodeSignature (Join-Path $Root ".venv\Scripts\pythonw.exe")).Status -eq "Valid"
Ok "$(& .venv\Scripts\python.exe --version) in .venv$(if ($signed) { ' (signed)' })"

# ---- 3. PyTorch --------------------------------------------------------------
Step 3 "PyTorch (the AI engine) - the big download, ~2.5 GB with an NVIDIA card"
$nvidia = $false
if (-not $Cpu -and (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) {
    # Read all of nvidia-smi's output first: piping it into Select-Object -First
    # cuts the program off, and it then reports failure (exit -1) on a working card.
    $smi = @(& nvidia-smi --query-gpu=name --format=csv,noheader 2>$null)
    if ($LASTEXITCODE -eq 0 -and $smi.Count -and $smi[0]) { $nvidia = $true; Note "NVIDIA card found: $($smi[0])" }
}
$index = if ($nvidia) { "https://download.pytorch.org/whl/cu126" } else { "https://download.pytorch.org/whl/cpu" }
if (-not $nvidia) { Note "No NVIDIA card found: installing the CPU version (works, but splits take several minutes)" }
# The CPU and CUDA builds share a version number, so uv would call a wrong
# build "already installed". Replace it when it is the other kind.
$have = & .venv\Scripts\python.exe -W ignore -c "import torch; print('cuda' if torch.version.cuda else 'cpu')" 2>$null
$swap = if ($have -and $have -ne $(if ($nvidia) { "cuda" } else { "cpu" })) { @("--reinstall-package", "torch") } else { @() }
Run "PyTorch install" { & $uv pip install "torch==$TorchVersion" --index-url $index @swap }
$cuda = & .venv\Scripts\python.exe -W ignore -c "import torch; print(torch.cuda.is_available())" 2>$null
Ok "PyTorch $TorchVersion, graphics card in use: $cuda"

# ---- 4. Gonilift's packages --------------------------------------------------
Step 4 "Gonilift's packages"
Run "Package install" { & $uv pip install -r requirements.txt }
Ok "installed from requirements.txt"

# ---- 5. ffmpeg ---------------------------------------------------------------
Step 5 "ffmpeg with Rubber Band (reads audio, changes key)"
function Has-Rubberband($exe) {
    try { return [bool]((& $exe -hide_banner -filters 2>$null) -match "\brubberband\b") } catch { return $false }
}
$bundled = Join-Path $Root "tools\ffmpeg\bin\ffmpeg.exe"
$onPath = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
if ((Test-Path $bundled) -and (Has-Rubberband $bundled)) {
    Ok "already set up in tools\ffmpeg"
} elseif (-not $ForceFfmpegDownload -and $onPath -and (Has-Rubberband $onPath)) {
    Ok "using your ffmpeg: $onPath"
} else {
    # Newest stable build from BtbN/FFmpeg-Builds, checked against its published checksum.
    $rel = Invoke-RestMethod "https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/latest" -Headers @{ "User-Agent" = "Gonilift-installer" } -ErrorAction Stop
    $asset = $rel.assets | Where-Object { $_.name -match '^ffmpeg-n(\d+)\.(\d+)-latest-win64-gpl-[\d.]+\.zip$' } |
        Sort-Object { [int]($_.name -replace '^ffmpeg-n(\d+)\.(\d+).*', '$1') }, { [int]($_.name -replace '^ffmpeg-n\d+\.(\d+).*', '$1') } |
        Select-Object -Last 1
    $sums = $rel.assets | Where-Object name -eq "checksums.sha256"
    if (-not $asset -or -not $sums) { throw "Could not find an ffmpeg download on GitHub. Try again later." }
    Note "downloading $($asset.name) ($([int]($asset.size / 1MB)) MB)"
    $tmp = Join-Path $env:TEMP "gonilift-ffmpeg"
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $zip = Join-Path $tmp $asset.name
    Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing -ErrorAction Stop
    # GitHub serves the checksum list as raw bytes, not text: decode it first.
    $raw = (Invoke-WebRequest $sums.browser_download_url -UseBasicParsing -ErrorAction Stop).Content
    $sumsText = if ($raw -is [byte[]]) { [Text.Encoding]::UTF8.GetString($raw) } else { [string]$raw }
    $expected = (@($sumsText -split "`n" | Where-Object { $_ -match [regex]::Escape($asset.name) + '\s*$' })[0]) -replace '\s.*$', ''
    $actual = (Get-FileHash $zip -Algorithm SHA256).Hash
    if (-not $expected -or $actual -ne $expected.ToUpper()) { throw "ffmpeg download failed its checksum check - not using it." }
    Note "checksum OK"
    Expand-Archive $zip -DestinationPath $tmp -Force -ErrorAction Stop
    $bin = Get-ChildItem $tmp -Recurse -Filter ffmpeg.exe | Select-Object -First 1
    Remove-Item (Join-Path $Root "tools\ffmpeg") -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force (Join-Path $Root "tools\ffmpeg") | Out-Null
    Copy-Item $bin.Directory.FullName (Join-Path $Root "tools\ffmpeg\bin") -Recurse -ErrorAction Stop
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Has-Rubberband $bundled)) { throw "The downloaded ffmpeg has no Rubber Band filter." }
    Ok "ffmpeg installed in tools\ffmpeg"
}

# ---- 6. Shortcuts ------------------------------------------------------------
Step 6 "Desktop and Start menu shortcuts"
if ($NoShortcut) { Note "skipped (-NoShortcut)" }
else { & (Join-Path $PSScriptRoot "make-shortcut.ps1") -Root $Root -StartMenu; Ok "double-click Gonilift on your Desktop to start" }

Write-Host ""
Write-Host "  Done! The AI model (~900 MB) downloads the first time you split a song." -ForegroundColor Cyan
Write-Host ""
