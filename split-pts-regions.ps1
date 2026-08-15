param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$InputFile,

    [Parameter(Position=1)]
    [string]$OutputDir,

    [double]$WindowSec = 30,        # Analysis window size in seconds
    [double]$Threshold = 0.15,      # Relative fps deviation to trigger a regime break
    [int]$MinHold = 3,              # Consecutive deviating windows to commit a break
    [double]$MinSegmentSec = 60,    # Drop segments shorter than this (merge to neighbor)
    [int]$MaxFrames = 200000,       # Cap PTS samples for analysis (0 = all)

    [switch]$NoEncode,              # Stream-copy instead of transcoding (lossless, huge files)
    [string]$Encoder = "auto",      # nvenc | amf | libx264 | auto (auto-detect first available)
    [double]$Crf = 28,              # Quality 0-51 (lower = better); NVENC -cq / AMF qp / x264 crf
    [string]$Preset = "",           # Encoder preset (e.g. p5 for nvenc, medium for x264)
    [double]$CfrFps = 0,            # If >0, force CFR at this fps instead of preserving VFR PTS

    [switch]$Concat,                # Also concat parts into {base}_fixed.mp4
    [switch]$ReportOnly,            # Only print the regime analysis, no cutting
    [switch]$Force,
    [switch]$KeepTemp
)

function Write-Step {
    param([string]$Msg, [string]$Color = "Cyan")
    Write-Host ">>> $Msg" -ForegroundColor $Color
}

function Write-Info {
    param([string]$Msg)
    Write-Host "  $Msg" -ForegroundColor DarkCyan
}

function Write-Ok {
    param([string]$Msg)
    Write-Host "  $Msg" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Msg)
    Write-Host "  $Msg" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Msg)
    Write-Host "  $Msg" -ForegroundColor Red
}

function Test-FFmpeg {
    $ver = ffmpeg -version 2>&1 | Select-Object -First 1
    if (-not $ver) {
        Write-Err "ERROR: ffmpeg not found. Install from https://ffmpeg.org/"
        exit 1
    }
    Write-Step "ffmpeg: $ver" DarkCyan
}

# Temp work dir: keep it next to this script (not C:\temp) — big intermediate files
$script:WorkDir = Join-Path $PSScriptRoot "_tmp"
if (-not (Test-Path $script:WorkDir)) {
    New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null
}

function Get-VideoInfo {
    param([string]$File)
    $json = ffprobe -v quiet -print_format json -show_format -show_streams $File 2>$null | ConvertFrom-Json
    $v = $json.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
    $a = $json.streams | Where-Object { $_.codec_type -eq "audio" } | Select-Object -First 1
    $fmt = $json.format
    return @{ Video = $v; Audio = $a; Format = $fmt }
}

function Format-Time {
    param([double]$Seconds)
    $ts = [timespan]::FromSeconds([math]::Max(0, $Seconds))
    return "$($ts.Hours.ToString('00')):$($ts.Minutes.ToString('00')):$($ts.Seconds.ToString('00'))"
}

function Get-FirstPts {
    param([string]$File, [string]$StreamSpec)
    $pts = ffprobe -v quiet -select_streams $StreamSpec -show_entries packet=pts_time -of csv=p=0 $File 2>$null | Select-Object -First 1
    if ($pts) { return [double]$pts }
    return $null
}

function Get-LastPts {
    param([string]$File, [string]$StreamSpec)
    $pts = ffprobe -v quiet -select_streams $StreamSpec -show_entries packet=pts_time -of csv=p=0 $File 2>$null | Select-Object -Last 1
    if ($pts) { return [double]$pts }
    return $null
}

# ===== Analysis: split the PTS timeline into fps regimes =====
function Get-PtsArray {
    param([string]$File, [int]$MaxFrames)
    $pts = ffprobe -v quiet -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 $File 2>$null
    if (-not $pts -or $pts.Count -lt 100) { return $null }

    $total = $pts.Count
    $step = 1
    if ($MaxFrames -gt 0 -and $total -gt $MaxFrames) {
        $step = [math]::Floor($total / $MaxFrames)
    }
    $out = New-Object System.Collections.Generic.List[double]
    for ($i = 0; $i -lt $total; $i += $step) { $out.Add([double]$pts[$i]) }
    return @{ Pts = $out.ToArray(); Step = $step; TotalFrames = $total }
}

