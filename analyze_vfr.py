import subprocess, json, sys

filepath = sys.argv[1] if len(sys.argv) > 1 else "E:/Video5/2026.6.10-1第五.mp4"

# Get stream info
cmd = [
    'ffprobe', '-v', 'quiet',
    '-print_format', 'json',
    '-select_streams', 'v:0',
    '-show_entries', 'stream=nb_frames,duration,time_base,r_frame_rate,avg_frame_rate',
    filepath
]
r = subprocess.run(cmd, capture_output=True, text=True)
info = json.loads(r.stdout)
s = info['streams'][0]
print('Video stream info:')
print(f'  nb_frames={s.get("nb_frames")}')
print(f'  duration={s.get("duration")}s')
print(f'  time_base={s.get("time_base")}')
print(f'  r_frame_rate={s.get("r_frame_rate")}')
print(f'  avg_frame_rate={s.get("avg_frame_rate")}')

# Get all PTS
cmd2 = [
    'ffprobe', '-v', 'quiet',
    '-select_streams', 'v:0',
    '-show_entries', 'packet=pts_time',
    '-of', 'csv=p=0',
    filepath
]
r2 = subprocess.run(cmd2, capture_output=True, text=True, timeout=180)
lines = r2.stdout.strip().split('\n')
total = len(lines)
print(f'Total packets: {total}')

# Analyze consecutive deltas from a large sample
# Take first N and last N frames from each window for detailed VFR pattern
sample_count = 100000
step = max(1, total // sample_count)

deltas = []
prev_pts = None
for i in range(0, total, step):
    parts = lines[i].split(',')
    if len(parts) >= 1:
        try:
            pts = float(parts[0])
            if prev_pts is not None:
                delta = pts - prev_pts
                if 0 < delta < 1:
                    deltas.append(delta)
            prev_pts = pts
        except ValueError:
            pass

deltas.sort()
n = len(deltas)
print(f'\nConsecutive frame deltas (step={step}): {n}')
if n > 0:
    print(f'  Min: {deltas[0]*1000:.4f}ms')
    print(f'  P1:  {deltas[max(0,n//100-1)]*1000:.4f}ms')
    print(f'  P5:  {deltas[max(0,n//20-1)]*1000:.4f}ms')
    print(f'  P10: {deltas[max(0,n//10-1)]*1000:.4f}ms')
    print(f'  P25: {deltas[max(0,n//4-1)]*1000:.4f}ms')
    print(f'  P50: {deltas[n//2]*1000:.4f}ms')
    print(f'  P75: {deltas[min(n-1,3*n//4)]*1000:.4f}ms')
    print(f'  P90: {deltas[min(n-1,9*n//10)]*1000:.4f}ms')
    print(f'  P99: {deltas[min(n-1,99*n//100)]*1000:.4f}ms')
    print(f'  Max: {deltas[-1]*1000:.4f}ms')
    print(f'  Mean: {sum(deltas)/n*1000:.4f}ms')
    
    # Count delta ranges
    sub5 = sum(1 for d in deltas if d < 0.005)
    sub16 = sum(1 for d in deltas if 0.005 <= d < 1/60)
    eq16 = sum(1 for d in deltas if 1/60 <= d < 1/50)
    eq33 = sum(1 for d in deltas if 1/50 <= d < 1/24)
    over = sum(1 for d in deltas if d >= 1/24)
    print(f'\nDelta distribution:')
    print(f'  <5ms (PTS corruption): {sub5} ({sub5/n*100:.1f}%)')
    print(f'  5-16.7ms (>60fps): {sub16} ({sub16/n*100:.1f}%)')
    print(f'  16.7-20ms (50-60fps): {eq16} ({eq16/n*100:.1f}%)')
    print(f'  20-41.7ms (24-50fps): {eq33} ({eq33/n*100:.1f}%)')
    print(f'  >=41.7ms (<24fps): {over} ({over/n*100:.1f}%)')

# Per-window FPS analysis (consecutive frames)
window_size = 2000  # frames per window
step_frames = 500   # sliding window step

print(f'\nPer-window FPS analysis (window={window_size} frames, step={step_frames}):')
fps_windows = []
for start in range(0, total - window_size, step_frames):
    try:
        pts_start = float(lines[start].split(',')[0])
        pts_end = float(lines[start + window_size].split(',')[0])
        dur = pts_end - pts_start
        if dur > 0:
            fps = window_size / dur
            fps_windows.append((start, pts_start, fps))
    except (ValueError, IndexError):
        pass

if fps_windows:
    fps_vals = [f for _, _, f in fps_windows]
    ts_vals = [t for _, t, _ in fps_windows]
    print(f'  Windows: {len(fps_windows)}')
    print(f'  Min FPS: {min(fps_vals):.2f}')
    print(f'  Max FPS: {max(fps_vals):.2f}')
    print(f'  Mean FPS: {sum(fps_vals)/len(fps_vals):.2f}')
    std = (sum((f-sum(fps_vals)/len(fps_vals))**2 for f in fps_vals)/len(fps_vals))**0.5
    print(f'  Std FPS: {std:.2f}')
    
    # Plot FPS over time (text histogram)
    print(f'\n  FPS timeline (0s to 13032s):')
    bucket_count = 65
    bucket_size = max(1, len(fps_windows) // bucket_count)
    for i in range(0, len(fps_windows), bucket_size):
        bucket = fps_windows[i:min(i+bucket_size, len(fps_windows))]
        avg_fps = sum(f for _, _, f in bucket) / len(bucket)
        t = bucket[0][1]
        bar_len = int(avg_fps / 3)  # scale: 60fps = 20 chars
        print(f'  {t:6.0f}s |{"#" * bar_len} {avg_fps:.1f}fps')
    
    # Find transitions (FPS changes > 20%)
    print(f'\n  Significant FPS transitions (>20% change):')
    transitions = []
    for i in range(1, len(fps_windows)):
        f_prev = fps_windows[i-1][2]
        f_curr = fps_windows[i][2]
        ratio = f_curr / f_prev if f_prev > 0 else 1
        if ratio > 1.2 or ratio < 0.8:
            t_sec = fps_windows[i][1]
            transitions.append((i, t_sec, f_prev, f_curr, ratio))
            print(f'    ~{t_sec:.0f}s: {f_prev:.1f} -> {f_curr:.1f} fps ({ratio:.3f}x)')
    
    if not transitions:
        print(f'    (none - relatively stable)')
    
    # Analyze: is this PTS compression or genuine VFR?
    # PTS compression: consistent low fps in early windows, jumping to ~60fps later
    # Genuine VFR: random variation frame-to-frame
    if std < 3:
        print(f'\n  Conclusion: Relatively stable FPS (std={std:.1f}) - likely CFR source')
    elif any(r > 1.5 for _, _, _, _, r in transitions[:3]):
        print(f'\n  Conclusion: FPS jumps from low to high - LIKELY PTS COMPRESSION in early part')
    else:
        print(f'\n  Conclusion: VFR source with gradual variation')
