param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$InputFile,

    [Parameter(Position=1)]
    [string]$OutputFile,
    [string]$OutputDir,

    [ValidateSet("fast", "medium", "slow", "veryslow")]
    [string]$Preset = "medium",

    [int]$CRF = 45,

    [switch]$Force,
    [switch]$DryRun,
    [switch]$NoCleanup
)

function Write-Step {
    param([string]$Msg, [string]$Color)
    Write-Host ">>> $Msg" -ForegroundColor $Color
}

function Test-FFmpeg {
    if (-not (ffmpeg -version 2>&1 | Select-Object -First 1)) {
        Write-Host "ERROR: ffmpeg not found" -ForegroundColor Red; exit 1
    }
    $av1 = ffmpeg -encoders 2>$null | Select-String "libsvtav1"
    if (-not $av1) {
        Write-Host "ERROR: libsvtav1 not in ffmpeg build. Get a full build from gyan.dev" -ForegroundColor Red
        exit 1
    }
    Write-Step "ffmpeg + SVT-AV1 OK" Cyan
}

function Get-TempFile {
    param([string]$Ext)
    return [System.IO.Path]::Combine(
        [System.IO.Path]::GetTempPath(),
        [System.IO.Path]::GetRandomFileName() + $Ext
    )
}

$svt_presets = @{ "fast" = 10; "medium" = 8; "slow" = 6; "veryslow" = 4 }

Write-Host "=" * 70 -ForegroundColor Cyan
Write-Host "  AV1 Transcoder" -ForegroundColor Cyan
Write-Host "  TS/MP4 → SVT-AV1 compressed MP4" -ForegroundColor Cyan
Write-Host "  CRF guide: 30=archival, 45=good (default), 50=small" -ForegroundColor Cyan
Write-Host "=" * 70 -ForegroundColor Cyan

if (-not (Test-Path $InputFile)) {
    Write-Host "ERROR: Input not found: $InputFile" -ForegroundColor Red; exit 1
}

Test-FFmpeg

$isTS = $InputFile -match '\.(ts|m2ts|mts)$'
$tempClean = $null

if ($isTS) {
    Write-Step "TS input detected - remuxing to clean MP4 first (fixes PTS)" Yellow
    $tempClean = Get-TempFile "_clean.mp4"

    $v_start = ffprobe -v quiet -print_format csv -select_streams v -show_entries "packet=pts_time" $InputFile 2>$null |
        Select-Object -Skip 1 | Select-Object -First 1
    $offset = -([double]($v_start -split ',')[1])

    Write-Step "Remuxing with -copyts (PTS offset: $offset s)..." DarkYellow
    ffmpeg -copyts -i $InputFile -map 0:v -map 0:a -c copy -output_ts_offset $offset -y $tempClean 2>&1 |
        ForEach-Object { if ($_ -match "time=(\d+:\d+:\d+\.\d+)") {
            Write-Progress -Activity "Remuxing TS→MP4..." -Status $matches[1]
        }}
    Write-Progress -Activity "Remuxing TS→MP4..." -Completed

    $encodeInput = $tempClean
    $orig_size = (Get-Item $InputFile).Length
} else {
    $encodeInput = $InputFile
    $orig_size = (Get-Item $InputFile).Length
}

if (-not $OutputFile) {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
    $dir = if ($OutputDir) { $OutputDir } else { Split-Path $InputFile -Parent }
    $OutputFile = Join-Path $dir "${base}_av1.mp4"
}

if ((Test-Path $OutputFile) -and -not $Force) {
    Write-Host "ERROR: Output exists: $OutputFile (use -Force)" -ForegroundColor Red
    if ($tempClean -and -not $NoCleanup) { Remove-Item $tempClean -Force -ErrorAction SilentlyContinue }
    exit 1
}

# Probe input
$info = ffprobe -v quiet -print_format json -show_format -show_streams $encodeInput 2>$null | ConvertFrom-Json
$v = $info.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
$a = $info.streams | Where-Object { $_.codec_type -eq "audio" } | Select-Object -First 1

