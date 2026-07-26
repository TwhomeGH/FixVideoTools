param(
    [Parameter(Mandatory=$true)]
    [string]$InputFile,
    [int]$MaxSamples = 0,
    [switch]$ShowAllDeltas
)

$ffmpeg = "ffmpeg"
$ffprobe = "ffprobe"

if (-not (Get-Command $ffprobe -ErrorAction SilentlyContinue)) {
    Write-Error "ffprobe not found in PATH"
    exit 1
}

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  PTS Delta Analyzer v1.0" -ForegroundColor Cyan
Write-Host "  Analyzes PTS delta distribution and compression ratio trends" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""

# Get stream info
$json = ffprobe -v quiet -print_format json -show_streams $InputFile 2>$null | ConvertFrom-Json
$v = $json.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
$a = $json.streams | Where-Object { $_.codec_type -eq "audio" } | Select-Object -First 1

if (-not $v) {
    Write-Error "No video stream found"
    exit 1
}

Write-Host ("[INPUT] {0}" -f $InputFile) -ForegroundColor Yellow
Write-Host ("  Video: {0} {1}x{2}" -f $v.codec_name, $v.width, $v.height)
Write-Host ("  Audio: {0} {1}Hz" -f $a.codec_name, $a.sample_rate)
Write-Host ""

# Read video PTS
Write-Host "Reading video PTS..." -NoNewline
$vpts = ffprobe -v quiet -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 $InputFile 2>$null
$vlist = $vpts -split "`n" | Where-Object { $_ -ne "" }
$vcount = $vlist.Count
Write-Host " $vcount frames"

# Read audio PTS
$apts = $null
if ($a) {
    Write-Host "Reading audio PTS..." -NoNewline
    $aptsRaw = ffprobe -v quiet -select_streams a:0 -show_entries packet=pts_time -of csv=p=0 $InputFile 2>$null
    $alist = $aptsRaw -split "`n" | Where-Object { $_ -ne "" }
    $acount = $alist.Count
    Write-Host " $acount packets"
}
Write-Host ""

# Limit samples if requested
$sampleCount = $vcount
if ($MaxSamples -gt 0 -and $MaxSamples -lt $vcount) {
    $sampleCount = $MaxSamples
}

# Calculate deltas
$deltas = @()
$sampleStep = [math]::Floor($vcount / $sampleCount)
for ($i = 1; $i -lt $vlist.Count; $i += $sampleStep) {
    $d = [double]$vlist[$i] - [double]$vlist[$i-1]
    $deltas += $d
}
$deltaCount = $deltas.Count

Write-Host "=== Delta Statistics ===" -ForegroundColor Cyan
$avg = if ($deltaCount -gt 0) { ($deltas | Measure-Object -Average).Average } else { 0 }
$min = if ($deltaCount -gt 0) { ($deltas | Measure-Object -Minimum).Minimum } else { 0 }
$max = if ($deltaCount -gt 0) { ($deltas | Measure-Object -Maximum).Maximum } else { 0 }

$sorted = $deltas | Sort-Object
$p10 = if ($deltaCount -gt 0) { $sorted[[math]::Floor($sorted.Count * 0.10) ] } else { 0 }
$p25 = if ($deltaCount -gt 0) { $sorted[[math]::Floor($sorted.Count * 0.25) ] } else { 0 }
$p50 = if ($deltaCount -gt 0) { $sorted[[math]::Floor($sorted.Count * 0.50) ] } else { 0 }
$p75 = if ($deltaCount -gt 0) { $sorted[[math]::Floor($sorted.Count * 0.75) ] } else { 0 }
$p90 = if ($deltaCount -gt 0) { $sorted[[math]::Floor($sorted.Count * 0.90) ] } else { 0 }

Write-Host ("  Samples: {0}" -f $deltaCount)
Write-Host ("  Min:     {0,9:f5}s  (~{1,7:f1} fps)" -f $min, $(if ($min -gt 0) { 1/$min } else { 0 }))
Write-Host ("  Max:     {0,9:f5}s  (~{1,7:f1} fps)" -f $max, $(if ($max -gt 0) { 1/$max } else { 0 }))
Write-Host ("  Avg:     {0,9:f5}s  (~{1,7:f1} fps)" -f $avg, $(if ($avg -gt 0) { 1/$avg } else { 0 }))
Write-Host ("  P10:     {0,9:f5}s  (~{1,7:f1} fps)" -f $p10, $(if ($p10 -gt 0) { 1/$p10 } else { 0 }))
Write-Host ("  P25:     {0,9:f5}s  (~{1,7:f1} fps)" -f $p25, $(if ($p25 -gt 0) { 1/$p25 } else { 0 }))
Write-Host ("  P50:     {0,9:f5}s  (~{1,7:f1} fps)" -f $p50, $(if ($p50 -gt 0) { 1/$p50 } else { 0 }))
Write-Host ("  P75:     {0,9:f5}s  (~{1,7:f1} fps)" -f $p75, $(if ($p75 -gt 0) { 1/$p75 } else { 0 }))
Write-Host ("  P90:     {0,9:f5}s  (~{1,7:f1} fps)" -f $p90, $(if ($p90 -gt 0) { 1/$p90 } else { 0 }))

