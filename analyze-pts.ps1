param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$InputFile,

    [Parameter(Position=1)]
    [string]$ReferenceFile,

    [switch]$ReportOnly
)

function Write-Banner {
    param([string]$Msg)
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host "  $Msg" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

function Analyze-Stream {
    param([string]$File, [string]$Label)

    $json = ffprobe -v quiet -print_format json -show_format -show_streams $File 2>$null | ConvertFrom-Json

    Write-Host "`n[$Label] 檔案: $File" -ForegroundColor Yellow
    Write-Host ("-" * 60)

    $format = $json.format
    Write-Host "  Format duration: $([math]::Round([double]$format.duration, 3))s"

    foreach ($stream in $json.streams) {
        $idx = $stream.index
        $type = $stream.codec_type
        $codec = $stream.codec_name
        $start = [double]$stream.start_time
        $dur = [double]$stream.duration
        $tb = $stream.time_base
        $frames = $stream.nb_frames
        $bitrate = $stream.bit_rate

        if ($type -eq "video") {
            $w = $stream.width
            $h = $stream.height
            $fps = $stream.r_frame_rate
            $avg = $stream.avg_frame_rate
            Write-Host "  [Stream #$idx] VIDEO: $codec ${w}x${h}, nominal $fps fps, avg_fps=$avg"
            Write-Host "    time_base=$tb, PTS range: ${start}s ~ $([math]::Round($start + $dur, 3))s (duration: $([math]::Round($dur, 3))s)"
            Write-Host "    frames=$frames, bitrate=$bitrate"

            if ($frames -gt 0 -and $dur -gt 0) {
                $real_fps = [double]$frames / [double]$dur
                Write-Host "    real avg fps: $([math]::Round($real_fps, 4))"

                # Check for PTS compression anomaly
                $expected_dur = $format.duration
                if ([double]$expected_dur -gt 0) {
                    $ratio = [double]$dur / [double]$expected_dur
                    if ($ratio -lt 0.8) {
                        Write-Host "    ⚠️  PTS COMPRESSION DETECTED: video PTS range ($([math]::Round($dur,1))s) is only $([math]::Round($ratio*100,1))% of container duration ($([math]::Round([double]$expected_dur,1))s)" -ForegroundColor Red
                    } elseif ($ratio -lt 0.95) {
                        Write-Host "    ⚠️  PTS RANGE SLIGHTLY SHORT: $([math]::Round($ratio*100,1))% of container duration" -ForegroundColor Yellow
                    } else {
                        Write-Host "    ✓ PTS range matches container duration" -ForegroundColor Green
                    }
                }
            }
        }
        elseif ($type -eq "audio") {
            $sr = $stream.sample_rate
            $ch = $stream.channels
            Write-Host "  [Stream #$idx] AUDIO: $codec ${sr}Hz ${ch}ch"
            Write-Host "    time_base=$tb, PTS range: ${start}s ~ $([math]::Round($start + $dur, 3))s (duration: $([math]::Round($dur, 3))s)"
            Write-Host "    frames=$frames, bitrate=$bitrate"
        }
    }

    # Compare video vs audio duration
    $v_dur = $null; $a_dur = $null
    foreach ($stream in $json.streams) {
        if ($stream.codec_type -eq "video") { $v_dur = [double]$stream.duration }
        if ($stream.codec_type -eq "audio") { $a_dur = [double]$stream.duration }
    }
    if ($v_dur -and $a_dur) {
        $diff = [math]::Abs($v_dur - $a_dur)
        Write-Host "`n  ⏱  Video-Audio duration diff: $([math]::Round($diff, 3))s" -ForegroundColor $(if ($diff -gt 1) {"Red"} else {"Green"})
        if ($diff -gt 1) {
            Write-Host "  ❌ LIKELY A/V SYNC ISSUE (diff > 1s)" -ForegroundColor Red
            # Known pattern: Twitch Creator Dashboard VOD download
            $expected_container = [double]$json.format.duration
            $ratio = $v_dur / $expected_container
            if ($ratio -lt 0.5) {
                Write-Host "  ℹ Probable cause: Twitch VOD download tool PTS compression bug" -ForegroundColor Yellow
                Write-Host "    Video PTS range ($([math]::Round($v_dur,1))s) is only $([math]::Round($ratio*100,1))% of real duration" -ForegroundColor Yellow
                Write-Host "    Fix: Download via HLS (貓抓/m3u8), then use fix-pts.ps1" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  ✓ A/V durations match within tolerance" -ForegroundColor Green
        }
    }
}

function Compare-PTS {
    param([string]$BrokenFile, [string]$RefFile)

    Write-Host "`n[PTS Cross-Comparison]" -ForegroundColor Yellow
    Write-Host ("-" * 60)

    $ref_json = ffprobe -v quiet -print_format json -show_streams $RefFile 2>$null | ConvertFrom-Json
    $broken_json = ffprobe -v quiet -print_format json -show_streams $BrokenFile 2>$null | ConvertFrom-Json

    $ref_v = $ref_json.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
    $broken_v = $broken_json.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1

    if (-not $ref_v -or -not $broken_v) {
        Write-Host "  Cannot compare: missing video stream in one file" -ForegroundColor Red
        return
    }

    $ref_frames = try { [int]$ref_v.nb_frames } catch { 0 }
    $broken_frames = try { [int]$broken_v.nb_frames } catch { 0 }
    if ($ref_frames -gt 0) { Write-Host "  Reference frames: $ref_frames" }
    if ($broken_frames -gt 0) { Write-Host "  Broken frames:    $broken_frames" }

    if ($ref_frames -gt 0 -and $broken_frames -gt 0) {
        if ($ref_frames -eq $broken_frames) {
            Write-Host "  ✓ Frame counts match (same video content)" -ForegroundColor Green
        } else {
            Write-Host "  ⚠️  Frame counts differ by $([math]::Abs($ref_frames - $broken_frames))" -ForegroundColor Yellow
        }
    } elseif ($ref_frames -eq 0) {
        Write-Host "  (Reference frame count unavailable - TS format limitation)" -ForegroundColor DarkGray
    }

    $ref_dur = [double]$ref_v.duration
    $broken_dur = [double]$broken_v.duration
    Write-Host "  Reference video PTS range: $([math]::Round($ref_dur, 3))s"
    Write-Host "  Broken video PTS range:    $([math]::Round($broken_dur, 3))s"

    if ($ref_dur -gt 0 -and $broken_dur -gt 0) {
        $ratio = $ref_dur / $broken_dur
        Write-Host "  Correction ratio needed: ~$([math]::Round($ratio, 4))x"
    }

    # Check time_base
    Write-Host "  Ref time_base: $($ref_v.time_base)"
    Write-Host "  Broken time_base: $($broken_v.time_base)"
}

# ====== MAIN ======
Write-Banner "PTS Diagnostic Tool v1.0"

if (-not (Test-Path $InputFile)) {
    Write-Host "ERROR: Input file not found: $InputFile" -ForegroundColor Red
    exit 1
}

Analyze-Stream $InputFile "INPUT"

if ($ReferenceFile -and (Test-Path $ReferenceFile)) {
    Analyze-Stream $ReferenceFile "REFERENCE"
    Compare-PTS $InputFile $ReferenceFile

    # Auto-fix suggestion
    Write-Host "`n[Suggested Fix]" -ForegroundColor Green
    Write-Host ("-" * 60)
    Write-Host "  Use: .\fix-pts.ps1 -ReferenceTS '$ReferenceFile'"
    Write-Host "  This remuxes the TS to MP4 with -copyts (preserving correct PTS)."
} else {
    Write-Host "`n  Tip: Provide -ReferenceFile <correct.ts> for cross-comparison and auto-fix." -ForegroundColor DarkGray
}

Write-Host "`n  Done." -ForegroundColor Cyan
