param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$InputFile,

    [Parameter(Position=1)]
    [string]$OutputFile,

    [switch]$Force,
    [switch]$KeepTemp,                          # Keep temp files for debugging
    [double]$Duration = 0,                      # Target video duration in seconds (0=keep original)
    [ValidateSet("auto","cfr","genpts","mkv")]
    [string]$Strategy = "auto"                  # auto=detect, cfr=constant-fps remux, genpts, mkv
)

function Write-Step {
    param([string]$Msg, [string]$Color = "Cyan")
    Write-Host ">>> $Msg" -ForegroundColor $Color
}

function Test-FFmpeg {
    $ver = ffmpeg -version 2>&1 | Select-Object -First 1
    if (-not $ver) {
        Write-Host "ERROR: ffmpeg not found" -ForegroundColor Red
        exit 1
    }
    Write-Step "ffmpeg: $ver" DarkCyan
}

function Get-VideoInfo {
    param([string]$File)
    $json = ffprobe -v quiet -print_format json -show_streams -show_format $File 2>$null | ConvertFrom-Json
    $v = $json.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
    $a = $json.streams | Where-Object { $_.codec_type -eq "audio" } | Select-Object -First 1
    $fmt = $json.format
    return @{ Video = $v; Audio = $a; Format = $fmt }
}

function Calc-RealFps {
    param($stream)
    $frames = try { [double]$stream.nb_frames } catch { 0 }
    $dur = try { [double]$stream.duration } catch { 0 }
    if ($frames -gt 0 -and $dur -gt 0) {
        return [math]::Round($frames / $dur, 6)
    }
    return 0
}

function Parse-FracFps {
    param([string]$FracStr)
    if ($FracStr -match '^(\d+)/(\d+)$') {
        $num = [double]$matches[1]; $den = [double]$matches[2]
        if ($den -gt 0) { return [math]::Round($num / $den, 4) }
    }
    return [double]$FracStr
}

function Test-PtsCorrupted {
    param([string]$File, [int]$SampleCount = 1000)
    # Sample PTS deltas at evenly spaced positions, check for ultra-short gaps
    $pts = ffprobe -v quiet -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 $File 2>$null
    if (-not $pts -or $pts.Count -lt 100) { return $false }
    $total = $pts.Count
    $step = [math]::Max(1, [math]::Floor($total / $SampleCount))
    $abnormal = 0
    $normal = 0
    for ($i = $step; $i -lt $total; $i += $step) {
        $delta = [double]$pts[$i] - [double]$pts[$i-1]
        if ($delta -gt 0 -and $delta -lt 0.001) { $abnormal++ }  # <1ms between frames = corrupted
        elseif ($delta -gt 0.01) { $normal++ }
    }
    if ($abnormal -gt 5 -and $abnormal -gt $normal * 0.3) { return $true }
    return $false
}

# ====== MAIN ======
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "  FPS Metadata Fix Tool v3.0" -ForegroundColor Cyan
Write-Host "  Detects and fixes: r_frame_rate corruption + PTS compression" -ForegroundColor Cyan
Write-Host ("=" * 70) -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $InputFile)) {
    Write-Host "ERROR: Input file not found: $InputFile" -ForegroundColor Red
    exit 1
}

Test-FFmpeg

# Step 1: Analyze
Write-Step "Analyzing: $InputFile" Yellow
$info = Get-VideoInfo $InputFile
$v = $info.Video
$a = $info.Audio
$fmt = $info.Format

if (-not $v) { Write-Host "ERROR: No video stream found" -ForegroundColor Red; exit 1 }

$r_fps = Parse-FracFps $v.r_frame_rate
$real_fps = Calc-RealFps $v
$vid_dur = [double]$v.duration
$aud_dur = if ($a) { [double]$a.duration } else { 0 }
$fmt_dur = if ($fmt) { [double]$fmt.duration } else { 0 }

Write-Step "Codec: $($v.codec_name)  $($v.width)x$($v.height)" Cyan
Write-Step "Video: duration=$([math]::Round($vid_dur,1))s, frames=$($v.nb_frames)" Cyan
Write-Step "r_frame_rate: $($v.r_frame_rate)  (~$([math]::Round($r_fps,2)) fps)" Cyan
Write-Step "Real FPS (frames/dur): $real_fps" Cyan
if ($a) { Write-Step "Audio: $($a.codec_name), duration=$([math]::Round($aud_dur,1))s" DarkCyan }