$dur_m = [math]::Round([double]$info.format.duration / 60, 1)
$res = if ($v) { "$($v.width)x$($v.height)" } else { "?" }

# Detect corrupt r_frame_rate and use actual average
$actualFps = $null
if ($v.nb_frames -and $v.duration -and [double]$v.duration -gt 0) {
    $actualFps = [math]::Round([double]$v.nb_frames / [double]$v.duration, 4)
}
$metaFps = if ($v.r_frame_rate -match '(\d+)/(\d+)') { [double]$matches[1] / [double]$matches[2] } else { 0 }
if ($actualFps -and $metaFps -gt 0 -and [math]::Abs($actualFps - $metaFps) -gt 1) {
    Write-Host "  !! r_frame_rate ($([math]::Round($metaFps,1))fps) != actual ($([math]::Round($actualFps,1))fps) — using -r $([math]::Round($actualFps,3))" -ForegroundColor Yellow
}

Write-Step "Duration: ${dur_m}min, Resolution: $res" Yellow
Write-Step "SVT-AV1 preset $($svt_presets[$Preset]) CRF=$CRF" Yellow

$ffargs = @(
    "-i", "`"$encodeInput`""
    "-map", "0:v"
    "-map", "0:a"
    "-c:v", "libsvtav1"
    "-preset", [string]$svt_presets[$Preset]
    "-crf", [string]$CRF
    "-g", "240"
    "-svtav1-params", "tune=0"
    "-c:a", "aac", "-b:a", "128k"
    "-y", "`"$OutputFile`""
)

if ($actualFps) {
    $ffargs += "-r", [string]$actualFps
}

$cmd = "ffmpeg $($ffargs -join ' ')"
Write-Step "Command:" Yellow; Write-Host "  $cmd" -ForegroundColor DarkGray

if ($DryRun) {
    if ($tempClean -and -not $NoCleanup) { Remove-Item $tempClean -Force -ErrorAction SilentlyContinue }
    Write-Step "Dry-run. Not executing." Green; exit 0
}

Write-Step "Transcoding... (this will take a while)" Green


# 轉碼進度顯示

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "ffmpeg.exe"
$psi.Arguments = $ffargs -join ' '
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi
$proc.Start() | Out-Null

$sw = [System.Diagnostics.Stopwatch]::StartNew()


while (-not $proc.HasExited) {
    $line = $proc.StandardError.ReadLine()
    if ($line -match "time=(\d+:\d+:\d+\.\d+)") {
        $pt = $sw.Elapsed.TotalMinutes
        $pct = if ($dur_m -gt 0) { [math]::Min(100, [math]::Round($pt / $dur_m * 100, 1)) } else { "?" }
        Write-Progress -Activity "AV1 [$Preset CRF=$CRF]" -Status "$($matches[1]) / ${dur_m}min ($pct%)" -PercentComplete $pct
    }
}


Write-Progress -Activity "AV1" -Completed


$sw.Stop()



# Cleanup temp
if ($tempClean -and -not $NoCleanup) {
    Remove-Item $tempClean -Force -ErrorAction SilentlyContinue
    Write-Step "Temp file cleaned" DarkGray
}

if (Test-Path $OutputFile) {
    $out_size = (Get-Item $OutputFile).Length
    $ratio = if ($orig_size -gt 0) { [math]::Round($out_size / $orig_size * 100, 1) } else { 0 }
    Write-Step "Done in $([math]::Round($sw.TotalMinutes, 1)) min" Green
    Write-Step "$([math]::Round($orig_size/1MB, 0)) MB → $([math]::Round($out_size/1MB, 0)) MB ($ratio%)" Green
    Write-Step "Output: $OutputFile" Green
} else {
    Write-Host "ERROR: Transcode failed" -ForegroundColor Red; exit 1
}