function Get-WindowFps {
    param([double[]]$Pts, [int]$Step, [double]$WindowSec)
    $n = $Pts.Count
    $windows = New-Object System.Collections.Generic.List[object]
    $i = 0
    $t = [math]::Floor($Pts[0] / $WindowSec) * $WindowSec
    $endT = $Pts[-1]
    while ($t -lt $endT) {
        $t2 = $t + $WindowSec
        $cnt = 0
        $first = $null
        $last = $null
        while ($i -lt $n -and $Pts[$i] -lt $t2) {
            $p = $Pts[$i]
            if ($null -eq $first) { $first = $p }
            $last = $p
            $cnt++
            $i++
        }
        if ($cnt -ge 2 -and $null -ne $first -and $null -ne $last -and ($last - $first) -gt 0) {
            # sampled count * step = actual frame count in this window
            $realFrames = $cnt * $Step
            $windows.Add(@{
                Start  = $t
                End    = $t2
                Frames = $realFrames
                Fps    = $realFrames / ($last - $first)
            })
        }
        $t = $t2
    }
    return $windows.ToArray()
}

# Print a full per-window FPS report table for the file
function Show-FpsReport {
    param([double[]]$Pts, [int]$Step, [double]$ReportWindowSec, $Regions)

    $reportWin = Get-WindowFps $Pts $Step $ReportWindowSec
    if (-not $reportWin -or $reportWin.Count -eq 0) { return }

    $rowCount = $reportWin.Count
    Write-Step "FPS analysis report (per $([math]::Round($ReportWindowSec,0))s window, total $rowCount rows)" Green

    # collapse to rows of at most ~60 so the report stays readable
    $groupBy = [math]::Max(1, [math]::Ceiling($rowCount / 60))
    Write-Host ""
    Write-Host ("  {0,-12} {1,-12} {2,-10} {3,-9} {4}" -f "Start", "End", "Frames", "FPS", "Regime") -ForegroundColor Cyan
    Write-Host ("  " + ("-" * 60))

    # build boundary markers (regime start times) for flagging
    $boundarySet = New-Object System.Collections.Generic.HashSet[double]
    if ($Regions) {
        for ($k = 1; $k -lt $Regions.Count; $k++) {
            [void]$boundarySet.Add([math]::Round($Regions[$k].StartPts / $ReportWindowSec) * $ReportWindowSec)
        }
    }

    for ($g = 0; $g -lt $rowCount; $g += $groupBy) {
        $agg = $reportWin[$g..([math]::Min($g + $groupBy - 1, $rowCount - 1))]
        $sumFrames = ($agg | ForEach-Object { $_.Frames } | Measure-Object -Sum).Sum
        $firstStart = $agg[0].Start
        $lastEnd = $agg[$agg.Count - 1].End
        $dur = $lastEnd - $firstStart
        $avgFps = if ($dur -gt 0) { $sumFrames / $dur } else { 0 }
        $mark = ""
        if ($g -gt 0) {
            $prevFps = ($reportWin[([math]::Max(0, $g - $groupBy))..($g - 1)] | ForEach-Object { $_.Fps } | Measure-Object -Average).Average
            if ($prevFps -gt 0 -and [math]::Abs($avgFps - $prevFps) / $prevFps -gt 0.3) { $mark = "  <<< transition" }
        }
        Write-Host ("  {0,-12} {1,-12} {2,-10} {3,-9} {4}" -f (Format-Time $firstStart), (Format-Time $lastEnd), $sumFrames, [math]::Round($avgFps, 1), $mark)
    }
    Write-Host ""
}

