$f = "E:\Video5\2026.6.11-3第五.mp4"
$vpts = ffprobe -v quiet -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 $f 2>$null
$n = $vpts.Count
$boundary = 363942
$step = 2000
Write-Host "== Part2 fine analysis (frame $boundary onwards) =="
Write-Host "  Frame#    VideoPTS   LocalRatio"
$prevK = $boundary
$prevPts = [double]$vpts[$boundary]
for ($k = $boundary + $step; $k -lt $n; $k += $step) {
    $pts = [double]$vpts[$k]
    $localRatio = (($k - $prevK) / 60.0) / ($pts - $prevPts)
    Write-Host ("  {0,8}  {1,9:N2}  {2,6:N2}x" -f $k, $pts, $localRatio)
    $prevK = $k; $prevPts = $pts
}
Write-Host ""
$last = $n - 1
$p2StartPts = [double]$vpts[$boundary]
$p2EndPts = [double]$vpts[$last]
$p2Frames = $n - $boundary
Write-Host ("Part2: frames={0}, videoPTS span={1:N2}s, expected-span(at59.2fps)={2:N2}s" -f $p2Frames, ($p2EndPts - $p2StartPts), ($p2Frames/59.2))
# audio duration mapping
Write-Host ""
Write-Host "Video total dur=6846.4s, audio total dur=8873.9s"
Write-Host ("Part2 boundary videoPTS={0:N2}s, audioAtBoundary≈{0:N2}s (part1 is 1:1 sync)" -f $p2StartPts)
Write-Host ("Part2 videoPTS span={0:N2}s, part2 audio duration={1:N2}s, RATIO={2:N3}" -f ($p2EndPts-$p2StartPts), (8873.9 - $p2StartPts), ((8873.9 - $p2StartPts)/($p2EndPts-$p2StartPts)))