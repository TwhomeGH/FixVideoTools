param(
    [Parameter(Mandatory=$true)]
    [string]$InputFile,
    [Parameter(Mandatory=$true)]
    [string]$OutputFile,
    [Parameter(ParameterSetName="time")]
    [string]$StartTime,
    [Parameter(ParameterSetName="time")]
    [string]$EndTime,
    [Parameter(ParameterSetName="duration")]
    [double]$Duration,
    [switch]$Force,
    [switch]$KeepTemp
)

$ffmpeg = "ffmpeg"
$ffprobe = "ffprobe"

if (-not (Get-Command $ffmpeg -ErrorAction SilentlyContinue)) {
    Write-Error "ffmpeg not found in PATH"
    exit 1
}

if (-not $StartTime) { $StartTime = "0" }

function To-Seconds {
    param([string]$Time)
    if ($Time -match "^(\d+):(\d+):(\d+)") {
        return [double]$matches[1] * 3600 + [double]$matches[2] * 60 + [double]$matches[3]
    }
    return [double]$Time
}

$startSec = To-Seconds $StartTime
$endSec = if ($EndTime) { To-Seconds $EndTime } elseif ($Duration) { $startSec + $Duration } else { 0 }

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  Hybrid Cut Tool v1.1" -ForegroundColor Cyan
Write-Host "  Precise stream copy cutting with PTS-aligned A/V content" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""

if (-not $Force -and (Test-Path $OutputFile)) {
    Write-Error "Output file exists. Use -Force to overwrite."
    exit 1
}

$tmpDir = [System.IO.Path]::GetTempPath()
$seekBack = [math]::Max(30, $startSec * 0.01)
$inputSeek = [math]::Max(0, $startSec - $seekBack)

Write-Host ("Input:  {0}" -f $InputFile) -ForegroundColor Yellow
Write-Host ("Output: {0}" -f $OutputFile) -ForegroundColor Yellow
Write-Host ("Seek:   {0}s (keyframe at ~{1}s)" -f $startSec, $inputSeek)
if ($endSec -gt 0) { Write-Host ("End:    {0}s (duration: {1}s)" -f $endSec, ($endSec - $startSec)) }
Write-Host ""

# Step 1: Cut video stream independently
$tempVideo = Join-Path $tmpDir "hcut_$([System.IO.Path]::GetRandomFileName()).mp4"
Write-Host "Step 1/2: Cutting video at PTS $startSec..." -ForegroundColor Cyan
$endArgV = if ($endSec -gt 0) { "-to $endSec" } else { "" }
ffmpeg -ss $inputSeek -copyts -i $InputFile -map 0:v -c copy -ss $startSec $endArgV -y $tempVideo 2>&1 | ForEach-Object {
    if ($_ -match "time=(\d+:\d+:\d+\.\d+)") {
        Write-Progress -Activity "Cutting video" -Status $matches[1]
    }
}
Write-Progress -Activity "Cutting video" -Completed
if (-not (Test-Path $tempVideo)) { Write-Error "Step 1 failed"; exit 1 }

# Measure first video frame's original PTS (preserved by -copyts)
$vFirstOrigPts = ffprobe -v quiet -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 $tempVideo 2>$null | Select-Object -First 1
if (-not $vFirstOrigPts) { Write-Error "Cannot read video PTS"; exit 1 }
Write-Host ("  First video frame at original PTS {0:f4}s" -f $vFirstOrigPts)

# Step 2: Cut audio stream at the same original PTS
$tempAudio = Join-Path $tmpDir "hcut_$([System.IO.Path]::GetRandomFileName()).mp4"
Write-Host ("Step 2/2: Cutting audio at same PTS {0:f4}s..." -f $vFirstOrigPts) -ForegroundColor Cyan
$endArgA = if ($endSec -gt 0) { "-to $endSec" } else { "" }
ffmpeg -ss $inputSeek -copyts -i $InputFile -map 0:a -c copy -ss $vFirstOrigPts $endArgA -y $tempAudio 2>&1 | ForEach-Object {
    if ($_ -match "time=(\d+:\d+:\d+\.\d+)") {
        Write-Progress -Activity "Cutting audio" -Status $matches[1]
    }
}
Write-Progress -Activity "Cutting audio" -Completed
if (-not (Test-Path $tempAudio)) { Write-Error "Step 2 failed"; exit 1 }

# Combine
Write-Host "Muxing final output..." -ForegroundColor Cyan
ffmpeg -i $tempVideo -i $tempAudio -c copy -y $OutputFile 2>&1 | ForEach-Object {
    if ($_ -match "time=(\d+:\d+:\d+\.\d+)") {
        Write-Progress -Activity "Muxing" -Status $matches[1]
    }
}
Write-Progress -Activity "Muxing" -Completed

# Cleanup
if (-not $KeepTemp) { Remove-Item $tempVideo, $tempAudio -Force -ErrorAction SilentlyContinue }

# Verify
if (Test-Path $OutputFile) {
    $vFinal = ffprobe -v quiet -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 $OutputFile 2>$null | Select-Object -First 1
    $aFinal = ffprobe -v quiet -select_streams a:0 -show_entries packet=pts_time -of csv=p=0 $OutputFile 2>$null | Select-Object -First 1
    $size = [math]::Round((Get-Item $OutputFile).Length / 1MB, 0)
    $diff = [math]::Abs([double]$vFinal - [double]$aFinal)
    $status = if ($diff -le 0.1) { "OK" } else { "OFFSET: $([math]::Round($diff,3))s" }
    Write-Host ("`nOutput: {0} ({1}MB) A/V start diff: {2}" -f $OutputFile, $size, $status) -ForegroundColor Green
} else {
    Write-Error "Output not created"
}
