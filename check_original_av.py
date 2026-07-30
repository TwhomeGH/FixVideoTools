import subprocess, json, sys

filepath = sys.argv[1] if len(sys.argv) > 1 else "E:/Video5/2026.6.10-1第五.mp4"

# Get video PTS at frame boundaries (first+last frames of each second)
# Use the PTS data we already have from our VFR analysis
cmd_vpts = [
    'ffprobe', '-v', 'quiet',
    '-select_streams', 'v:0',
    '-show_entries', 'packet=pts_time',
    '-of', 'csv=p=0',
    filepath
]
r = subprocess.run(cmd_vpts, capture_output=True, text=True, timeout=180)
v_pts = []
for line in r.stdout.strip().split('\n'):
    try:
        v_pts.append(float(line.split(',')[0]))
    except:
        pass
print(f'Video frames: {len(v_pts)}')
print(f'Video PTS range: {v_pts[0]:.3f}s to {v_pts[-1]:.3f}s')

# Get audio PTS
cmd_apts = [
    'ffprobe', '-v', 'quiet',
    '-select_streams', 'a:0',
    '-show_entries', 'packet=pts_time',
    '-of', 'csv=p=0',
    filepath
]
r2 = subprocess.run(cmd_apts, capture_output=True, text=True, timeout=180)
a_pts = []
for line in r2.stdout.strip().split('\n'):
    try:
        a_pts.append(float(line.split(',')[0]))
    except:
        pass
print(f'Audio packets: {len(a_pts)}')
print(f'Audio PTS range: {a_pts[0]:.3f}s to {a_pts[-1]:.3f}s')

# Check A/V sync at multiple points
# Sample every ~5% through the file
print('\nA/V sync check at checkpoints:')
print(f'{"Point":>8} {"Video PTS":>12} {"Audio PTS":>12} {"Diff":>10} {"Cum Err":>10}')
print('-' * 55)

# Calculate what video PTS should be if it were perfectly uniform at 58.58fps
uniform_v_pts = [i / 58.581241 for i in range(len(v_pts))]

frame_points = [int(len(v_pts) * p / 20) for p in range(21)]  # every 5%
for fp in frame_points:
    if fp >= len(v_pts):
        break
    vp = v_pts[fp]
    up = uniform_v_pts[fp]
    # Find closest audio PTS
    apts_idx = int(fp * len(a_pts) / len(v_pts))
    if apts_idx >= len(a_pts):
        apts_idx = len(a_pts) - 1
    ap = a_pts[apts_idx]
    
    # At this frame, what's the diff between video PTS and audio PTS?
    diff = vp - ap
    # What's the diff if we used uniform PTS?
    uniform_diff = up - ap
    
    pct = fp * 100 // len(v_pts)
    print(f'  {pct:>3}%  {vp:>10.3f}s  {ap:>10.3f}s  {diff:>+8.3f}s  {uniform_diff:>+8.3f}s')

# Check the low-fps regions specifically
print('\nLow-FPS region analysis:')
# Beginning section (~0-200s)
for frame in [0, 1000, 2000, 3000, 4000, 5000, 10000]:
    if frame < len(v_pts):
        vp = v_pts[frame]
        delta = vp - v_pts[frame-1] if frame > 0 else v_pts[frame+1] - v_pts[frame]
        fps = 1.0 / delta if delta > 0 else 0
        # Map to audio
        apts_idx = int(frame * len(a_pts) / len(v_pts))
        if apts_idx < len(a_pts):
            ap = a_pts[apts_idx]
            print(f'  Frame {frame:6d}  PTS={vp:>8.3f}s  delta={delta*1000:.1f}ms  fps={fps:.1f}  A_PTS={ap:.3f}s  diff={vp-ap:+.3f}s')

# End section
print('\n  End section:')
for frame in [len(v_pts)-1, len(v_pts)-1000, len(v_pts)-5000, len(v_pts)-10000]:
    if frame >= 0:
        vp = v_pts[frame]
        delta = vp - v_pts[frame-1] if frame > 0 else 0
        fps = 1.0 / delta if delta > 0 else 0
        apts_idx = int(frame * len(a_pts) / len(v_pts))
        if apts_idx < len(a_pts):
            ap = a_pts[apts_idx]
            print(f'  Frame {frame:6d}  PTS={vp:>8.3f}s  delta={delta*1000:.1f}ms  fps={fps:.1f}  A_PTS={ap:.3f}s  diff={vp-ap:+.3f}s')