# Check for erratic pattern
$minPctOfAvg = if ($avg -gt 0) { $min / $avg * 100 } else { 0 }
if ($minPctOfAvg -lt 10) {
    Write-Host "  !! PTS deltas are ERRATIC (min/avg = $([math]::Round($minPctOfAvg, 1))%)" -ForegroundColor Yellow
}

# Compression ratio trend
Write-Host ""
Write-Host "=== Compression Ratio Trend ===" -ForegroundColor Cyan
$audioDur = if ($a) { [double]$a.duration } else { 0 }
$videoDur = [double]$vlist[$vlist.Count-1] - [double]$vlist[0]
$overallRatio = if ($videoDur -gt 0 -and $audioDur -gt 0) { $audioDur / $videoDur } else { 0 }

if ($audioDur -gt 0 -and $videoDur -gt 0) {
    Write-Host ("  Video PTS range: {0:f1}s" -f $videoDur)
    Write-Host ("  Audio duration:  {0:f1}s" -f $audioDur)
    Write-Host ("  Overall ratio:   {0:f4}x" -f $overallRatio)
    Write-Host ""

    $ratios = @()
    for ($pct = 5; $pct -le 100; $pct += 5) {
        $vIdx = [math]::Min([math]::Floor($vcount * $pct / 100), $vcount-1)
        $vPts = [double]$vlist[$vIdx]
        $expectedAudio = ($pct / 100) * $audioDur
        $ratioAtPoint = if ($vPts -gt 0) { $expectedAudio / $vPts } else { 0 }
        $ratios += $ratioAtPoint
        Write-Host ("  {0,3}%: PTS={1,8:f2}s  expected_audio={2,8:f1}s  ratio={3,6:f3}x" -f $pct, $vPts, $expectedAudio, $ratioAtPoint)
    }

    # Detect trend
    $firstHalf = $ratios[0..([math]::Floor($ratios.Count/2)-1)]
    $secondHalf = $ratios[([math]::Floor($ratios.Count/2))..($ratios.Count-1)]
    $firstAvg = ($firstHalf | Measure-Object -Average).Average
    $secondAvg = ($secondHalf | Measure-Object -Average).Average
    $trendDir = if ($secondAvg -gt $firstAvg * 1.05) { "rising (compression worsens toward end)" }
                elseif ($secondAvg -lt $firstAvg * 0.95) { "falling (compression eases toward end)" }
                else { "stable" }

    Write-Host ""
    Write-Host ("  Trend: {0}" -f $trendDir) -ForegroundColor $(if ($trendDir -eq "stable") { "Green" } else { "Yellow" })
    Write-Host ("  Early avg ratio: {0:f3}x" -f $firstAvg)
    Write-Host ("  Late avg ratio:  {0:f3}x" -f $secondAvg)

    if ($trendDir -ne "stable") {
        Write-Host "  !! Variable compression detected - single stretch ratio will cause gradual A/V desync" -ForegroundColor Yellow
    }
}

# A/V sync check
if ($alist -and $alist.Count -gt 0) {
    Write-Host ""
    Write-Host "=== A/V Sync Check ===" -ForegroundColor Cyan
    Write-Host ("  {0,-5}  {1,-8}  {2,-10}  {3,-8}  {4,-10}  {5}" -f "Time%", "Frame#", "vPTS", "Audio#", "aPTS", "Diff")
    for ($pct = 0; $pct -le 100; $pct += 10) {
        $vIdx = [math]::Min([math]::Floor($vcount * $pct / 100), $vcount-1)
        $aIdx = [math]::Min([math]::Floor($acount * $pct / 100), $acount-1)

        $vPts = [double]$vlist[$vIdx]
        if ($pct -eq 100) { $vPts = [double]$vlist[$vcount-1] }

        $aPts = [double]$alist[$aIdx]
        if ($pct -eq 100) { $aPts = [double]$alist[$acount-1] }

        $diff = $vPts - $aPts
        Write-Host ("  {0,3}%  {1,-8}  {2,-10:f3}  {3,-8}  {4,-10:f3}  {5,7:f3}s" -f $pct, $vIdx, $vPts, $aIdx, $aPts, $diff)
    }
}

Write-Host ""
Write-Host "Done."