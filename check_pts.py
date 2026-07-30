import subprocess, json, sys

f = sys.argv[1] if len(sys.argv) > 1 else "E:/Video5/2026.6.10-1第五_fpsfixed.mp4"
r = subprocess.run([
    'ffprobe', '-v', 'quiet', '-print_format', 'json',
    '-select_streams', 'v:0',
    '-show_entries', 'stream=nb_frames,duration,time_base,r_frame_rate,avg_frame_rate',
    f
], capture_output=True, text=True)
s = json.loads(r.stdout)['streams'][0]
print(f'r_frame_rate={s["r_frame_rate"]}')
print(f'avg_frame_rate={s["avg_frame_rate"]}')
print(f'Duration={s["duration"]}s  time_base={s["time_base"]}')
print(f'Frames={s["nb_frames"]}')

r2 = subprocess.run([
    'ffprobe', '-v', 'quiet', '-select_streams', 'v:0',
    '-show_entries', 'packet=pts_time',
    '-of', 'csv=p=0', f
], capture_output=True, text=True, timeout=120)
lines = r2.stdout.strip().split('\n')
pts0, pts_last = float(lines[0]), float(lines[-1])
n = len(lines)
print(f'Actual PTS range: {pts0:.3f}s to {pts_last:.3f}s')
print(f'Actual avg fps: {n/pts_last:.4f}')

# Check PTS deltas
for i in [1000, 10001, 50001, 100001, 500001, 700001]:
    if i < n:
        pts = float(lines[i])
        d = pts - float(lines[i-1])
        print(f'  Frame {i}: PTS={pts:.3f}s  delta={d*1000:.3f}ms  fps={1/d:.1f}')
