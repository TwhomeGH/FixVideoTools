param(
    [Parameter(Mandatory=$true)]
    [string]$InputFile,
    [Parameter(Mandatory=$true)]
    [string]$OutputFile,
    [double]$ManualOffset,
    [switch]$Force,
    [switch]$DelayVideo,
    [switch]$CheckOnly
)

$ffmpeg = "ffmpeg"
$ffprobe = "ffprobe"

if (-not (Get-Command $ffprobe -ErrorAction SilentlyContinue)) {
    Write-Error "ffprobe not found in PATH"
    exit 1
}

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  A/V Alignment Tool v1.0" -ForegroundColor Cyan
Write-Host "  Measure and correct A/V start offset" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""

# Get stream info
$json = ffprobe -v quiet -print_format json -show_streams $InputFile 2>$null | ConvertFrom-Json
$v = $json.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
$a = $json.streams | Where-Object { $_.codec_type -eq "audio" } | Select-Object -First 1

if (-not $v -or -not $a) {
    Write-Error "File must contain both video and audio streams"
    exit 1
}

# Measure first PTS for each stream
Write-Host "Measuring A/V start offset..." -ForegroundColor Cyan
$vFirst = ffprobe -v quiet -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 $InputFile 2>$null | Select-Object -First 1
$aFirst = ffprobe -v quiet -select_streams a:0 -show_entries packet=pts_time -of csv=p=0 $InputFile 2>$null | Select-Object -First 1

if (-not $vFirst -or -not $aFirst) {
    Write-Error "Could not read PTS values"
    exit 1
}

$vPts = [double]$vFirst
$aPts = [double]$aFirst

Write-Host ("  Video first PTS: {0:f4}s" -f $vPts)
Write-Host ("  Audio first PTS: {0:f4}s" -f $aPts)

$offset = $aPts - $vPts
if ($offset -gt 0) {
    Write-Host ("  Audio is ahead of video by {0:f4}s" -f $offset) -ForegroundColor Yellow
} elseif ($offset -lt 0) {
    Write-Host ("  Video is ahead of audio by {0:f4}s" -f [math]::Abs($offset)) -ForegroundColor Yellow
} else {
    Write-Host ("  A/V start is already aligned (diff=0s)") -ForegroundColor Green
}

if ($CheckOnly) {
    Write-Host "`nCheck complete."
    exit 0
}

# Apply alignment
if (-not $Force -and (Test-Path $OutputFile)) {
    Write-Error "Output file exists. Use -Force to overwrite."
    exit 1
}

if ($ManualOffset -and $ManualOffset -ne 0) {
    $offset = $ManualOffset
    Write-Host ("`nUsing manual offset: {0:f4}s" -f $offset) -ForegroundColor Cyan
}

if ([math]::Abs($offset) -lt 0.001) {
    Write-Host "`nNo alignment needed. Copying file..."
    Copy-Item $InputFile $OutputFile -Force
    Write-Host "Done."
    exit 0
}

# Determine which stream to delay
# Positive offset = audio ahead → delay video (or delay audio by -offset)
# Negative offset = video ahead → delay audio by offset
Write-Host "`nApplying alignment..." -ForegroundColor Cyan

if ($DelayVideo) {
    # Delay video by the offset
    Write-Host ("  Delaying video by {0:f4}s..." -f $offset)
    ffmpeg -i $InputFile -itsoffset $offset -i $InputFile -map 1:v -map 0:a -c copy -y $OutputFile 2>&1
} else {
    # Default: delay audio by the offset
    Write-Host ("  Delaying audio by {0:f4}s..." -f $offset)
    ffmpeg -i $InputFile -itsoffset $offset -i $InputFile -map 0:v -map 1:a -c copy -y $OutputFile 2>&1
}

# Verify
if (Test-Path $OutputFile) {
    $vNew = ffprobe -v quiet -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 $OutputFile 2>$null | Select-Object -First 1
    $aNew = ffprobe -v quiet -select_streams a:0 -show_entries packet=pts_time -of csv=p=0 $OutputFile 2>$null | Select-Object -First 1
    $newDiff = [math]::Abs([double]$vNew - [double]$aNew)
    $status = if ($newDiff -le 0.1) { "OK" } else { "WARNING: residual offset $([math]::Round($newDiff,4))s" }
    Write-Host ("  A/V start diff after fix: {0:f4}s  [{1}]" -f $newDiff, $status) -ForegroundColor Green
}
