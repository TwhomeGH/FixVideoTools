param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$InputFile,

    [Parameter(Position=1)]
    [string]$OutputFile,

    [string]$SplitTime,
    [string]$OutputDir,
    [switch]$Force,
    [switch]$KeepTemp,
    [switch]$SkipVerify,
    [switch]$NoConcat
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

function Test-DiskSpace {
    param(
        [string]$Path,
        [double]$RequiredGB,
        [string]$Label = "disk"
    )
    try {
        $drive = New-Object System.IO.DriveInfo($Path.Substring(0, 3))
        $freeGB = $drive.AvailableFreeSpace / 1GB
        if ($freeGB -lt $RequiredGB) {
            throw "Insufficient disk space on ${Label}: only $([math]::Round($freeGB, 2)) GB free, need at least $([math]::Round($RequiredGB, 2)) GB"
        }
        Write-Info "  $Label free space: $([math]::Round($freeGB, 2)) GB"
        return $freeGB
    } catch {
        throw "Cannot check disk space for $Path : $_"
    }
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
    $ts = [timespan]::FromSeconds($Seconds)
    return "$($ts.Hours.ToString('00')):$($ts.Minutes.ToString('00')):$($ts.Seconds.ToString('00'))"
}

function Get-PtsDeltas {
    param([string]$File, [int]$MaxSamples = 2000)
    $pts = ffprobe -v quiet -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 $File 2>$null
    if (-not $pts -or $pts.Count -lt 10) { return $null }

    $total = $pts.Count
    $step = [math]::Max(1, [math]::Floor($total / $MaxSamples))
    $window = [math]::Max(1, [math]::Floor($step / 2))

    $result = @()
    for ($i = $step; $i -lt $total; $i += $step) {
        $delta = [double]$pts[$i] - [double]$pts[$i - $window]
        $avgDelta = $delta / $window
        $result += @{
            Frame = $i
            Pts = [double]$pts[$i]
            Delta = $avgDelta
        }
    }
    return $result
}

function Detect-BreakPoint {
    param([string]$File)

    Write-Step "Scanning PTS deltas for break point..." Yellow
    $deltas = Get-PtsDeltas $File -MaxSamples 1000
    if (-not $deltas -or $deltas.Count -lt 30) {
        Write-Err "  Cannot analyze PTS: too few frames"
        return $null
    }

    $count = $deltas.Count
    $baselineCount = [math]::Max(15, [math]::Floor($count * 0.2))
    $baseline = ($deltas[0..($baselineCount-1)] | ForEach-Object { $_.Delta } | Measure-Object -Average).Average

    Write-Info "Baseline delta: $([math]::Round($baseline, 5))s  (~$([math]::Round(1/$baseline, 1)) fps)"

    # Require a SUSTAINED drop: the first sample whose delta drops below 50% of
    # baseline AND whose following samples stay low. Per-sample detection avoids
    # the forward-window averaging that pulls the boundary earlier.
    $minHold = [math]::Max(3, [math]::Floor($count * 0.01))
    $breakFound = $null

    for ($i = $baselineCount; $i -lt $count - $minHold; $i++) {
        $ratio = $deltas[$i].Delta / $baseline
        if ($ratio -ge 0.5) { continue }

        # confirm the next minHold samples also stay below 0.5
        $sustained = $true
        for ($j = $i + 1; $j -le $i + $minHold; $j++) {
            if ($deltas[$j].Delta / $baseline -ge 0.5) { $sustained = $false; break }
        }
        if (-not $sustained) { continue }

        $breakFound = @{
            Frame = $deltas[$i].Frame
            PtsTime = $deltas[$i].Pts
            DeltaAvg = $deltas[$i].Delta
            Ratio = $ratio
        }
        Write-Info "Break detected at frame ~$($deltas[$i].Frame), PTS=$([math]::Round($deltas[$i].Pts, 1))s"
        Write-Info "  Delta dropped to $([math]::Round($ratio*100, 1))% of baseline ($([math]::Round(1/$deltas[$i].Delta, 1)) fps)"
        break
    }

    if (-not $breakFound) {
        Write-Step "No clear break point detected" DarkCyan
        return $null
    }

    return $breakFound
}

