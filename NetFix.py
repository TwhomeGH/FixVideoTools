
import subprocess
import os
import sys
import json

from pathlib import Path

import dotenv
dotenv.load_dotenv(dotenv.find_dotenv())


import requests

bark_url = os.getenv("BARK_URL")

isBark = True

print("Debug BarkURL:", bark_url[:-6] + "000000")

def send_bark_post(title: str, body: str):
    global bark_url

    if not isBark:
        print("⚠️ Bark 推送功能未啟用，跳過推送")
        return

    if bark_url == "":
        print("⚠️ Bark URL 未設定，跳過推送")
        return

    payload = {
        "title": title,
        "body": body,
        "group": "SRT"
    }
    try:
        res = requests.post(bark_url, json=payload)
        if res.status_code == 200:
            print("✅ Bark 推送成功")
        else:
            print(f"❌ 推送失敗，狀態碼: {res.status_code}")
    except Exception as e:
        print(f"⚠️ 發送失敗: {e}")


def get_real_fps(video_path):
    cmd = [
        "ffprobe", "-v", "quiet",
        "-print_format", "json",
        "-show_streams", "-show_format",
        video_path
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, errors='replace', check=True)
        info = json.loads(result.stdout)
        for s in info.get("streams", []):
            if s.get("codec_type") == "video":
                frames = s.get("nb_frames")
                duration = s.get("duration")
                if frames and duration:
                    return float(frames) / float(duration)
    except Exception as e:
        print(f"⚠️ FPS 偵測失敗: {e}")
    return None

def process_video(input_path, output_dir="output"):
    if not os.path.exists(output_dir):
        os.makedirs(output_dir)

    base_name = os.path.splitext(os.path.basename(input_path))[0]
    
    real_fps = get_real_fps(input_path)
    if real_fps:
        fps_str = f"{real_fps:.4f}"
        print(f"真實 FPS: {fps_str}")
    else:
        fps_str = "60"
        print("⚠️ 無法偵測 FPS，使用預設 60")

    final_file = os.path.join(output_dir, f"NEV{base_name}.mp4")

    # # 1️⃣ CPU 軟編碼整理影片（VFR -> CFR，yuv420p）
    # cmd_fix = [
    #     "ffmpeg",
    #     "-y",
    #     "-i", input_path,
    #     "-c:v", "libx264",
    #     "-preset", "ultrafast",
    #     "-crf", "30",
    #     "-vf", "fps=60,format=yuv420p",
    #     "-c:a", "aac",
    #     "-q:a",  "4",
    #     tmp_file
    # ]
    # print(f"整理影片: {' '.join(cmd_fix)}")
    # subprocess.run(cmd_fix, check=True)

    # 2️⃣ NVENC 硬編碼
    cmd_nvenc = [
        "ffmpeg",
        "-y",
        "-i", input_path,
        "-c:v", "libsvtav1",
        "-svtav1-params" ,"tune=2:scd=1",
        "-preset", "10",
        "-crf","40",
        "-pix_fmt","yuv420p10le",
        "-r", fps_str,
        "-c:a", "copy",
        "-movflags", "+faststart",
        final_file
    ]
    print(f"NVENC 編碼: {' '.join(cmd_nvenc)}")
    
    try:
        subprocess.run(cmd_nvenc, check=True, text=True, errors='replace')
    except subprocess.CalledProcessError as e:
        print(f"⚠️ NVENC 失敗，改用 CPU 軟編碼救場 {e}")

        cmd_cpu = [
            "ffmpeg",
            "-y",
            "-i", input_path,
            "-c:v", "libx264",
            "-preset", "veryfast",
            "-crf", "28",
            "-r", fps_str,
            "-pix_fmt", "yuv420p",
            "-c:a", "copy",
            "-movflags", "+faststart",
            final_file
        ]

        print(f"CPU 編碼: {' '.join(cmd_cpu)}")
        subprocess.run(cmd_cpu, check=True, text=True, errors='replace')
        

    
    print(f"完成: {final_file}")

    send_bark_post("影片處理完成", f"影片已輸出到：{final_file}")
    return final_file



ListV=[

]

if __name__ == "__main__":

    useBark = input("是否停用 Bark 推送？(y/n)： ").strip().lower()
    if useBark == 'y':
        print("Bark 推送功能已停用。")
        isBark = False
    else:
        isBark = True
        

    video_extensions = ('.mp4', '.mkv', '.avi', '.flv', '.mov')
    print(f"當前支援格式: {' / '.join(video_extensions)}")
    choice = input(f"請選擇模式：(1) 手動添加檔案 (2) 指定資料夾下所有 {video_extensions[0]} 檔案： ").strip()

    if choice == '2':
        folder_path = input("請輸入資料夾路徑： ").strip().strip('"').strip("'")
        folder_path = os.path.normpath(folder_path)
        
        if os.path.isdir(folder_path):
            # 取得該資料夾下所有檔案
            all_files = os.listdir(folder_path)
            
            # 定義你想要的影片副檔名
            
            # 過濾條件：是 .mp4 檔、不是 NEV 開頭、且是檔案而非資料夾
            ts_files = [
                f for f in all_files 
                if f.lower().endswith(video_extensions) 
                and not f.startswith('NEV')
                and os.path.isfile(os.path.join(folder_path, f))
            ]
            
            # 排序（確保 0.ts 在 1.ts 前面）
            import re
            ts_files.sort(key=lambda f: int(re.sub(r'\D', '', f)) if re.sub(r'\D', '', f) else 0)
            
            for f in ts_files:
                full_path = os.path.join(folder_path, f)
                ListV.append(full_path)
                print(f"已自動添加： {f}")
        else:
            print("資料夾路徑無效。")

    else:
    
        while True:
            input_video = input("請輸入要處理的影片檔案路徑： ").strip()

            # 移除引號
            input_video = input_video.strip('"').strip("'")

            if not input_video.lower().endswith(video_extensions):
                print(f"檔案格式不支援，請選擇以下格式的影片： {', '.join(video_extensions)}")
                continue
            
            # 修正 Windows 的反斜線
            input_video = os.path.normpath(input_video)

            if not os.path.exists(input_video):
                print(f"檔案不存在，請重新輸入。{input_video}")
                continue

            ListV.append(input_video)
            print(f"已添加影片： {input_video}")
            more = input("是否要繼續添加影片？(y/n)： ").strip().lower()
            if more != 'y':
                break


    for input_video in ListV:
        OutDir=os.path.dirname(input_video)
        print(f"處理影片： {input_video}")
        print(f"輸出目錄： {OutDir}")
        process_video(input_video,output_dir=OutDir)
        print("========================================")
    
    print("所有影片處理完成！")
    send_bark_post("所有影片處理完成", "所有影片已成功處理並輸出！")