# Step 2: Diagnose
$badFpsHeader = ($r_fps -gt 120 -or $r_fps -lt 1)
$ptsCompressed = $false
$ptsCorrupted = $false
$ptsRatio = 1.0

# Only stretch PTS if user explicitly provides -Duration
if ($Duration -gt 0 -and $vid_dur -gt 0) {
    $ptsRatio = $Duration / $vid_dur
    if ($ptsRatio -gt 1.02) {
        $ptsCompressed = $true
    }
}

# Check for PTS corruption (ultra-short deltas mixed with normal)
if (-not $ptsCompressed -and $Strategy -eq "auto") {
    Write-Step "Checking PTS integrity..." DarkCyan
    $ptsCorrupted = Test-PtsCorrupted $InputFile
}

Write-Host ""
if ($badFpsHeader) {
    Write-Host "  [ISSUE] r_frame_rate=$([math]::Round($r_fps,0)) fps (invalid stts metadata)" -ForegroundColor Red
}
if ($ptsCorrupted) {
    Write-Host "  [ISSUE] PTS corrupted: ultra-short frame gaps detected (mixed normal/abnormal deltas)" -ForegroundColor Red
}
if ($ptsCompressed) {
    Write-Host "  [ISSUE] PTS compressed: video=$([math]::Round($vid_dur,1))s vs target=$([math]::Round($Duration,1))s (ratio=$([math]::Round($ptsRatio,4)))" -ForegroundColor Red
}

if (-not $badFpsHeader -and -not $ptsCompressed -and -not $ptsCorrupted) {
    Write-Host "  No issues detected." -ForegroundColor Green
    if ($aud_dur -gt $vid_dur + 2) {
        Write-Host "  Note: audio ($([math]::Round($aud_dur,1))s) is longer than video ($([math]::Round($vid_dur,1))s)" -ForegroundColor Yellow
    }
    if (-not $Force) { exit 0 }
}

if ($ptsCompressed) {
    $stretchedFps = [math]::Round($real_fps / $ptsRatio, 6)
    Write-Host "  -> Will stretch PTS by $([math]::Round($ptsRatio,4))x" -ForegroundColor Yellow
    Write-Host "  -> Target FPS: $stretchedFps (was $real_fps)" -ForegroundColor Yellow
} elseif ($ptsCorrupted) {
    Write-Host "  -> Will rebuild as CFR at $real_fps fps (discard corrupted PTS)" -ForegroundColor Yellow
} elseif ($badFpsHeader) {
    Write-Host "  -> Will fix stts metadata (PTS values are correct)" -ForegroundColor Yellow
}

# Step 3: Set output path
if (-not $OutputFile) {
    $dir = Split-Path $InputFile -Parent
    $base = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
    $OutputFile = Join-Path $dir "${base}_fpsfixed.mp4"
}

if ((Test-Path -LiteralPath $OutputFile) -and -not $Force) {
    Write-Host "ERROR: Output exists: $OutputFile (use -Force to overwrite)" -ForegroundColor Red
    exit 1
}