function Detect-Regions {
    param([double[]]$Pts, [int]$Step, [double]$WindowSec, [double]$Threshold, [int]$MinHold, [double]$MinSegmentSec)

    $windows = Get-WindowFps $Pts $Step $WindowSec
    if (-not $windows -or $windows.Count -eq 0) { return $null }

    # region = { StartPts, EndPts, WinA (first window idx), WinB (last window idx) }
    $regions = New-Object System.Collections.Generic.List[object]
    $curA = 0
    $curStart = $windows[0].Start
    $curFpsRef = $windows[0].Fps
    $i = 1
    $wc = $windows.Count

    while ($i -lt $wc) {
        $dev = [math]::Abs($windows[$i].Fps - $curFpsRef) / $curFpsRef
        if ($dev -gt $Threshold) {
            # find run of consecutive deviating windows
            $run = New-Object System.Collections.Generic.List[object]
            $j = $i
            while ($j -lt $wc) {
                $dj = [math]::Abs($windows[$j].Fps - $curFpsRef) / $curFpsRef
                if ($dj -gt $Threshold) { $run.Add($j); $j++ } else { break }
            }
            if ($run.Count -ge $MinHold) {
                # commit current region ending just before this run
                $prevEnd = if ($i -gt 0) { $windows[$i - 1].End } else { $windows[0].End }
                $regions.Add(@{
                    StartPts = $curStart
                    EndPts   = $prevEnd
                    WinA     = $curA
                    WinB     = $i - 1
                })
                # start new region; reference fps = median of the run
                $runFps = $run | ForEach-Object { $windows[$_].Fps } | Sort-Object
                $curFpsRef = $runFps[[math]::Floor($runFps.Count / 2)]
                $curStart = $windows[$run[0]].Start
                $curA = $run[0]
                $i = $j
                continue
            } else {
                $i = $j   # noise run, absorb
                continue
            }
        }
        $i++
    }
    $regions.Add(@{
        StartPts = $curStart
        EndPts   = $windows[-1].End
        WinA     = $curA
        WinB     = $wc - 1
    })

    $arr = $regions.ToArray()

    # merge very short regions into neighbor (backward, then forward for the first region)
    $merged = New-Object System.Collections.Generic.List[object]
    foreach ($r in $arr) {
        $dur = $r.EndPts - $r.StartPts
        if ($dur -lt $MinSegmentSec -and $merged.Count -gt 0) {
            $lastR = $merged[$merged.Count - 1]
            $lastR.EndPts = $r.EndPts
            $lastR.WinB = $r.WinB
        } else {
            $merged.Add(@{ StartPts = $r.StartPts; EndPts = $r.EndPts; WinA = $r.WinA; WinB = $r.WinB })
        }
    }
    $arr = $merged.ToArray()

    # if the FIRST region is still too short, merge it forward into region 2
    if ($arr.Count -ge 2 -and ($arr[0].EndPts - $arr[0].StartPts) -lt $MinSegmentSec) {
        $arr[1].StartPts = $arr[0].StartPts
        $arr[1].WinA = $arr[0].WinA
        $arr = $arr[1..($arr.Count - 1)]
    }

    # recompute each region's fps from the actual windows that fall in its span
    foreach ($r in $arr) {
        $totalFrames = 0
        for ($w = $r.WinA; $w -le $r.WinB; $w++) {
            $win = $windows[$w]
            # only count window time that overlaps [StartPts, EndPts]
            $ovStart = [math]::Max($win.Start, $r.StartPts)
            $ovEnd = [math]::Min($win.End, $r.EndPts)
            if ($ovEnd -gt $ovStart) {
                $totalFrames += $win.Frames * (($ovEnd - $ovStart) / ($win.End - $win.Start))
            }
        }
        $rDur = $r.EndPts - $r.StartPts
        $r.Fps = if ($rDur -gt 0) { $totalFrames / $rDur } else { 0 }
        $r.Frames = [math]::Round($totalFrames)
    }
    return $arr
}

