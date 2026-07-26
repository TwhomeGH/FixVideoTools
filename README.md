# FixVideoTools 視頻修復工具

此項目是因為長期測試下難免會出現把回放搞砸的情況，而產生的修復子工具以及部分解決方式，使用 Twitch TS 檔做搶救工具方式。

[松鼠推流 ReplyKIT](https://github.com/TwhomeGH/ReplyKit)

---

## 工具列表

### `analyze-pts.ps1`
PTS 診斷工具。分析影片的 PTS 壓縮情形、A/V 時長差異，提供修復建議。

```
.\analyze-pts.ps1 -InputFile <路徑> [-ReferenceFile <路徑>] [-ReportOnly]
```

| 參數 | 說明 |
|------|------|
| `-InputFile` | 目標檔案（必填） |
| `-ReferenceFile` | 參考檔（比對用） |
| `-ReportOnly` | 僅輸出報告，不產生輸出檔 |

---

### `analyze-pts-deltas.ps1`
PTS Delta 分析器。詳細統計影片每幀間隔（P10/P25/P50/P75/P90）、壓縮率趨勢、A/V 同步檢查表。

```
.\analyze-pts-deltas.ps1 -InputFile <路徑> [-MaxSamples <數量>] [-ShowAllDeltas]
```

| 參數 | 說明 |
|------|------|
| `-InputFile` | 目標檔案（必填） |
| `-MaxSamples` | 最大採樣數（0 = 全部） |
| `-ShowAllDeltas` | 顯示所有 delta 值 |

---

### `fix-pts-spike.ps1`
PTS Spike 修復工具。偵測 PTS 異常跳變點（如 fps 從 60 突然跳到 200+），將影片在跳變點拆成 Part1 + Part2，修復 Part2 的 PTS，可選合併或分別輸出。

```
.\fix-pts-spike.ps1 -InputFile <路徑> [-SplitTime HH:MM:SS] [-OutputFile <路徑>] [-OutputDir <目錄>] [-NoConcat] [-Force] [-KeepTemp] [-SkipVerify]
```

| 參數 | 說明 |
|------|------|
| `-InputFile` | 原始檔案（必填） |
| `-SplitTime` | 手動指定分割點（`HH:MM:SS` 或秒數），省略則自動偵測 |
| `-OutputFile` | 輸出完整合併檔路徑（預設：同目錄 `{檔名}_fixed.mp4`） |
| `-OutputDir` | 輸出目錄（預設：與輸入同目錄） |
| `-NoConcat` | 不自動合併，分別輸出 `_part1.mp4` + `_part2_fixed.mp4` |
| `-Force` | 覆蓋已存在的輸出檔 |
| `-KeepTemp` | 保留暫存檔（位於系統暫存目錄） |
| `-SkipVerify` | 跳過驗證步驟 |

**運作流程：**
1. PHASE 1: 切 Part1（0 ~ SplitTime）
2. PHASE 2: 切 Part2（SplitTime ~ 結尾）
3. PHASE 3: 修復 Part2 PTS（偵測壓縮比，自動選擇 setts 拉伸或 CFR 重建）
4. PHASE 4: 合併 Part1 + Part2_fixed，或分別輸出（`-NoConcat`）
5. PHASE 5: 驗證 A/V 同步（可跳過）

**範例：**
```powershell
# 自動偵測跳變點，合併輸出
.\fix-pts-spike.ps1 "input.mp4"

# 手動指定分割點，分別輸出
.\fix-pts-spike.ps1 "input.mp4" -SplitTime 01:43:20 -NoConcat -OutputDir ".\output"
```

---

### `hybrid-cut.ps1`
精確切割工具。分別以相同原始 PTS 切割 video 與 audio 再合併，確保 A/V 起始點完全一致。

```
.\hybrid-cut.ps1 -InputFile <路徑> -OutputFile <路徑> -StartTime <時間> [-EndTime <時間> | -Duration <秒數>] [-Force] [-KeepTemp]
```

| 參數 | 說明 |
|------|------|
| `-InputFile` | 原始檔案（必填） |
| `-OutputFile` | 輸出檔案（必填） |
| `-StartTime` | 起始時間（`HH:MM:SS` 或秒數） |
| `-EndTime` | 結束時間 |
| `-Duration` | 持續秒數（與 EndTime 二選一） |
| `-Force` | 覆蓋已存在的輸出 |
| `-KeepTemp` | 保留暫存檔 |

**範例：**
```powershell
.\hybrid-cut.ps1 -InputFile "input.mp4" -OutputFile "cut.mp4" -StartTime 01:30:00 -Duration 60
```

---

### `fix-pts.ps1`
PTS 修復工具。將 TS（HLS/mpegts）檔 remux 為 MP4，修正 Twitch VOD 下載造成的 PTS 壓縮問題。

```
.\fix-pts.ps1 -ReferenceTS <.ts路徑> [-OutputFile <路徑>] [-Force] [-KeepOffset]
```

| 參數 | 說明 |
|------|------|
| `-ReferenceTS` | TS 原始檔（必填） |
| `-OutputFile` | 輸出 MP4 路徑 |
| `-Force` | 覆蓋已存在的輸出 |
| `-KeepOffset` | 保留原始 PTS offset（預設歸零） |

---

### `fix-fps.ps1`
FPS 修復工具。偵測並修復三種問題：r_frame_rate 損壞、PTS 壓縮、PTS 混亂。

```
.\fix-fps.ps1 -InputFile <路徑> [-OutputFile <路徑>] [-Strategy auto|cfr|genpts|mkv] [-Duration <秒數>] [-Force] [-KeepTemp]
```

| 參數 | 說明 |
|------|------|
| `-InputFile` | 目標檔案（必填） |
| `-OutputFile` | 輸出檔案 |
| `-Strategy` | 修復策略：`auto`（自動偵測）、`cfr`（CFR 重建）、`genpts`（genpts flag）、`mkv`（MKV 中繼） |
| `-Duration` | 目標影片時長（PTS 拉伸用） |
| `-Force` | 覆蓋已存在的輸出 |
| `-KeepTemp` | 保留暫存檔 |

---

### `align-av.ps1`
A/V 對齊工具。測量 video 與 audio 的起始 PTS 差值，自動或手動修正偏移。

```
.\align-av.ps1 -InputFile <路徑> -OutputFile <路徑> [-ManualOffset <秒數>] [-DelayVideo] [-CheckOnly] [-Force]
```

| 參數 | 說明 |
|------|------|
| `-InputFile` | 目標檔案（必填） |
| `-OutputFile` | 輸出檔案（必填） |
| `-ManualOffset` | 手動指定偏移量（秒） |
| `-DelayVideo` | 延遲 video 而非 audio |
| `-CheckOnly` | 僅檢查，不輸出 |
| `-Force` | 覆蓋已存在的輸出 |

---

### `transcode-av1.ps1`
AV1 轉碼工具。將 TS 或 MP4 轉碼為 SVT-AV1 壓縮的 MP4，自動偵測 r_frame_rate 損壞並修正。

```
.\transcode-av1.ps1 -InputFile <路徑> [-OutputFile <路徑>] [-OutputDir <目錄>] [-Preset fast|medium|slow|veryslow] [-CRF <數值>] [-Force] [-DryRun] [-NoCleanup]
```

| 參數 | 說明 |
|------|------|
| `-InputFile` | 原始檔案（必填） |
| `-OutputFile` | 輸出檔案路徑 |
| `-OutputDir` | 輸出目錄（預設：與輸入同目錄） |
| `-Preset` | SVT-AV1 預設：`fast`(10)、`medium`(8)、`slow`(6)、`veryslow`(4) |
| `-CRF` | 品質參數（30=檔案級, 45=推薦, 50=最小） |
| `-Force` | 覆蓋已存在的輸出 |
| `-DryRun` | 僅顯示指令不執行 |
| `-NoCleanup` | 不清除暫存檔 |

**注意：** 若輸入檔的 `r_frame_rate` 與實際 fps 差距 >1，工具會自動補上 `-r` 參數以正確幀率編碼，避免丟幀。

**範例：**
```powershell
.\transcode-av1.ps1 "input.mp4" -CRF 45 -Preset slow -OutputDir ".\av1_output"
```

---

### `find_cut_points.py`（Python 3）
切割點搜尋工具。透過音訊 cross-correlation 與影片 PSNR 比對，找出兩個影片間的對齊時間點。

```
python find_cut_points.py
```

**依賴：** `numpy`、`ffmpeg`/`ffprobe`（需在 PATH 中）

**注意：** 此腳本目前為 standalone 工具，需手動修改內部路徑。

---

## 注意事項

- 所有工具需安裝 `ffmpeg`/`ffprobe` 並加入 PATH
- 從 [gyan.dev](https://www.gyan.dev/ffmpeg/builds/) 下載完整版（含 libsvtav1）
- AV1 轉碼需 ffmpeg 編譯包含 `libsvtav1`（gyan.dev 的完整版包含）
- 輸出檔預設與輸入同目錄，可使用 `-OutputDir` 指定