function Cut-Part1 {
    param([string]$File, [double]$Duration, [string]$OutPath)

    Write-Step "Cutting Part1 (0 ~ $([math]::Round($Duration, 0))s = $($(Format-Time $Duration)))" Green
    $tempPath = $script:WorkDir
    $tempPart1 = Join-Path $tempPath "ptsspike_$([System.IO.Path]::GetRandomFileName()).mp4"

    # Use audio-first stream copy for accurate cut
    ffmpeg -copyts -i $File -map 0:a -map 0:v -c copy -to $Duration -avoid_negative_ts make_zero -y $tempPart1 2>&1 | ForEach-Object {
        if ($_ -match "time=(\d+:\d+:\d+\.\d+)") {
            Write-Progress -Activity "Cutting Part1" -Status $matches[1]
        }
    }
    Write-Progress -Activity "Cutting Part1" -Completed

    if (-not (Test-Path $tempPart1)) {
        Write-Err "ERROR: Part1 cut failed"
        return $null
    }

    # Remux to restore video-first stream order
    ffmpeg -i $tempPart1 -map 0:1 -map 0:0 -c copy -avoid_negative_ts make_zero -y $OutPath 2>&1 | ForEach-Object {
        if ($_ -match "time=(\d+:\d+:\d+\.\d+)") {
            Write-Progress -Activity "Remuxing Part1" -Status $matches[1]
        }
    }
    Write-Progress -Activity "Remuxing Part1" -Completed

    Remove-Item $tempPart1 -Force -ErrorAction SilentlyContinue

    if (Test-Path $OutPath) {
        Write-Ok "  Part1 written: $OutPath"
        return Get-VideoInfo $OutPath
    }
    return $null
}

function Get-FirstPts {
    param([string]$File, [string]$StreamSpec)
    $pts = ffprobe -v quiet -select_streams $StreamSpec -show_entries packet=pts_time -of csv=p=0 $File 2>$null | Select-Object -First 1
    if ($pts) { return [double]$pts }
    return $null
}

function Cut-Part2 {
    param([string]$File, [double]$StartTime, [string]$OutPath)

    Write-Step "Cutting Part2 ($(Format-Time $StartTime) ~ end)" Green

    $tmpDir = $script:WorkDir
    $seekBack = [math]::Max(30, $StartTime * 0.01)

    # Step 1/3: Cut video stream at StartTime
    $tempVideo = Join-Path $tmpDir "ptsspike_$([System.IO.Path]::GetRandomFileName()).mp4"
    Write-Info "  Step 1/3: Cutting video at PTS $StartTime..."
    ffmpeg -ss ($StartTime - $seekBack) -copyts -i $File -map 0:v -c copy -ss $StartTime -y $tempVideo 2>&1 | ForEach-Object {
        if ($_ -match "time=(\d+:\d+:\d+\.\d+)") {
            Write-Progress -Activity "Cutting video" -Status $matches[1]
        }
    }
    Write-Progress -Activity "Cutting video" -Completed
    if (-not (Test-Path $tempVideo)) { Write-Err "ERROR: Video cut failed"; return $null }

    # Get actual first video PTS (original PTS preserved by -copyts)
    $vFirstOrigPts = Get-FirstPts $tempVideo "v:0"
    if (-not $vFirstOrigPts) { Write-Err "ERROR: Cannot read video PTS"; Remove-Item $tempVideo -Force; return $null }
    Write-Info ("  First video frame at original PTS {0:f4}s" -f $vFirstOrigPts)

    # Step 2/3: Cut audio stream from the original PTS StartTime.
    # NOTE: do NOT use $vFirstOrigPts — the MP4 muxer zeroed the temp video's PTS,
    # so that value is meaningless. The audio must start at StartTime so Part2 keeps
    # the full-length audio stream (needed to detect video-PTS-only compression).
    $tempAudio = Join-Path $tmpDir "ptsspike_$([System.IO.Path]::GetRandomFileName()).mp4"
    Write-Info ("  Step 2/3: Cutting audio at PTS {0:f4}s..." -f $StartTime)
    ffmpeg -ss ($StartTime - $seekBack) -copyts -i $File -map 0:a -c copy -ss $StartTime -y $tempAudio 2>&1 | ForEach-Object {
        if ($_ -match "time=(\d+:\d+:\d+\.\d+)") {
            Write-Progress -Activity "Cutting audio" -Status $matches[1]
        }
    }
    Write-Progress -Activity "Cutting audio" -Completed
    if (-not (Test-Path $tempAudio)) { Write-Err "ERROR: Audio cut failed"; Remove-Item $tempVideo -Force; return $null }

    # Step 3/3: Combine video + audio (PTS auto-normalizes on mux)
    Write-Info "  Step 3/3: Combining..."
    ffmpeg -i $tempVideo -i $tempAudio -c copy -y $OutPath 2>&1 | ForEach-Object {
        if ($_ -match "time=(\d+:\d+:\d+\.\d+)") {
            Write-Progress -Activity "Combining" -Status $matches[1]
        }
    }
    Write-Progress -Activity "Combining" -Completed
    Remove-Item $tempVideo, $tempAudio -Force -ErrorAction SilentlyContinue

    if (Test-Path $OutPath) {
        Write-Ok "  Part2 written: $OutPath"
        return Get-VideoInfo $OutPath
    }
    return $null
}