# ===== Cutting =====
function Cut-Segment {
    param([string]$File, [double]$Start, [double]$End, [string]$OutPath)

    $seekBack = [math]::Max(30, $Start * 0.01)
    $inputSeek = [math]::Max(0, $Start - $seekBack)
    $hasEnd = ($End -gt 0)

    $args = @("-ss", $inputSeek.ToString(), "-copyts", "-i", $File,
              "-map", "0:v", "-map", "0:a",
              "-ss", $Start.ToString())
    if ($hasEnd) { $args += @("-to", $End.ToString()) }

    if ($script:EncodeEnabled) {
        $args += $script:VEncArgs
        $args += @("-c:a", "copy")
        if ($CfrFps -gt 0) {
            $args += @("-r", $CfrFps.ToString(), "-fps_mode", "cfr")
        } else {
            $args += @("-fps_mode", "passthrough", "-vsync", "passthrough")
        }
        $args += @("-movflags", "+faststart")
    } else {
        $args += @("-c", "copy")
    }
    $args += @("-avoid_negative_ts", "make_zero", "-y", $OutPath)

    $out = & ffmpeg -hide_banner -loglevel info @args 2>&1
    if (-not (Test-Path $OutPath)) {
        Write-Err "    ffmpeg cut failed:"
        $out | Select-Object -Last 6 | ForEach-Object { Write-Err "    $_" }
        return $null
    }
    return Get-VideoInfo $OutPath
}

function Concat-FixedParts {
    param([string[]]$Parts, [string]$OutputFile)

    $tmpDir = $script:WorkDir
    $concatFile = Join-Path $tmpDir "ptsreg_concat_$([System.IO.Path]::GetRandomFileName()).txt"
    $lines = $Parts | ForEach-Object { "file '$($_ -replace "'","'\\''")'" }
    $lines -join "`n" | Set-Content -Path $concatFile -Encoding ASCII

    & ffmpeg -f concat -safe 0 -i $concatFile -c copy -map 0 -movflags +faststart -y $OutputFile 2>&1 | Out-Null
    Remove-Item $concatFile -Force -ErrorAction SilentlyContinue
    return (Test-Path $OutputFile)
}


# ====== MAIN ======
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "  PTS Region Split Tool v1.0" -ForegroundColor Cyan
Write-Host "  Detects distinct FPS regimes in the PTS timeline and splits into N parts" -ForegroundColor Cyan
Write-Host ("=" * 70) -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $InputFile)) {
    Write-Err "ERROR: Input file not found: $InputFile"
    exit 1
}

Test-FFmpeg

# ---- Resolve encoder ----
$script:EncodeEnabled = -not $NoEncode
$script:VEncArgs = @()
if ($script:EncodeEnabled) {
    $encoders = (ffmpeg -hide_banner -encoders 2>&1 | Out-String)
    $script:EncName = "none"
    $cand = if ($Encoder -eq "auto") { @("h264_nvenc", "h264_amf", "h264_qsv", "libx264") } else { @($Encoder) }
    foreach ($c in $cand) {
        if ($encoders -match "\b$c\b") { $script:EncName = $c; break }
    }
    if ($script:EncName -eq "none") {
        Write-Warn "WARNING: encoder '$Encoder' not found; falling back to stream-copy."
        $script:EncodeEnabled = $false
    } else {
        switch ($script:EncName) {
            "h264_nvenc" {
                $script:VEncArgs = @("-c:v", "h264_nvenc", "-b:v", "0", "-cq", $Crf.ToString())
                if ($Preset) { $script:VEncArgs += @("-preset", $Preset) }
            }
            "h264_amf" {
                $script:VEncArgs = @("-c:v", "h264_amf", "-rc", "cqp", "-qp_i", $Crf.ToString(), "-qp_p", $Crf.ToString())
                if ($Preset) { $script:VEncArgs += @("-quality", $Preset) }
            }
            "h264_qsv" {
                $script:VEncArgs = @("-c:v", "h264_qsv", "-global_quality", $Crf.ToString())
                if ($Preset) { $script:VEncArgs += @("-preset", $Preset) }
            }
            default { # libx264
                $script:VEncArgs = @("-c:v", "libx264", "-crf", $Crf.ToString())
                if ($Preset) { $script:VEncArgs += @("-preset", $Preset) }
                $script:VEncArgs += @("-pix_fmt", "yuv420p")
            }
        }
        Write-Step "Encoder: $($script:EncName) (crf/cq=$Crf, VFR preserved by default)" Green
        if ($CfrFps -gt 0) {
            Write-Warn "  NOTE: -CfrFps $CfrFps forces a uniform frame rate (destroys VFR). Only use if the part is truly CFR."
        }

        $srcSizeBits = (Get-Item -LiteralPath $InputFile).Length * 8
        $srcDur = [double]((ffprobe -v quiet -show_entries format=duration -of csv=p=0 $InputFile) 2>$null)
        if ($srcDur -gt 0) {
            $srcBitrate = $srcSizeBits / $srcDur / 1000   # kbps
            Write-Warn "  Source bitrate ~$([math]::Round($srcBitrate / 1000, 2)) Mbps — a re-encode at cq=$Crf can come out LARGER than the source if it is already heavily compressed."
            Write-Warn "  Tip: raise -Crf (e.g. 30-35) for a smaller file, or use -NoEncode for a lossless split."
        }
    }
}