# Step 4: Execute fix
if ($Strategy -eq "genpts") {
    Write-Step "Strategy: genpts (regenerate PTS)" Green
    ffmpeg -i $InputFile -c copy -map 0 -fflags +genpts -movflags +faststart -y $OutputFile 2>&1 | ForEach-Object {
        if ($_ -match "time=(\d+:\d+:\d+\.\d+)") { Write-Progress -Activity "genpts remux" -Status $matches[1] }
    }
}
elseif ($Strategy -eq "mkv") {
    Write-Step "Strategy: mkv (MKV intermediate strip)" Green
    $tmpMkv = Join-Path ([System.IO.Path]::GetTempPath()) "fixfps_$([System.IO.Path]::GetRandomFileName()).mkv"
    Write-Step "  Step 1: MP4 -> MKV" DarkYellow
    ffmpeg -i $InputFile -c copy -map 0 -y $tmpMkv 2>&1 | ForEach-Object {
        if ($_ -match "time=(\d+:\d+:\d+\.\d+)") { Write-Progress -Activity "Step 1/2: MP4->MKV" -Status $matches[1] }
    }
    Write-Progress -Activity "Step 1/2" -Completed
    Write-Step "  Step 2: MKV -> MP4" DarkYellow
    ffmpeg -i $tmpMkv -c copy -map 0 -movflags +faststart -y $OutputFile 2>&1 | ForEach-Object {
        if ($_ -match "time=(\d+:\d+:\d+\.\d+)") { Write-Progress -Activity "Step 2/2: MKV->MP4" -Status $matches[1] }
    }
    Write-Progress -Activity "Step 2/2" -Completed
    if (-not $KeepTemp) { Remove-Item $tmpMkv -Force -ErrorAction SilentlyContinue }
}
elseif ($Strategy -eq "cfr" -or $ptsCorrupted) {
    # CFR strategy: extract raw H.264 + AAC, remux at constant FPS
    # Discards all PTS/DTS (good for corrupted/intermittently wrong timestamps)
    Write-Step "Strategy: CFR (constant frame rate rebuild, discards corrupted PTS)" Green
    $tmpDir = [System.IO.Path]::GetTempPath()
    $tmpVideo = Join-Path $tmpDir "fixfps_$([System.IO.Path]::GetRandomFileName()).h264"
    $tmpAudio = Join-Path $tmpDir "fixfps_$([System.IO.Path]::GetRandomFileName()).aac"

    Write-Step "  Step 1/2: Extracting raw H.264 stream..." DarkYellow
    ffmpeg -i $InputFile -c:v copy -bsf:v h264_mp4toannexb -f h264 -y $tmpVideo 2>&1 | ForEach-Object {
        if ($_ -match "time=(\d+:\d+:\d+\.\d+)") { Write-Progress -Activity "Extracting raw H.264" -Status $matches[1] }
    }
    Write-Progress -Activity "Extracting raw H.264" -Completed

    Write-Step "  Step 2/2: Remuxing at $real_fps fps CFR -> MP4..." DarkYellow
    ffmpeg -r $real_fps -i $tmpVideo -i $InputFile -c copy -map 0:v -map 1:a -t $vid_dur -movflags +faststart -y $OutputFile 2>&1 | ForEach-Object {
        if ($_ -match "time=(\d+:\d+:\d+\.\d+)") { Write-Progress -Activity "CFR remux to MP4" -Status $matches[1] }
    }
    Write-Progress -Activity "CFR remux to MP4" -Completed

    if (-not $KeepTemp) { Remove-Item $tmpVideo -Force -ErrorAction SilentlyContinue }
}
else {
    # auto / raw strategy: extract raw streams + remux
    # If PTS is compressed, also apply setts stretch before extraction
    $tmpDir = [System.IO.Path]::GetTempPath()
    $srcForExtract = $InputFile

    # Phase 1: PTS stretch (if needed)
    if ($ptsCompressed) {
        Write-Step "Phase 1: Stretching PTS by $([math]::Round($ptsRatio,4))x (setts bsf, stream copy)..." Green
        $tmpStretched = Join-Path $tmpDir "fixfps_$([System.IO.Path]::GetRandomFileName()).mp4"
        Write-Step "  Applying setts=pts=PTS*$ptsRatio to video stream..." DarkYellow
        ffmpeg -i $InputFile -c copy -bsf:v "setts=pts=PTS*$ptsRatio" -map 0 -y $tmpStretched 2>&1 | ForEach-Object {
            if ($_ -match "time=(\d+:\d+:\d+\.\d+)") { Write-Progress -Activity "Stretching PTS" -Status $matches[1] }
        }
        Write-Progress -Activity "Stretching PTS" -Completed
        if (-not (Test-Path $tmpStretched)) {
            Write-Host "ERROR: PTS stretch failed" -ForegroundColor Red
            exit 1
        }
        $srcForExtract = $tmpStretched
    }

    # Phase 2: Remux to MKV (preserves correct PTS, strips bad stts, keeps VFR)
    Write-Step "Phase 2: Remuxing to MKV intermediate (preserves VFR timing)..." Green
    $tmpMkv = Join-Path $tmpDir "fixfps_$([System.IO.Path]::GetRandomFileName()).mkv"
    ffmpeg -i $srcForExtract -c copy -map 0 -y $tmpMkv 2>&1 | ForEach-Object {
        if ($_ -match "time=(\d+:\d+:\d+\.\d+)") { Write-Progress -Activity "Remuxing to MKV" -Status $matches[1] }
    }
    Write-Progress -Activity "Remuxing to MKV" -Completed

    if (-not (Test-Path $tmpMkv)) {
        Write-Host "ERROR: MKV remux failed" -ForegroundColor Red
        exit 1
    }

    # Phase 3: Remux MKV to MP4 (generates correct duration from MKV timestamps)
    Write-Step "Phase 3: Remuxing MKV -> MP4..." Green
    $trimDuration = if ($ptsCompressed) { $Duration } elseif ($aud_dur -gt $vid_dur + 1) { $vid_dur } else { 0 }
    $trimArgs = if ($trimDuration -gt 0) { @("-t", [string]$trimDuration) } else { @() }
    if ($trimDuration -gt 0) {
        Write-Step "  Trimming audio to $([math]::Round($trimDuration,1))s (video duration)" DarkYellow
    }
    ffmpeg -i $tmpMkv -c copy -map 0 @trimArgs -movflags +faststart -y $OutputFile 2>&1 | ForEach-Object {
        if ($_ -match "time=(\d+:\d+:\d+\.\d+)") { Write-Progress -Activity "MKV -> MP4" -Status $matches[1] }
    }
    Write-Progress -Activity "MKV -> MP4" -Completed

    # Cleanup
    if (-not $KeepTemp) {
        Remove-Item $tmpMkv -Force -ErrorAction SilentlyContinue
        if ($ptsCompressed -and $tmpStretched) { Remove-Item $tmpStretched -Force -ErrorAction SilentlyContinue }
    } else {
        Write-Step "Temp files kept in $tmpDir" DarkGray
    }
}
Write-Progress -Activity "Fixing FPS..." -Completed