function Test-CfrSafe {
    param([string]$File)

    # CFR rebuild is safe when the video PTS timeline is STRONGLY compressed
    # relative to audio (vDur much smaller than aDur) AND per-frame deltas are
    # erratic. In that case the real frame rate is constant (frames/audio_dur)
    # and only the PTS labels are broken — uniform re-timing via -r is correct.
    #
    # Genuine VFR sources keep video PTS ≈ audio duration (PTS reflects real
    # time, only fps changes) — those must NOT go through CFR. The audio>>video
    # guard here guarantees we never route a VFR source into CFR.
    $info = Get-VideoInfo $File
    $v = $info.Video
    $a = $info.Audio
    if (-not $v -or -not $a) { return $true }

    $vDur = [double]$v.duration
    $aDur = [double]$a.duration
    $ratio = if ($aDur -gt 0) { $vDur / $aDur } else { 1 }
    $safe = $ratio -lt 0.5
    Write-Info ("  PTS/audio span ratio: {0:N2} {1}" -f $ratio, $(if ($safe) { "(CFR safe)" } else { "(not strongly compressed — skip CFR)" }))
    return $safe
}

function Fix-Part2Pts {
    param([string]$InputFile, [string]$OutputFile, [double]$PtsOffset)

    $info = Get-VideoInfo $InputFile
    $v = $info.Video
    $a = $info.Audio

    if (-not $v -or -not $a) {
        Write-Err "ERROR: Part2 missing video or audio stream"
        return $null
    }

    $vDur = [double]$v.duration
    $aDur = [double]$a.duration
    $frames = try { [double]$v.nb_frames } catch { 0 }

    Write-Step "Part2 analysis:" Yellow
    Write-Info "  Video PTS duration: $([math]::Round($vDur, 1))s"
    Write-Info "  Audio duration: $([math]::Round($aDur, 1))s"
    Write-Info "  Frames: $frames"
    Write-Info "  PTS offset for concat: +$([math]::Round($PtsOffset, 1))s"
    if ($vDur -le 0) {
        Write-Err "ERROR: Part2 video duration invalid"
        return $null
    }

    if ($aDur -gt $vDur + 2) {
        $ratio = $aDur / $vDur
        Write-Warn "  PTS compression detected: video=$([math]::Round($vDur,1))s vs audio=$([math]::Round($aDur,1))s"
        Write-Info "  Correction ratio: $([math]::Round($ratio, 4))x"
        Write-Info "  Target FPS: $([math]::Round($frames / $aDur, 4))  (was $([math]::Round($frames / $vDur, 4)))"

        # Decide between CFR rebuild and setts stretch by looking at the actual
        # video PTS delta uniformity — NOT by compression ratio. A file with
        # uneven per-frame deltas (some regions ~1x, others ~4x) cannot be fixed
        # with a single setts multiplier; that is exactly the "fast/slow jerky
        # video" symptom. CFR rebuild re-times every frame uniformly and is safe
        # when the PTS timeline is strongly compressed (real fps constant).
        $erratic = $false
        $deltas = Get-PtsDeltas $InputFile -MaxSamples 500
        if ($deltas -and $deltas.Count -gt 20) {
            $deltaVals = $deltas | ForEach-Object { $_.Delta }
            $avg = ($deltaVals | Measure-Object -Average).Average
            $min = ($deltaVals | Measure-Object -Minimum).Minimum
            if ($avg -gt 0 -and $min -gt 0 -and $min / $avg -lt 0.25) {
                $erratic = $true
                Write-Warn "  PTS deltas are erratic (min/avg=$([math]::Round($min/$avg*100, 1))%) — considering CFR rebuild"
            }
        }

        if ($erratic) {
            if (-not (Test-CfrSafe $InputFile)) {
                Write-Warn "  Not strongly compressed — CFR would destroy timing, using setts stretch instead"
                $erratic = $false
            } else {
                Write-Info "  Strongly compressed with uniform real fps — using CFR rebuild"
            }
        }

        if ($erratic) {
            $targetFps = [math]::Round($frames / $aDur, 4)

            $tmpDir = $script:WorkDir
            $tmpVideo = Join-Path $tmpDir "ptsspike_$([System.IO.Path]::GetRandomFileName()).h264"
            Write-Step "  Step 1/2: Extracting raw H.264..." DarkYellow
            ffmpeg -i $InputFile -c:v copy -bsf:v h264_mp4toannexb -f h264 -y $tmpVideo 2>&1 | ForEach-Object {
                if ($_ -match "time=(\d+:\d+:\d+\.\d+)") {
                    Write-Progress -Activity "Extracting H.264" -Status $matches[1]
                }
            }
            Write-Progress -Activity "Extracting H.264" -Completed

            Write-Step "  Step 2/2: Remuxing at $targetFps fps CFR + offset..." DarkYellow
            ffmpeg -r $targetFps -i $tmpVideo -i $InputFile -c copy -map 0:v -map 1:a -t $aDur -output_ts_offset $PtsOffset -video_track_timescale 90000 -movflags +faststart -y $OutputFile 2>&1 | ForEach-Object {
                if ($_ -match "time=(\d+:\d+:\d+\.\d+)") {
                    Write-Progress -Activity "CFR remux + offset" -Status $matches[1]
                }
            }
            Write-Progress -Activity "CFR remux + offset" -Completed
            Remove-Item $tmpVideo -Force -ErrorAction SilentlyContinue

        } else {
            Write-Step "Applying PTS stretch + offset..." Green
            # Stretch BOTH PTS and DTS — setts=pts only leaves DTS at the old
            # (compressed) scale, and a later MKV remux rebuilds the timeline
            # from DTS, truncating the video.
            # NOTE: ${ratio} braces required — `$ratio:dts` is parsed as a
            # drive-qualified variable and becomes null!
            ffmpeg -i $InputFile -c copy -bsf:v "setts=pts=PTS*${ratio}:dts=DTS*${ratio}" -map 0 -output_ts_offset $PtsOffset -video_track_timescale 90000 -y $OutputFile 2>&1 | ForEach-Object {
                if ($_ -match "time=(\d+:\d+:\d+\.\d+)") {
                    Write-Progress -Activity "Stretching PTS" -Status $matches[1]
                }
            }
            Write-Progress -Activity "Stretching PTS" -Completed
        }
    } elseif ($vDur -gt $aDur + 2) {
        $ratio = $aDur / $vDur
        Write-Warn "  Video PTS is longer than audio: ratio=$([math]::Round($ratio, 4))"
        Write-Step "Applying PTS compress + offset..." Green
        ffmpeg -i $InputFile -c copy -bsf:v "setts=pts=PTS*${ratio}:dts=DTS*${ratio}" -map 0 -output_ts_offset $PtsOffset -video_track_timescale 90000 -y $OutputFile 2>&1 | ForEach-Object {
            if ($_ -match "time=(\d+:\d+:\d+\.\d+)") {
                Write-Progress -Activity "Compressing PTS" -Status $matches[1]
            }
        }
        Write-Progress -Activity "Compressing PTS" -Completed
    } else {
        Write-Ok "  Part2 A/V durations already match within tolerance"
        Write-Step "  Shifting PTS by +$([math]::Round($PtsOffset, 1))s for concat..." DarkYellow
        ffmpeg -i $InputFile -c copy -map 0 -output_ts_offset $PtsOffset -video_track_timescale 90000 -y $OutputFile 2>&1 | ForEach-Object {
            if ($_ -match "time=(\d+:\d+:\d+\.\d+)") {
                Write-Progress -Activity "Shifting PTS" -Status $matches[1]
            }
        }
        Write-Progress -Activity "Shifting PTS" -Completed
    }

    if (Test-Path $OutputFile) {
        # NOTE: do NOT remux here. setts+output_ts_offset gives the intermediate
        # part2 the concat offset it needs; an MKV round-trip zeroes the PTS and
        # would truncate part2's video during concat. Metadata regeneration is
        # done on the FINAL output only.
        Write-Ok "  Fixed Part2: $OutputFile"
        return Get-VideoInfo $OutputFile
    }
    return $null
}

