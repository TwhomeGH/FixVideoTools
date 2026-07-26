import subprocess, wave, numpy as np

# ===== 1. Confirm audio cut point =====
print("=== Step 1: Audio cut point ===")
subprocess.run(['ffmpeg', '-y', '-i', 'E:/Video5/2026.6.11-3第五.mp4',
    '-ss', '6160', '-map', '0:a:0', '-t', '15', '-acodec', 'pcm_s16le', '-ar', '44100', '-ac', '1',
    '-f', 'wav', 'F:\\FixVideoTools\\orig_audio_snippet.wav'],
    capture_output=True)

subprocess.run(['ffmpeg', '-y', '-i', 'E:/Video5/2026.6.11-3第五_part2_fixed_v4.mp4',
    '-map', '0:a:0', '-t', '3', '-acodec', 'pcm_s16le', '-ar', '44100', '-ac', '1',
    '-f', 'wav', 'F:\\FixVideoTools\\v4_audio_start.wav'],
    capture_output=True)

with wave.open('F:\\FixVideoTools\\v4_audio_start.wav', 'rb') as w:
    v4_ref = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)

with wave.open('F:\\FixVideoTools\\orig_audio_snippet.wav', 'rb') as w:
    orig_snippet = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)

# Cross-correlate using first 0.5s of v4 (cleaner match)
v4_short = v4_ref[:22050]
corr = np.correlate(orig_snippet, v4_short, mode='valid')
peak = np.argmax(corr)
audio_offset_in_snippet = peak / 44100
audio_cut_point = 6160 + audio_offset_in_snippet
print(f"Audio cut point: original audio time = {audio_cut_point:.4f}s")
print(f"  Which is {audio_cut_point/3600:.0f}h{(audio_cut_point%3600)/60:.0f}m{audio_cut_point%60:.2f}s")

# ===== 2. Find video cut point by comparing frame content =====
print("\n=== Step 2: Video cut point ===")

# Export sample frames from v4 at times 0, 1, 2, 3, 5 seconds
for t in [0, 1, 2, 3, 5]:
    ss = str(t)
    subprocess.run(['ffmpeg', '-y', '-ss', ss, '-i', 'E:/Video5/2026.6.11-3第五_part2_fixed_v4.mp4',
        '-map', '0:v:0', '-vframes', '1', '-vf', 'scale=160:90',
        f'F:\\FixVideoTools\\v4_t{t}.png'],
        capture_output=True)

# Now search in original at various PTS positions
# Stride = 2 seconds to keep search fast
print("Scanning original video at 2s PTS intervals...")
results = []
for pts in range(4500, 6846, 2):
    subprocess.run(['ffmpeg', '-y', '-ss', str(pts), '-i', 'E:/Video5/2026.6.11-3第五.mp4',
        '-map', '0:v:0', '-vframes', '1', '-vf', 'scale=160:90',
        'F:\\FixVideoTools\\orig_frame.png'],
        capture_output=True)
    
    # Compare with v4_t0 using PSNR
    r = subprocess.run(['ffmpeg', '-i', 'F:\\FixVideoTools\\v4_t0.png',
        '-i', 'F:\\FixVideoTools\\orig_frame.png',
        '-filter_complex', '[0][1]psnr',
        '-f', 'null', '-'],
        capture_output=True)
    stderr = r.stderr.decode('utf-8', errors='replace')
    psnr = None
    for l in stderr.split('\n'):
        if 'average:' in l:
            try:
                psnr = float(l.split('average:')[1].split()[0])
            except:
                pass
    if psnr and psnr > 20:
        results.append((pts, psnr))
        print(f"  PTS {pts}s: PSNR = {psnr:.2f} dB")

if results:
    best = max(results, key=lambda x: x[1])
    print(f"\nBest match: original PTS = {best[0]}s with PSNR {best[1]:.2f}")
    print(f"Corresponding audio time = {best[0] * 1.293:.1f}s (estimated)")
else:
    print("No good PSNR match found (re-encoding changes pixels)")
    print("Trying alternative approach: downscaled SSIM-like comparison...")