# Step 5: Verify
if (Test-Path -LiteralPath $OutputFile) {
    Write-Step "Verifying output..." Yellow
    $out_info = Get-VideoInfo $OutputFile
    $out_v = $out_info.Video
    $out_a = $out_info.Audio

    if ($out_v) {
        $out_r = Parse-FracFps $out_v.r_frame_rate
        $out_dur = [double]$out_v.duration
        $out_aud_dur = if ($out_a) { [double]$out_a.duration } else { 0 }

        Write-Step "  Video r_frame_rate: $($out_v.r_frame_rate)  (~$([math]::Round($out_r,2)) fps)" Green
        Write-Step "  Video duration: $([math]::Round($out_dur,1))s  ($([math]::Floor($out_dur/3600)):$([math]::Floor(($out_dur%3600)/60).ToString('00')):$([math]::Floor($out_dur%60).ToString('00')))" Green
        if ($out_aud_dur -gt 0) {
            Write-Step "  Audio duration: $([math]::Round($out_aud_dur,1))s" Green
            $durDiff = [math]::Abs($out_dur - $out_aud_dur)
            if ($durDiff -lt 2) {
                Write-Step "  A/V sync: OK (diff=$([math]::Round($durDiff,2))s)" Green
            } else {
                Write-Host "  A/V sync: WARNING (diff=$([math]::Round($durDiff,2))s)" -ForegroundColor Yellow
            }
        }
        Write-Step "  Frames: $($out_v.nb_frames) (preserved)" DarkCyan

        $r_ok = ($out_r -gt 0 -and $out_r -lt 120)
        if ($r_ok) { Write-Step "PASS" Green } else { Write-Host "  WARNING: r_frame_rate still abnormal" -ForegroundColor Yellow }
    }

    $inSize = (Get-Item $InputFile).Length / 1GB
    $outSize = (Get-Item $OutputFile).Length / 1GB
    Write-Step "Input:  $([math]::Round($inSize, 3)) GB" DarkCyan
    Write-Step "Output: $([math]::Round($outSize, 3)) GB" Green
    Write-Step "DONE!" Green
} else {
    Write-Host "ERROR: Output file was not created" -ForegroundColor Red
    exit 1
}
