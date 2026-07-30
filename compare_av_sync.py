import subprocess, json, sys

original = sys.argv[1] if len(sys.argv) > 1 else "E:/Video5/2026.6.10-1第五.mp4"
fixed = sys.argv[2] if len(sys.argv) > 2 else "E:/Video5/2026.6.10-1第五_fpsfixed.mp4"

def get_pts(filepath, stream_type):
    cmd = [
        'ffprobe', '-v', 'quiet',
        '-select_streams', f'{stream_type}:0',
        '-show_entries', 'packet=pts_time',
        '-of', 'csv=p=0',
        filepath
    ]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    pts = []
    for line in r.stdout.strip().split('\n'):
        try:
            pts.append(float(line.split(',')[0]))
        except:
            pass
    return pts

print('Reading original video PTS...')
orig_vpts = get_pts(original, 'v')
print(f'  {len(orig_vpts)} frames, range: {orig_vpts[0]:.3f}s to {orig_vpts[-1]:.3f}s')

print('Reading original audio PTS...')
orig_apts = get_pts(original, 'a')
print(f'  {len(orig_apts)} packets, range: {orig_apts[0]:.3f}s to {orig_apts[-1]:.3f}s')

print('Reading fixed video PTS...')
fix_vpts = get_pts(fixed, 'v')
print(f'  {len(fix_vpts)} frames, range: {fix_vpts[0]:.3f}s to {fix_vpts[-1]:.3f}s')

print('Reading fixed audio PTS...')
fix_apts = get_pts(fixed, 'a')
print(f'  {len(fix_apts)} packets, range: {fix_apts[0]:.3f}s to {fix_apts[-1]:.3f}s')

# Proper A/V sync check: find the audio PTS closest to each video PTS
# Check at evenly spaced video frames
print(f'\n{"Point":>8} {"Orig V_PTS":>10} {"Orig A_PTS":>10} {"Orig Δ":>8} {"Fix V_PTS":>10} {"Fix A_PTS":>10} {"Fix Δ":>8}')
print('-' * 70)

checkpoints = 20
for i in range(checkpoints + 1):
    fi = int(i * len(orig_vpts) / checkpoints)
    if fi >= len(orig_vpts):
        break
    
    ovp = orig_vpts[fi]
    fvp = fix_vpts[fi]
    
    # Find audio PTS closest to this video PTS time
    # For original: the audio is the same, so compare at the same real time
    o_ai = min(range(len(orig_apts)), key=lambda j: abs(orig_apts[j] - ovp))
    oap = orig_apts[o_ai]
    o_diff = ovp - oap
    
    # For fixed: find audio at the same real time
    f_ai = min(range(len(fix_apts)), key=lambda j: abs(fix_apts[j] - fvp)) if fix_apts else 0
    fap = fix_apts[f_ai]
    f_diff = fvp - fap
    
    pct = fi * 100 // len(orig_vpts)
    print(f'  {pct:>3}%  {ovp:>10.3f}s  {oap:>10.3f}s  {o_diff:>+8.3f}s  {fvp:>10.3f}s  {fap:>10.3f}s  {f_diff:>+8.3f}s')

# Also check frame-level deltas to show VFR pattern
print(f'\n\nFrame-level delta comparison (every 10000 frames):')
print(f'{"Frame":>8} {"Orig Delta":>12} {"Fix Delta":>12} {"Orig fps":>8} {"Fix fps":>8}')
print('-' * 52)
for fi in range(1000, len(orig_vpts), 10000):
    if fi >= len(orig_vpts):
        break
    od = orig_vpts[fi] - orig_vpts[fi-1]
    fd = fix_vpts[fi] - fix_vpts[fi-1]
    ofps = 1.0 / od if od > 0 else 0
    ffps = 1.0 / fd if fd > 0 else 0
    print(f'  {fi:>6}  {od*1000:>8.3f}ms  {fd*1000:>8.3f}ms  {ofps:>6.1f}  {ffps:>6.1f}')