function Analyze-CompressionWindows {
    param([string]$File, [int]$Windows = 20)

    $info = Get-VideoInfo $File
    $aDur = [double]$info.Audio.duration
    if ($aDur -le 0) { return $null }

    $pts = ffprobe -v quiet -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 $File 2>$null
    if (-not $pts -or $pts.Count -lt $Windows * 5) { return $null }

    $total = $pts.Count
    $winSize = [math]::Floor($total / $Windows)
    $results = @()

    for ($i = 0; $i -lt $Windows; $i++) {
        $s = $i * $winSize
        $e = [math]::Min(($i + 1) * $winSize - 1, $total - 2)
        if ($s -ge $e) { break }

        $vStart = [double]$pts[$s]
        $vEnd = [double]$pts[$e]
        $vDur = $vEnd - $vStart
        if ($vDur -le 0) { continue }

        $pctStart = $s / $total
        $pctEnd = ($e + 1) / $total
        $aSegDur = ($pctEnd - $pctStart) * $aDur
        $ratio = $aSegDur / $vDur

        $results += @{
            Window = $i
            FrameS = $s
            FrameE = $e
            VStart = $vStart
            VEnd   = $vEnd
            VDur   = $vDur
            Ratio  = $ratio
        }
    }
    return $results
}

function Find-CompressionBreaks {
    param($Windows, [double]$Threshold = 0.30)

    if (-not $Windows -or $Windows.Count -lt 4) { return @() }

    $ratios = $Windows | ForEach-Object { $_.Ratio }
    $avg = ($ratios | Measure-Object -Average).Average
    $breaks = @()

    for ($i = 2; $i -lt $Windows.Count - 2; $i++) {
        $localAvg = ($ratios[($i-2)..($i+2)] | Measure-Object -Average).Average
        $deviation = [math]::Abs($ratios[$i] - $localAvg) / $localAvg
        if ($deviation -gt $Threshold) {
            $breakPts = [math]::Round(($Windows[$i].VStart + $Windows[$i].VEnd) / 2, 3)
            $breaks += @{ PtsTime = $breakPts; Ratio = $ratios[$i]; Deviation = $deviation }
        }
    }
    return $breaks
}