Write-Step "Analyzing: $InputFile" Yellow
$inInfo = Get-VideoInfo $InputFile
$inV = $inInfo.Video
$inA = $inInfo.Audio

if (-not $inV) {
    Write-Err "ERROR: No video stream found"
    exit 1
}

$inVDur = [double]$inV.duration
$inADur = if ($inA) { [double]$inA.duration } else { 0 }

Write-Info "Video: $($inV.codec_name) $($inV.width)x$($inV.height), PTS=$([math]::Round($inVDur,1))s, frames=$($inV.nb_frames)"
if ($inA) {
    Write-Info "Audio: $($inA.codec_name), duration=$([math]::Round($inADur,1))s"
    $diff = [math]::Abs($inVDur - $inADur)
    if ($diff -gt 2) { Write-Warn "  A/V duration diff: $([math]::Round($diff, 1))s (PTS compression suspected)" }
}

# ---- Detect regions ----
Write-Step "Scanning PTS timeline (window=${WindowSec}s, threshold=$Threshold, minhold=$MinHold)..." Yellow
$ptsData = Get-PtsArray $InputFile $MaxFrames
if (-not $ptsData) {
    Write-Err "ERROR: Cannot read PTS from input"
    exit 1
}
$pts = $ptsData.Pts
$step = $ptsData.Step
if ($step -gt 1) {
    Write-Info "  Sampled every ${step}th frame ($($ptsData.TotalFrames) total -> $($pts.Count) analyzed)"
}
$regions = Detect-Regions $pts $step $WindowSec $Threshold $MinHold $MinSegmentSec
if (-not $regions -or $regions.Count -eq 0) {
    Write-Err "ERROR: No regions detected"
    exit 1
}

# ---- Full-file FPS report ----
Show-FpsReport $pts $step 60 $regions

# ---- Print regime table ----
Write-Host ""
Write-Host "  FPS regime summary (analysis window ${WindowSec}s):" -ForegroundColor Cyan
Write-Host ("  {0,-5} {1,-10} {2,-12} {3,-12} {4,-12} {5,-8}" -f "Part", "FPS", "Start", "End", "Duration", "Frames")
Write-Host ("  " + ("-" * 59))
$boundaries = New-Object System.Collections.Generic.List[double]
$totalReportFrames = 0
for ($k = 0; $k -lt $regions.Count; $k++) {
    $r = $regions[$k]
    $dur = $r.EndPts - $r.StartPts
    $rFrames = $r.Frames
    $totalReportFrames += $rFrames
    Write-Host ("  {0,-5} {1,-10} {2,-12} {3,-12} {4,-12} {5,-8}" -f ("#" + ($k + 1)), [math]::Round($r.Fps, 1), (Format-Time $r.StartPts), (Format-Time $r.EndPts), (Format-Time $dur), $rFrames)
    if ($k -gt 0) { $boundaries.Add($r.StartPts) }
}
Write-Host ("  " + ("-" * 59))
Write-Info "  Total estimated frames: $totalReportFrames (reported: $($inV.nb_frames))"

