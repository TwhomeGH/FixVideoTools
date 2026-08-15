$f = "E:\Video5\2026.6.11-3第五.mp4"
$vpts = ffprobe -v quiet -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 $f 2>$null
$n = $vpts.Count
Write-Host ("video packets: {0}" -f $n)

# Sample every 10000th frame (~167s real time at 60fps)
$step = 10000
Write-Host ""
Write-Host "  Frame#    VideoPTS   Expected(k/60)  Drift      LocalRatio"
$prevK = 0; $prevPts = 0.0; $prevExp = 0.0
for ($k = 0; $k -lt $n; $k += $step) {
    $pts = [double]$vpts[$k]
    $exp = $k / 60.0
    $drift = $pts - $exp
    $localRatio = if ($k -gt 0) { (($k - $prevK) / 60.0) / ($pts - $prevPts) } else { 1.0 }
    $mark = ""
    if ($k -gt 0 -and $localRatio -gt 1.3) { $mark = "  <<< compressed" }
    Write-Host ("  {0,8}  {1,9:N2}  {2,9:N2}  {3,9:N2}  {4,6:N2}x{5}" -f $k, $pts, $exp, $drift, $localRatio, $mark)
    $prevK = $k; $prevPts = $pts; $prevExp = $exp
}
Write-Host ""
Write-Host ("Final: videoPTS={0:N2}, expected={1:N2}, videoDur(ffprobe)={2}" -f [double]$vpts[-1], (($n-1)/60.0), 6846.407367)