function Fix-Part2PtsMulti {
    param([string]$InputFile, [string]$OutputFile, [double]$PtsOffset)

    $tmpDir = $script:WorkDir

    # If audio >> video PTS, the audio is the healthy reference timeline. The
    # question is whether the compression is uniform (single ratio works) or
    # uneven (needs CFR or multi-segment). Defer to Fix-Part2Pts which inspects
    # PTS delta uniformity — do NOT force single-ratio here.
    # (Splitting part2 by video PTS would truncate the healthy audio, so the
    # multi-segment path below is only valid when audio PTS matches video PTS.)
    $gInfo = Get-VideoInfo $InputFile
    $gV = $gInfo.Video
    $gA = $gInfo.Audio
    if ($gV -and $gA) {
        $gVDur = [double]$gV.duration
        $gADur = [double]$gA.duration
        if ($gADur -gt $gVDur * 1.5) {
            Write-Warn "  Audio is the reference timeline (audio=$([math]::Round($gADur,1))s vs video PTS=$([math]::Round($gVDur,1))s)"
            Write-Warn "  Delegating to Fix-Part2Pts (uniform ratio → setts; erratic deltas → CFR)"
            return Fix-Part2Pts $InputFile $OutputFile $PtsOffset
        }
    }

    # Analyze compression windows
    $windows = Analyze-CompressionWindows $InputFile -Windows 20
    if (-not $windows) { return Fix-Part2Pts $InputFile $OutputFile $PtsOffset }

    $uniform = $true
    if ($windows.Count -ge 4) {
        $ratios = $windows | ForEach-Object { $_.Ratio }
        $min = ($ratios | Measure-Object -Minimum).Minimum
        $max = ($ratios | Measure-Object -Maximum).Maximum
        $avg = ($ratios | Measure-Object -Average).Average
        # If ratio varies by more than 25% from average, non-uniform
        if ($avg -gt 0 -and ($max - $min) / $avg -gt 0.25) { $uniform = $false }
    }

    if ($uniform) {
        Write-Info "  Compression ratio is uniform — using single-ratio fix"
        return Fix-Part2Pts $InputFile $OutputFile $PtsOffset
    }

    Write-Warn "  Compression ratio varies across segment — using multi-segment fix"
    $breaks = Find-CompressionBreaks $windows

    # Build split points (in PTS, from the raw part2)
    $splitPts = @(0)
    foreach ($b in $breaks) {
        $splitPts += $b.PtsTime
    }
    $info = Get-VideoInfo $InputFile
    $splitPts += [double]$info.Video.duration
    $splitPts = $splitPts | Sort-Object -Unique

    Write-Info "  Splitting at $($splitPts.Count - 1) sub-segments..."

    $segPaths = @()
    $totalDur = 0
    $accumOffset = $PtsOffset

    for ($i = 0; $i -lt $splitPts.Count - 1; $i++) {
        $segStart = $splitPts[$i]
        $segEnd   = $splitPts[$i + 1]
        $segDur   = $segEnd - $segStart
        if ($segDur -lt 1) { continue }

        $rawSeg = Join-Path $tmpDir "ptsspike_ms_$([System.IO.Path]::GetRandomFileName()).mp4"
        $fixedSeg = Join-Path $tmpDir "ptsspike_mf_$([System.IO.Path]::GetRandomFileName()).mp4"

        Test-DiskSpace $tmpDir $script:RequiredGB "work dir (multi-segment)" | Out-Null

        # Cut segment (stream copy, A/V together since part2_raw is already aligned)
        Write-Info "    Segment $(($i+1)): PTS $([math]::Round($segStart,1))s ~ $([math]::Round($segEnd,1))s"
        $ok = $false
        if ($i -eq 0) {
            # First segment: include from beginning
            ffmpeg -copyts -i $InputFile -c copy -map 0 -to $segEnd -y $rawSeg 2>&1 | Out-Null
            if (Test-Path $rawSeg) { $ok = $true }
        } else {
            ffmpeg -copyts -i $InputFile -c copy -map 0 -ss $segStart -to $segEnd -y $rawSeg 2>&1 | Out-Null
            if (Test-Path $rawSeg) { $ok = $true }
        }
        if (-not $ok) { Write-Warn "      Segment $(($i+1)) cut failed, skipping"; continue }

        # Fix segment with its own ratio + accumulated offset
        $fixedInfo = Fix-Part2Pts $rawSeg $fixedSeg $accumOffset
        Remove-Item $rawSeg -Force -ErrorAction SilentlyContinue

        if (-not $fixedInfo) { Write-Warn "      Segment $(($i+1)) fix failed, skipping"; continue }

        $segVDur = [double]$fixedInfo.Video.duration
        $accumOffset += $segVDur
        $totalDur += $segVDur
        $segPaths += $fixedSeg
    }

    if ($segPaths.Count -eq 0) { throw "Multi-segment fix produced no valid segments" }
    if ($segPaths.Count -eq 1) {
        # Only one segment — just use it directly
        Move-Item $segPaths[0] $OutputFile -Force
        return Get-VideoInfo $OutputFile
    }

    # Concat all fixed segments
    $concatList = Join-Path $tmpDir "ptsspike_concat_$([System.IO.Path]::GetRandomFileName()).txt"
    $lines = $segPaths | ForEach-Object { "file '$_'" }
    $lines -join "`n" | Set-Content -Path $concatList -Encoding ASCII

    ffmpeg -f concat -safe 0 -i $concatList -c copy -map 0 -y $OutputFile 2>&1 | Out-Null
    Remove-Item $concatList -Force -ErrorAction SilentlyContinue

    # Cleanup segment files
    foreach ($p in $segPaths) { Remove-Item $p -Force -ErrorAction SilentlyContinue }

    if (Test-Path $OutputFile) {
        Write-Ok "  Multi-segment fixed: $OutputFile"
        return Get-VideoInfo $OutputFile
    }
    return $null
}

