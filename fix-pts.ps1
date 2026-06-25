param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$ReferenceTS,

    [Parameter(Position=1)]
    [string]$OutputFile,

    [switch]$Force,
    [switch]$KeepOffset
)

function Write-Step {
    param([string]$Msg, [string]$Color)
    Write-Host ">>> $Msg" -ForegroundColor $Color
}

function Test-FFmpeg {
    $ver = ffmpeg -version 2>&1 | Select-Object -First 1
    if (-not $ver) {
        Write-Host "ERROR: ffmpeg not found. Install from https://ffmpeg.org/" -ForegroundColor Red
        exit 1
    }
    Write-Step "ffmpeg: $ver" Cyan
}

Write-Host "=" * 70 -ForegroundColor Cyan
Write-Host "  PTS Fix Tool v2.0" -ForegroundColor Cyan
Write-Host "  Remuxes a TS (HLS) file to MP4 with correct timestamps" -ForegroundColor Cyan
Write-Host "  Use -copyts to preserve original PTS (handles discontinuities)" -ForegroundColor Cyan
Write-Host "=" * 70 -ForegroundColor Cyan

if (-not (Test-Path $ReferenceTS)) {
    Write-Host "ERROR: Reference TS file not found: $ReferenceTS" -ForegroundColor Red
    exit 1
}

Test-FFmpeg

$ext = [System.IO.Path]::GetExtension($ReferenceTS).ToLower()
if ($ext -ne ".ts" -and $ext -ne ".m2ts" -and $ext -ne ".mts") {
    Write-Host "WARNING: Input is not a TS file (got $ext). Proceeding anyway..." -ForegroundColor Yellow
}

if (-not $OutputFile) {
    $dir = Split-Path $ReferenceTS -Parent
    $base = [System.IO.Path]::GetFileNameWithoutExtension($ReferenceTS)
    $OutputFile = Join-Path $dir "${base}_fixed.mp4"
}

if ((Test-Path $OutputFile) -and -not $Force) {
    Write-Host "ERROR: Output exists: $OutputFile (use -Force to overwrite)" -ForegroundColor Red
    exit 1
}

# Step 1: Analyze reference file
Write-Step "Analyzing reference TS..." Yellow
$ref_info = ffprobe -v quiet -print_format json -show_streams $ReferenceTS 2>$null | ConvertFrom-Json

$ref_v = $ref_info.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
$ref_a = $ref_info.streams | Where-Object { $_.codec_type -eq "audio" } | Select-Object -First 1

if (-not $ref_v) { Write-Host "ERROR: No video stream in reference" -ForegroundColor Red; exit 1 }
if (-not $ref_a) { Write-Host "ERROR: No audio stream in reference" -ForegroundColor Red; exit 1 }

$v_dur = [double]$ref_v.duration
$a_dur = [double]$ref_a.duration
$diff = [math]::Abs($v_dur - $a_dur)

Write-Step "Video duration: $([math]::Round($v_dur, 1))s, Audio duration: $([math]::Round($a_dur, 1))s" Yellow
if ($diff -gt 1) {
    Write-Host "WARNING: A/V duration differs by $([math]::Round($diff, 1))s in source!" -ForegroundColor Yellow
}

# Step 2: Remux with -copyts to preserve timestamps
Write-Step "Remuxing TS → MP4 (preserving original PTS with -copyts)..." Green

if ($KeepOffset) {
    Write-Step "Keeping original PTS offset (starts at ~64s)" DarkYellow
    ffmpeg -copyts -i $ReferenceTS -map 0:v -map 0:a -c copy -y $OutputFile 2>&1 | ForEach-Object {
        if ($_ -match "time=(\d+:\d+:\d+\.\d+)") {
            Write-Progress -Activity "Remuxing..." -Status $matches[1]
        }
    }
} else {
    Write-Step "Re-zeroing PTS to start at 0s" DarkYellow
    $v_start = ffprobe -v quiet -print_format csv -select_streams v -show_entries "packet=pts_time" $ReferenceTS 2>$null |
        Select-Object -Skip 1 | Select-Object -First 1
    $offset = -([double]($v_start -split ',')[1])
    Write-Step "Applying PTS offset: $offset s" DarkYellow
    ffmpeg -copyts -i $ReferenceTS -map 0:v -map 0:a -c copy -output_ts_offset $offset -y $OutputFile 2>&1 | ForEach-Object {
        if ($_ -match "time=(\d+:\d+:\d+\.\d+)") {
            Write-Progress -Activity "Remuxing... (this handles PTS discontinuities automatically)" -Status $matches[1]
        }
    }
}
Write-Progress -Activity "Remuxing..." -Completed

# Step 3: Verify
if (Test-Path $OutputFile) {
    Write-Step "Verifying output..." Yellow
    $out_info = ffprobe -v quiet -print_format json -show_format -show_streams $OutputFile 2>$null | ConvertFrom-Json
    $out_v = $out_info.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
    $out_a = $out_info.streams | Where-Object { $_.codec_type -eq "audio" } | Select-Object -First 1

    if ($out_v -and $out_a) {
        $v = [double]$out_v.duration
        $a = [double]$out_a.duration
        $d = [math]::Abs($v - $a)

        Write-Step ("Output video duration: " + [math]::Round($v, 1) + "s") Cyan
        Write-Step ("Output audio duration: " + [math]::Round($a, 1) + "s") Cyan
        Write-Step ("A/V diff: " + [math]::Round($d, 3) + "s") $(if ($d -gt 1) {"Red"} elseif ($d -gt 0.5) {"Yellow"} else {"Green"})
        Write-Step ("Container duration: " + [math]::Round([double]$out_info.format.duration, 1) + "s") Cyan

        if ($d -lt 1) {
            Write-Step "✓ A/V SYNC OK" Green
        } else {
            Write-Step "⚠ A/V duration mismatch persists (>1s)" Yellow
        }
    }

    $size = (Get-Item $OutputFile).Length / 1GB
    Write-Step ("Output: $OutputFile (" + [math]::Round($size, 2) + " GB)") Green
    Write-Step "DONE" Green
} else {
    Write-Host "ERROR: Output file was not created" -ForegroundColor Red
    exit 1
}
