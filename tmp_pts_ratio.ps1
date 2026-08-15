$f = "E:\Video5\2026.6.11-3第五.mp4"
$vpts = ffprobe -v quiet -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 $f 2>$null
$apts = ffprobe -v quiet -select_streams a:0 -show_entries packet=pts_time -of csv=p=0 $f 2>$null
Write-Host ("video packets: {0}, audio packets: {1}" -f $vpts.Count, $apts.Count)
Write-Host ("video pts range: {0:N2} -> {1:N2}" -f [double]$vpts[0], [double]$vpts[-1])
Write-Host ("audio pts range: {0:N2} -> {1:N2}" -f [double]$apts[0], [double]$apts[-1])

# Audio-aligned windows: for each 60s audio window, find video PTS span and compute ratio
$winStart = 0
$audioEnd = [double]$apts[-1]
$winSec = 60
$ai = 0
$vi = 0
$nA = $apts.Count
$nV = $vpts.Count

Write-Host ""
Write-Host "  AudioWin   VideoPTSpan  Ratio  VideoFPS   AudioFrames"
$t = 0.0
while ($t -lt $audioEnd -and $ai -lt $nA) {
    $t2 = $t + $winSec
    while ($ai -lt $nA -and [double]$apts[$ai] -lt $t2) { $ai++ }
    $aStart = [double]$apts[$ai-1]
    # find video pts nearest to audio window start/end
    $vWinFrames = 0
    $vFirst = $null; $vLast = $null
    $saveVi = $vi
    while ($vi -lt $nV -and [double]$vpts[$vi] -lt $t2) {
        if ($null -eq $vFirst) { $vFirst = [double]$vpts[$vi] }
        $vLast = [double]$vpts[$vi]
        $vWinFrames++
        $vi++
    }
    if ($null -ne $vFirst -and $null -ne $vLast -and ($vLast - $vFirst) -gt 0) {
        $ratio = $winSec / ($vLast - $vFirst)
        $vFps = $vWinFrames / ($vLast - $vFirst)
        Write-Host ("  {0,8:N0}   {1,10:N1}s   {2,5:N2}x  {3,7:N1}    {4}" -f $t, ($vLast - $vFirst), $ratio, $vFps, $ai)
    }
    $t = $t2
}