function Concat-Parts {
    param([string]$Part1, [string]$Part2, [string]$OutputFile)

    Write-Step "Concatenating Part1 + Fixed Part2..." Green

    $tmpDir = $script:WorkDir
    $concatFile = Join-Path $tmpDir "ptsspike_$([System.IO.Path]::GetRandomFileName()).txt"

    # Use ffmpeg concat demuxer. Write UTF-8 WITHOUT BOM — ffmpeg's concat demuxer
    # rejects a leading BOM as an unknown keyword. UTF-8 (not ASCII) so Chinese
    # filenames survive.
    $listContent = @"
file '$($Part1 -replace "'","'\\''")'
file '$($Part2 -replace "'","'\\''")'
"@
    [System.IO.File]::WriteAllText($concatFile, $listContent, (New-Object System.Text.UTF8Encoding($false)))

    ffmpeg -f concat -safe 0 -i $concatFile -c copy -map 0 -movflags +faststart -y $OutputFile 2>&1 | ForEach-Object {
        if ($_ -match "time=(\d+:\d+:\d+\.\d+)") {
            Write-Progress -Activity "Concatenating" -Status $matches[1]
        }
    }
    Write-Progress -Activity "Concatenating" -Completed

    Remove-Item $concatFile -Force -ErrorAction SilentlyContinue

    # NOTE: no remux needed. setts stretches BOTH pts and dts, so the MP4 muxer
    # writes a correct stts table directly — an MKV round-trip is unnecessary
    # and doubles the disk requirement.
    return (Test-Path $OutputFile)
}


# ====== MAIN ======
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "  PTS Spike Fix Tool v1.1" -ForegroundColor Cyan
Write-Host "  Detects and repairs PTS anomalies causing FPS spikes" -ForegroundColor Cyan
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "  -NoConcat : output part1 + part2_fixed separately (skip merge)" -ForegroundColor DarkGray
Write-Host "  -OutputDir PATH : output directory (default: same as input)" -ForegroundColor DarkGray
Write-Host "  -SplitTime HH:MM:SS : manual split point" -ForegroundColor DarkGray

# Validate input
if (-not (Test-Path -LiteralPath $InputFile)) {
    Write-Err "ERROR: Input file not found: $InputFile"
    exit 1
}

Test-FFmpeg

# ---- Work dir (local, avoids C: temp space issues) ----
$script:WorkDir = Join-Path $PSScriptRoot "_tmp"
if (-not (Test-Path $script:WorkDir)) {
    New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null
}

# ---- Minimum free space guard (stop early rather than filling the disk) ----
$script:MinFreeGB = 1.0
$inSizeGB = (Get-Item -LiteralPath $InputFile).Length / 1GB
$script:RequiredGB = [math]::Max($script:MinFreeGB, [math]::Round($inSizeGB * 2.5, 2))
Write-Step "Disk guard: need >= $($script:RequiredGB) GB free (input=$([math]::Round($inSizeGB, 2)) GB)" DarkGray

# Analyze input
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
$inFmtDur = if ($inInfo.Format) { [double]$inInfo.Format.duration } else { 0 }

Write-Info "Video: $($inV.codec_name) $($inV.width)x$($inV.height), PTS=$([math]::Round($inVDur,1))s, frames=$($inV.nb_frames)"
if ($inA) {
    Write-Info "Audio: $($inA.codec_name), duration=$([math]::Round($inADur,1))s"
    $diff = [math]::Abs($inVDur - $inADur)
    if ($diff -gt 2) {
        Write-Warn "  A/V duration diff: $([math]::Round($diff, 1))s (PTS compression suspected)"
    }
}

