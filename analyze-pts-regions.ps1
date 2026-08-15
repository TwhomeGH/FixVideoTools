param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$InputFile,

    [double]$WindowSec = 30,        # Regime-detection window size in seconds
    [double]$ReportWindowSec = 60,  # Report table row granularity in seconds
    [double]$Threshold = 0.15,      # Relative fps deviation to trigger a regime break
    [int]$MinHold = 3,              # Consecutive deviating windows to commit a break
    [double]$MinSegmentSec = 60,    # Drop segments shorter than this (merge to neighbor)
    [int]$MaxFrames = 200000,       # Cap PTS samples for analysis (0 = all)
    [switch]$ShowAll                # Print every report row (default: ~60 rows)
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

function Format-Time {
    param([double]$Seconds)
    $ts = [timespan]::FromSeconds([math]::Max(0, $Seconds))
    return "$($ts.Hours.ToString('00')):$($ts.Minutes.ToString('00')):$($ts.Seconds.ToString('00'))"
}

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

function Detect-Regions {
    param([double[]]$Pts, [int]$Step, [double]$WindowSec, [double]$Threshold, [int]$MinHold, [double]$MinSegmentSec)

    $windows = Get-WindowFps $Pts $Step $WindowSec
    if (-not $windows -or $windows.Count -eq 0) { return $null }

    $regions = New-Object System.Collections.Generic.List[object]
    $curA = 0
    $curStart = $windows[0].Start
    $curFpsRef = $windows[0].Fps
    $i = 1
    $wc = $windows.Count

    while ($i -lt $wc) {
        $dev = [math]::Abs($windows[$i].Fps - $curFpsRef) / $curFpsRef
        if ($dev -gt $Threshold) {
            $run = New-Object System.Collections.Generic.List[object]
            $j = $i
            while ($j -lt $wc) {
                $dj = [math]::Abs($windows[$j].Fps - $curFpsRef) / $curFpsRef
                if ($dj -gt $Threshold) { $run.Add($j); $j++ } else { break }
            }
            if ($run.Count -ge $MinHold) {
                $prevEnd = if ($i -gt 0) { $windows[$i - 1].End } else { $windows[0].End }
                $regions.Add(@{
                    StartPts = $curStart
                    EndPts   = $prevEnd
                    WinA     = $curA
                    WinB     = $i - 1
                })
                $runFps = $run | ForEach-Object { $windows[$_].Fps } | Sort-Object
                $curFpsRef = $runFps[[math]::Floor($runFps.Count / 2)]
                $curStart = $windows[$run[0]].Start
                $curA = $run[0]
                $i = $j
                continue
            } else {
                $i = $j
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

    if ($arr.Count -ge 2 -and ($arr[0].EndPts - $arr[0].StartPts) -lt $MinSegmentSec) {
        $arr[1].StartPts = $arr[0].StartPts
        $arr[1].WinA = $arr[0].WinA
        $arr = $arr[1..($arr.Count - 1)]
    }

    foreach ($r in $arr) {
        $totalFrames = 0
        for ($w = $r.WinA; $w -le $r.WinB; $w++) {
            $win = $windows[$w]
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
    return @{ Regions = $arr; Windows = $windows }
}


# ====== MAIN ======
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "  PTS Regions Analyzer v1.0" -ForegroundColor Cyan
Write-Host "  Read-only FPS regime analysis report (no output files)" -ForegroundColor Cyan
Write-Host ("=" * 70) -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $InputFile)) {
    Write-Err "ERROR: Input file not found: $InputFile"
    exit 1
}

$ver = ffmpeg -version 2>&1 | Select-Object -First 1
if (-not $ver) { Write-Err "ERROR: ffmpeg not found"; exit 1 }
Write-Step "ffmpeg: $ver" DarkCyan

# --- File overview ---
Write-Step "Analyzing: $InputFile" Yellow
$json = ffprobe -v quiet -print_format json -show_format -show_streams $InputFile 2>$null | ConvertFrom-Json
$v = $json.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
$a = $json.streams | Where-Object { $_.codec_type -eq "audio" } | Select-Object -First 1

if (-not $v) { Write-Err "ERROR: No video stream found"; exit 1 }

$vDur = [double]$v.duration
$aDur = if ($a) { [double]$a.duration } else { 0 }
$rFpsRaw = try { [double]($v.r_frame_rate -split '/')[0] / [double]($v.r_frame_rate -split '/')[1] } catch { 0 }

Write-Info "Video: $($v.codec_name) $($v.width)x$($v.height), PTS=$([math]::Round($vDur,1))s, frames=$($v.nb_frames)"
Write-Info "  r_frame_rate (header): $($v.r_frame_rate) (~$([math]::Round($rFpsRaw, 2)) fps)"
if ($a) {
    Write-Info "Audio: $($a.codec_name), duration=$([math]::Round($aDur,1))s"
    $diff = [math]::Abs($vDur - $aDur)
    if ($diff -le 2) { Write-Ok "  A/V duration: match (diff=$([math]::Round($diff,2))s) — PTS timeline is intact" }
    else { Write-Warn "  A/V duration differs by $([math]::Round($diff, 1))s — PTS compression suspected" }
}

# --- Detect regions ---
Write-Step "Scanning PTS timeline (window=${WindowSec}s, threshold=$Threshold, minhold=$MinHold)..." Yellow
$ptsData = Get-PtsArray $InputFile $MaxFrames
if (-not $ptsData) { Write-Err "ERROR: Cannot read PTS from input"; exit 1 }
$pts = $ptsData.Pts
$step = $ptsData.Step
if ($step -gt 1) {
    Write-Info "  Sampled every ${step}th frame ($($ptsData.TotalFrames) total -> $($pts.Count) analyzed)"
}

$result = Detect-Regions $pts $step $WindowSec $Threshold $MinHold $MinSegmentSec
if (-not $result -or -not $result.Regions -or $result.Regions.Count -eq 0) {
    Write-Err "ERROR: No regions detected"
    exit 1
}
$regions = $result.Regions
$windows = $result.Windows

# --- Per-window report table ---
Write-Step "FPS report (per $([math]::Round($ReportWindowSec,0))s window, $($windows.Count) rows total)" Green
$rowCount = $windows.Count
$groupBy = 1
if (-not $ShowAll) {
    $groupBy = [math]::Max(1, [math]::Ceiling($rowCount / 60))
}
Write-Host ""
Write-Host ("  {0,-12} {1,-12} {2,-10} {3,-9} {4}" -f "Start", "End", "Frames", "FPS", "Regime") -ForegroundColor Cyan
Write-Host ("  " + ("-" * 60))

$boundarySet = New-Object System.Collections.Generic.HashSet[double]
for ($k = 1; $k -lt $regions.Count; $k++) {
    [void]$boundarySet.Add([math]::Round($regions[$k].StartPts / $ReportWindowSec) * $ReportWindowSec)
}

for ($g = 0; $g -lt $rowCount; $g += $groupBy) {
    $agg = $windows[$g..([math]::Min($g + $groupBy - 1, $rowCount - 1))]
    $sumFrames = ($agg | ForEach-Object { $_.Frames } | Measure-Object -Sum).Sum
    $firstStart = $agg[0].Start
    $lastEnd = $agg[$agg.Count - 1].End
    $dur = $lastEnd - $firstStart
    $avgFps = if ($dur -gt 0) { $sumFrames / $dur } else { 0 }
    $mark = ""
    if ($g -gt 0) {
        $prevFps = ($windows[([math]::Max(0, $g - $groupBy))..($g - 1)] | ForEach-Object { $_.Fps } | Measure-Object -Average).Average
        if ($prevFps -gt 0 -and [math]::Abs($avgFps - $prevFps) / $prevFps -gt 0.3) { $mark = "  <<< transition" }
    }
    Write-Host ("  {0,-12} {1,-12} {2,-10} {3,-9} {4}" -f (Format-Time $firstStart), (Format-Time $lastEnd), $sumFrames, [math]::Round($avgFps, 1), $mark)
}
Write-Host ""

# --- Regime summary table ---
Write-Host "  FPS regime summary (analysis window ${WindowSec}s):" -ForegroundColor Cyan
Write-Host ("  {0,-5} {1,-10} {2,-12} {3,-12} {4,-12} {5,-8}" -f "Part", "FPS", "Start", "End", "Duration", "Frames")
Write-Host ("  " + ("-" * 59))
$totalReportFrames = 0
for ($k = 0; $k -lt $regions.Count; $k++) {
    $r = $regions[$k]
    $dur = $r.EndPts - $r.StartPts
    $totalReportFrames += $r.Frames
    Write-Host ("  {0,-5} {1,-10} {2,-12} {3,-12} {4,-12} {5,-8}" -f ("#" + ($k + 1)), [math]::Round($r.Fps, 1), (Format-Time $r.StartPts), (Format-Time $r.EndPts), (Format-Time $dur), $r.Frames)
}
Write-Host ("  " + ("-" * 59))
Write-Info "  Total estimated frames: $totalReportFrames (reported: $($v.nb_frames))"

# --- Conclusion ---
Write-Host ""
if ($regions.Count -eq 1) {
    $avgFps = [math]::Round($regions[0].Fps, 2)
    Write-Ok "  Single fps regime (~$avgFps fps) — no VFR segmentation."
    if ([math]::Abs($rFpsRaw - $regions[0].Fps) / $regions[0].Fps -gt 0.15 -and [math]::Abs($vDur - $aDur) -le 2) {
        Write-Warn "  But r_frame_rate ($($v.r_frame_rate)) disagrees with actual (~$avgFps fps) while PTS is intact."
        Write-Warn "  This is the metadata-corruption case → fix with: fix-fps.ps1 -Strategy mkv"
    }
} else {
    Write-Warn "  $($regions.Count) distinct fps regimes detected."
    $transitions = ($regions | Select-Object -Skip 1 | ForEach-Object { Format-Time $_.StartPts }) -join ", "
    Write-Info "  Transition points: $transitions"
    Write-Info "  To split into parts:  split-pts-regions.ps1 \"$InputFile\""
}
Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Step "ANALYSIS DONE" Green
Write-Host ("=" * 70) -ForegroundColor Cyan