if ($regions.Count -eq 1) {
    Write-Ok "  Single fps regime ($([math]::Round($regions[0].Fps, 1)) fps) — no split needed."
    if (-not $ReportOnly) { Write-Info "  If the file still plays wrong, the issue is likely metadata (r_frame_rate) — try fix-fps.ps1 -Strategy mkv." }
    exit 0
}

Write-Host ""
if ($boundaries.Count -eq 1) {
    Write-Info "Detected 1 fps transition at $($(Format-Time $boundaries[0])) ($([math]::Round($boundaries[0], 1))s) -> will split into 2 parts"
} else {
    Write-Info "Detected $($boundaries.Count) fps transitions -> will split into $($regions.Count) parts"
}

if ($ReportOnly) { exit 0 }

# ---- Validate output paths ----
$inDir = Split-Path $InputFile -Parent
$base = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
$outDir = if ($OutputDir) { $OutputDir } else { $inDir }
if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

$partPaths = New-Object System.Collections.Generic.List[string]
$partCount = $regions.Count
for ($k = 0; $k -lt $partCount; $k++) {
    $p = Join-Path $outDir ("{0}_part{1}.mp4" -f $base, ($k + 1))
    if ((Test-Path $p) -and -not $Force) {
        Write-Err "ERROR: Output exists: $p (use -Force to overwrite)"
        exit 1
    }
    $partPaths.Add($p)
}

if ($Concat) {
    $concatOut = if ($OutputDir) { Join-Path $OutputDir ("{0}_fixed.mp4" -f $base) } else { Join-Path $inDir ("{0}_fixed.mp4" -f $base) }
    if ((Test-Path $concatOut) -and -not $Force) {
        Write-Err "ERROR: Output exists: $concatOut (use -Force to overwrite)"
        exit 1
    }
}