# Determine split point
$actualSplitTime = $null

if ($SplitTime) {
    # Parse manual split time
    if ($SplitTime -match '^(\d+):(\d+):(\d+)$') {
        $actualSplitTime = [double]$matches[1] * 3600 + [double]$matches[2] * 60 + [double]$matches[3]
        Write-Step "Using manual split time: $SplitTime = $([math]::Round($actualSplitTime, 0))s" Cyan
    } elseif ($SplitTime -match '^(\d+)$') {
        $actualSplitTime = [double]$SplitTime
        Write-Step "Using manual split time: $([math]::Round($actualSplitTime, 0))s" Cyan
    } else {
        Write-Err "ERROR: Invalid SplitTime format. Use HH:MM:SS or seconds."
        exit 1
    }
} else {
    # Auto-detect
    Write-Step "Auto-detecting break point..." Yellow
    $breakPt = Detect-BreakPoint $InputFile
    if ($breakPt) {
        $actualSplitTime = $breakPt.PtsTime
        Write-Ok "  Auto-detected break at PTS=$([math]::Round($actualSplitTime, 1))s"
    } else {
        Write-Err "ERROR: No break point detected. Use -SplitTime to specify manually."
        exit 1
    }
}

# Validate split time
if ($actualSplitTime -le 0 -or $actualSplitTime -ge $inVDur) {
    Write-Err "ERROR: Split time outside video PTS range (0 ~ $([math]::Round($inVDur, 1))s)"
    exit 1
}

# Determine output paths
$inDir = Split-Path $InputFile -Parent
$base = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
$outDir = if ($OutputDir) { $OutputDir } else { $inDir }

# Ensure output dir exists
if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    Write-Step "Created output dir: $outDir" DarkGray
}

# Verify both work dir and output dir have enough space
Test-DiskSpace $script:WorkDir $script:RequiredGB "work dir ($script:WorkDir)" | Out-Null
Test-DiskSpace $outDir $script:RequiredGB "output dir ($outDir)" | Out-Null

if ($NoConcat) {
    $part1Output = Join-Path $outDir "${base}_part1.mp4"
    $part2FixedOutput = Join-Path $outDir "${base}_part2_fixed.mp4"

    if ((Test-Path $part1Output) -and -not $Force) {
        Write-Err "ERROR: Part1 output exists: $part1Output (use -Force to overwrite)"
        exit 1
    }
    if ((Test-Path $part2FixedOutput) -and -not $Force) {
        Write-Err "ERROR: Part2 fixed output exists: $part2FixedOutput (use -Force to overwrite)"
        exit 1
    }
} else {
    if (-not $OutputFile) {
        $OutputFile = Join-Path $outDir "${base}_fixed.mp4"
    }
    if ((Test-Path $OutputFile) -and -not $Force) {
        Write-Err "ERROR: Output exists: $OutputFile (use -Force to overwrite)"
        exit 1
    }
}

# Prepare paths
$tmpDir = $script:WorkDir
$part2RawPath = Join-Path $tmpDir "ptsspike_part2_$([System.IO.Path]::GetRandomFileName()).mp4"

if ($NoConcat) {
    $part1Path = $part1Output
    $part2FixedPath = $part2FixedOutput
} else {
    $part1Path = Join-Path $tmpDir "ptsspike_part1_$([System.IO.Path]::GetRandomFileName()).mp4"
    $part2FixedPath = Join-Path $tmpDir "ptsspike_part2fixed_$([System.IO.Path]::GetRandomFileName()).mp4"
}