# ---- Cut each segment ----
$tmpDir = $script:WorkDir
$cutInfos = @()
try {
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Step "SPLITTING: $partCount segments" Yellow
    Write-Host ("=" * 70) -ForegroundColor Cyan

    for ($k = 0; $k -lt $partCount; $k++) {
        Write-Host ""
        Write-Host ("-" * 70)
        Write-Step ("PHASE " + ($k + 1) + "/" + $partCount + ": Cutting Part " + ($k + 1)) Green
        $r = $regions[$k]
        $start = $r.StartPts
        $end = if ($k -lt $partCount - 1) { $r.EndPts } else { -1 }
        $dur = $r.EndPts - $r.StartPts
        Write-Info "  Range   : $(Format-Time $start) ~ $(if ($end -gt 0) { Format-Time $end } else { 'end' })  (duration $(Format-Time $dur))"
        Write-Info "  Regime  : ~$([math]::Round($r.Fps, 1)) fps"
        Write-Info "  Output  : $($partPaths[$k])"

        $segInfo = Cut-Segment $InputFile $start $end $partPaths[$k]
        if (-not $segInfo) {
            Write-Err "  ERROR: Part $($k + 1) cut failed"
            throw "Part $($k + 1) cut failed"
        }
        $cutInfos += $segInfo
        $sv = $segInfo.Video
        $sa = $segInfo.Audio
        $mb = [math]::Round((Get-Item $partPaths[$k]).Length / 1MB, 1)
        if ($sv -and $sa) {
            $vD = [double]$sv.duration; $aD = [double]$sa.duration
            $d = [math]::Abs($vD - $aD)
            Write-Info "  Result  : video=$([math]::Round($vD,1))s audio=$([math]::Round($aD,1))s frames=$($sv.nb_frames) size=${mb}MB"
            if ($d -lt 2) { Write-Ok "  A/V sync OK (diff=$([math]::Round($d, 2))s)" }
            else { Write-Warn "  A/V diff $([math]::Round($d, 2))s" }
        } else {
            Write-Info "  Result  : size=${mb}MB"
        }
        Write-Ok "  Written : $($partPaths[$k])"
    }

    # ---- Optional concat ----
    if ($Concat) {
        Write-Host ""
        Write-Host ("-" * 60)
        Write-Step "PHASE CONCAT: Aligning + concatenating all parts" Yellow

        $fixedParts = New-Object System.Collections.Generic.List[string]
        $accumOffset = 0.0
        for ($k = 0; $k -lt $partCount; $k++) {
            if ($k -eq 0) {
                $fixedParts.Add($partPaths[$k])
                $vLast = Get-LastPts $partPaths[$k] "v:0"
                $vFirst = Get-FirstPts $partPaths[$k] "v:0"
                if ($vLast -and $vFirst) { $accumOffset = $vLast - $vFirst }
            } else {
                $tmpShifted = Join-Path $script:WorkDir "ptsreg_shift_$([System.IO.Path]::GetRandomFileName()).mp4"
                & ffmpeg -i $partPaths[$k] -c copy -map 0 -output_ts_offset $accumOffset.ToString("0.000000") -video_track_timescale 90000 -y $tmpShifted 2>&1 | Out-Null
                if (-not (Test-Path $tmpShifted)) { throw "Shift part $($k + 1) failed" }
                $vLast = Get-LastPts $tmpShifted "v:0"
                $vFirst = Get-FirstPts $tmpShifted "v:0"
                if ($vLast -and $vFirst) { $accumOffset += ($vLast - $vFirst) }
                $fixedParts.Add($tmpShifted)
            }
        }

        $concatPath = if ($OutputDir) { Join-Path $OutputDir ("{0}_fixed.mp4" -f $base) } else { Join-Path $inDir ("{0}_fixed.mp4" -f $base) }
        Write-Info "  Concatenating $($fixedParts.Count) parts -> $concatPath"
        $ok = Concat-FixedParts $fixedParts.ToArray() $concatPath
        if ($ok) {
            $outInfo = Get-VideoInfo $concatPath
            $ov = $outInfo.Video; $oa = $outInfo.Audio
            if ($ov -and $oa) {
                $vD = [double]$ov.duration; $aD = [double]$oa.duration
                $d = [math]::Abs($vD - $aD)
                if ($d -lt 2) { Write-Ok "  A/V sync OK (diff=$([math]::Round($d, 2))s)" }
                else { Write-Warn "  A/V diff $([math]::Round($d, 2))s" }
            }
            Write-Ok "  Concat output: $concatPath"
        } else {
            Write-Warn "  Concat failed — parts are still available separately"
        }

        foreach ($p in $fixedParts) {
            if ($p -ne $partPaths[0]) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
        }
    }

    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Step "DONE — parts saved:" Green
    Write-Host ("  {0,-8} {1,-9} {2,-12} {3,-12} {4}" -f "Part", "FPS", "Range", "Duration", "File") -ForegroundColor Cyan
    Write-Host ("  " + ("-" * 66))
    for ($k = 0; $k -lt $partCount; $k++) {
        $r = $regions[$k]
        $dur = $r.EndPts - $r.StartPts
        $mb = if (Test-Path $partPaths[$k]) { [math]::Round((Get-Item $partPaths[$k]).Length / 1MB, 1) } else { 0 }
        $rEndStr = if ($r.EndPts -gt $r.StartPts) { Format-Time $r.EndPts } else { "end" }
        $row = ("  {0,-8} {1,-9} {2,-12} {3,-12} {4}  [{5}MB]" -f ("Part " + ($k + 1)), [math]::Round($r.Fps, 1), ((Format-Time $r.StartPts) + " ~ " + $rEndStr), (Format-Time $dur), $partPaths[$k], $mb)
        Write-Host $row
    }
    Write-Host ("  " + ("-" * 66))
    Write-Info "  Each part keeps its original PTS — inspect per-part A/V sync before further fixing."
    Write-Host ("=" * 70) -ForegroundColor Cyan

    # clean up leftover intermediate files in the work dir
    if (-not $KeepTemp) {
        Get-ChildItem -Path $script:WorkDir -Filter "ptsreg_*" -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}
catch {
    Write-Err "ERROR: $_"
    exit 1
}