try {
    # Step 1: Cut Part1
    Write-Host ""
    Write-Host ("-" * 60)
    Write-Step "PHASE 1: Cut Part1 (0 ~ $([math]::Round($actualSplitTime, 0))s)" Yellow
    Test-DiskSpace $script:WorkDir $script:RequiredGB "work dir" | Out-Null
    $part1Info = Cut-Part1 $InputFile $actualSplitTime $part1Path
    if (-not $part1Info) { throw "Part1 cut failed" }

    # Step 2: Cut Part2
    Write-Host ""
    Write-Host ("-" * 60)
    Write-Step "PHASE 2: Cut Part2 (remainder)" Yellow
    Test-DiskSpace $script:WorkDir $script:RequiredGB "work dir" | Out-Null
    $part2Info = Cut-Part2 $InputFile $actualSplitTime $part2RawPath
    if (-not $part2Info) { throw "Part2 cut failed" }

    # Step 3: Fix Part2 PTS (auto-detect uniform vs multi-segment)
    Write-Host ""
    Write-Host ("-" * 60)
    Write-Step "PHASE 3: Fix Part2 PTS" Yellow
    Test-DiskSpace $script:WorkDir $script:RequiredGB "work dir" | Out-Null
    $ptsOffset = if ($NoConcat) { 0 } else { [double]$part1Info.Video.duration }
    $fixedInfo = Fix-Part2PtsMulti $part2RawPath $part2FixedPath $ptsOffset
    if (-not $fixedInfo) { throw "Part2 fix failed" }

    if ($NoConcat) {
        # Phase 4: done — parts are already at final paths
        Write-Host ""
        Write-Host ("-" * 60)
        Write-Step "PHASE 4: Done — parts saved separately" Yellow
        Write-Ok "  Part1: $part1Path"
        Write-Ok "  Part2 fixed: $part2FixedPath"

        # Verify each part
        if (-not $SkipVerify) {
            foreach ($label in @(@{Path=$part1Path; Name="Part1"}, @{Path=$part2FixedPath; Name="Part2 fixed"})) {
                Write-Host ""
                Write-Step "Verify $($label.Name)" Yellow
                $vi = Get-VideoInfo $label.Path
                $v = $vi.Video; $a = $vi.Audio
                if ($v -and $a) {
                    $vD = [double]$v.duration; $aD = [double]$a.duration; $d = [math]::Abs($vD - $aD)
                    Write-Info "  Video PTS: $([math]::Round($vD,1))s  Audio: $([math]::Round($aD,1))s  Diff: $([math]::Round($d,2))s"
                    if ($d -lt 2) { Write-Ok "  A/V sync OK" } else { Write-Warn "  A/V diff $([math]::Round($d,2))s" }
                }
            }
        }

        Write-Host ""
        Write-Host ("=" * 70) -ForegroundColor Cyan
        Write-Step "DONE — inspect each part separately before concatenating manually" Green
        Write-Ok "  Part1:       $part1Path"
        Write-Ok "  Part2 fixed: $part2FixedPath"
        Write-Host ("=" * 70) -ForegroundColor Cyan
    } else {
        # Step 4: Concatenate
        Write-Host ""
        Write-Host ("-" * 60)
        Write-Step "PHASE 4: Concatenate" Yellow
        Test-DiskSpace $outDir $script:RequiredGB "output dir" | Out-Null
        $ok = Concat-Parts $part1Path $part2FixedPath $OutputFile
        if (-not $ok) { throw "Concatenation failed" }

        # Step 5: Verify
        if (-not $SkipVerify) {
            Write-Host ""
            Write-Host ("-" * 60)
            Write-Step "PHASE 5: Verify Output" Yellow
            $outInfo = Get-VideoInfo $OutputFile
            $outV = $outInfo.Video
            $outA = $outInfo.Audio

            if ($outV -and $outA) {
                $vDur = [double]$outV.duration
                $aDur = [double]$outA.duration
                $diff = [math]::Abs($vDur - $aDur)

                Write-Info "  Video PTS duration: $([math]::Round($vDur, 1))s  ($(Format-Time $vDur))"
                Write-Info "  Audio duration:     $([math]::Round($aDur, 1))s  ($(Format-Time $aDur))"

                if ($diff -lt 2) {
                    Write-Ok "  A/V sync: OK (diff=$([math]::Round($diff, 2))s)"
                } else {
                    Write-Warn "  A/V sync: diff=$([math]::Round($diff, 2))s"
                }

                $r_fps = try { [double]($outV.r_frame_rate -split '/')[0] / [double]($outV.r_frame_rate -split '/')[1] } catch { 0 }
                Write-Info "  r_frame_rate: $($outV.r_frame_rate) (~$([math]::Round($r_fps, 2)) fps)"
                Write-Info "  Container duration: $([math]::Round([double]$outInfo.Format.duration, 1))s"

                if ($diff -lt 2) {
                    Write-Step "VERIFIED: A/V sync OK" Green
                } else {
                    Write-Warn "WARNING: A/V duration mismatch persists"
                }
            }

            $inSize = (Get-Item $InputFile).Length / 1GB
            $outSize = (Get-Item $OutputFile).Length / 1GB
            Write-Info "  Input size:  $([math]::Round($inSize, 3)) GB"
            Write-Info "  Output size: $([math]::Round($outSize, 3)) GB"
        }

        Write-Host ""
        Write-Host ("=" * 70) -ForegroundColor Cyan
        Write-Step "SUCCESS! Output: $OutputFile" Green
        Write-Host ("=" * 70) -ForegroundColor Cyan
    }

} catch {
    Write-Err "ERROR: $_"
    exit 1
} finally {
    if (-not $KeepTemp) {
        Remove-Item $part2RawPath -Force -ErrorAction SilentlyContinue
        if (-not $NoConcat) {
            Remove-Item $part1Path -Force -ErrorAction SilentlyContinue
            Remove-Item $part2FixedPath -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-Step "Temp files kept" DarkGray
    }
}
