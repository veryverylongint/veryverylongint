# Companion-01 光栅裸眼 3D 显示器 — 交接文档

> 交接日期：2026-10-28
> 前序工作：从 3DGallery / OpenstageAI / Any2C1 / D20_Dice 四个程序逆向出 Companion-01 的完整光栅参数与交织算法，恢复丢失的设备参数文件，并实现了独立 WebGL 驱动。
> 本文档自包含：新 agent 无需翻阅历史对话即可接管。

---

## 1. 任务目标与现状

**用户诉求**：
1. Steam 指南（id=3386091122，"如何使用给 Companion 01 设计的 3d 壁纸"）订阅的壁纸下载在 `E:\Game\Steam\steamapps\workshop\content\431960\`，但指南要求的 `%APPDATA%\3DGallery\screen_params.json`（显示屏参数）已不存在 → 已恢复。
2. 实现独立 3D 驱动，不依赖 3DGallery / OpenstageAI → 已实现（`Companion01_Driver.html`，零依赖单文件 WebGL）。

**完成度**：软件层全部打通，算法经三路交叉验证。**尚未在物理屏幕上做过实测**（详见 §7）。

---

## 2. 硬件与软件环境

### 显示器（Companion-01，北京自由象限视觉科技有限公司）
| 项 | 值 |
|---|---|
| 设备尺寸 | 156 × 81.6 × 11.6 mm，裸机 ≈140.5 g |
| 屏幕 | 5.7" LCD，物理分辨率 **1440×2560**，视觉分辨率 540×960 |
| 景深 ≈6cm，最佳视角 ≈40°，观看距离 50–80cm | |
| 接口 | Type-C + HDMI |
| 设备标识 | deviceId `ZX1385`，deviceNumber `CP057010224340558`，hardwareSN `ffffffffb950bc5e5125abcd` |
| EDID label 白名单 | `TPV-2288-IN` 或 `OPC-0157-25`（OpenstageAI background.js 中的 `Ki` 常量；程序靠它识别副屏） |

### 本机环境
- Windows（win32），工作区 `C:\Users\Administrator\WorkBuddy\2026-10-28-21-28-30\`
- **pip 不可用**，numpy / PIL / cv2 均缺失 → Python 侧只能用标准库；图像处理须用纯 Python（BMP 手工解析可行）或 JS（驱动内置 canvas）
- 无 objdump / gdb / capstone → 逆向靠 Python 手工解析（PE/DWARF 均已证明可行）
- 相关进程：OpenstageAI 常驻（4 个进程），命名管道 `\\.\pipe\OpenstageAI_server_pipe` 存活

---

## 3. 核心数据（全部已验证）

### 3.1 本机实测光学参数（唯一真值来源）
```
lineNumber   = 19.6349      # 光栅周期，单位=子像素（×3 因为 RGB）
obliquity    = 0.103813     # 柱镜倾斜斜率（= 倾斜角的正切；atan → 5.93°）
deviation    = 3.8456375    # 相位偏移 x0
originDeviation = 3.8456375
```

派生量：
- 光栅周期（物理像素）`jiange` = 19.6349/3 = **6.5449667**（D20_Dice 的单位）
- 屏幕宽含 **220.0164** 个光栅周期（4320/19.6349）——整数性是单位解读正确的证据
- 倾斜角 = atan(0.103813) = **5.927°**（UV 空间斜率 = 0.103813×2560/1440 = 0.184556 → 10.46°）

### 3.2 参数的存储与传输链（为什么"找不到"）
```
%APPDATA%\OpenstageAI\deviceConfig.json   ← 现行存储，AES-256-CBC 加密（"Salted__" 前缀）
        │  解密密钥 3f5e1a2b4c6d7e8f9a0b1c2d3e4f5a6b（另一密钥 fesdgeyjtreuyfgbeytrjkcfhgcFGBSTDFJEYDWAZCXV 用于 pfconfig/bgconfig）
        ▼
OpenstageAI 常驻进程 ──命名管道──> \\.\pipe\OpenstageAI_server_pipe
        │  JSON 协议（见 §3.3）
        ├──> 3DGallery（Electron）     request_type: getDeivice / getLabelList
        ├──> Any2C1（原生 C++）        同上
        └──> D20_Dice（原生 C++）      同上，sscanf %lf ×4
```
- `screen_params.json` 是**旧版**路径（Steam 指南仍引用）：3DGallery 曾放在 `%APPDATA%\3DGallery\`，现版改管道+加密 → 文件消失的原因。
- 解密命令（devconf.bin 已导出在工作区）：
  `openssl enc -d -aes-256-cbc -md md5 -in devconf.bin -pass pass:3f5e1a2b4c6d7e8f9a0b1c2d3e4f5a6b`

### 3.3 管道协议（已实测，可直接复用）
请求体（`pipe_probe.py` 可运行）：
```json
{"id":"inbuilt","app_id":"1892190964274548738","app_key":"173996845597512",
 "app_secret":"Fb@-GD@s=Adte$Df2HV4","app_version":"1.0.0","request_type":"getDeivice"}
```
实测响应（315 字节）：
```json
{"app_id":"...","request_type":"getDeivice","plat_version":"2.4.0",
 "response_data":{"type":"device","config":{"deviceId":"ZX1385","lineNumber":19.6349,
 "obliquity":0.103813,"deviation":3.8456375,"originDeviation":3.8456375,
 "deviceNumber":"CP057010224340558"},"hardwareSN":"ffffffffb950bc5e5125abcd"}}
```
注意：app_secret 含 `$`，bash 内联 Python 会被 shell 展开吃掉——必须写成脚本文件执行（踩过的坑）。

### 3.4 光栅交织算法（三个实现，结构等价）

**共同几何**（8 列 × 5 行 = 40 视点 quilt 4320×4800，输出 1440×2560）：
```
pitch  = (W*3) / lineNumber        = 4320/19.6349 = 220.0164
slope  = obliquity * (H/W)         （UV 空间）；物理像素空间斜率 = obliquity
center = (deviation + 3) / lineNumber
```

**实现 A — 3DGallery（GLSL，ShaderPass，出处 `assets/index-DEzz72gb.js`）**：
```
x1 = (x + y*slope)*3 + bias        # bias = 0/1/2 → R/G/B 子像素
xl = mod(x1 + x0, interval)
choice = floor(xl / interval * 40)
原厂序: col = 8 - mod(choice,8) - 1, row = floor(choice/8)   # 视点0在图集右下角
uv = (vec2(col,row) + pos) / vec2(8,5)
```

**实现 B — Any2C1（HLSL，明文内嵌于 exe 偏移 ≈378800–391300）**：
```
v = (uv.x + uv.y*slope + bias*unit_subpix)*pitch + center; v = mod(v,1); v = 1 - v
viewOffset = (v - 0.5) * -1
maxParallax = 0.2 * depthFactor
FindOffsetUV_X: 16 步 POM 光线步进求横向采样偏移；R/G/B 各用自己子像素的偏移
另有 hole_filling（横向 5 格取最大深度）、depth = saturate(d*1.2-0.1)、gamma 1/2.2
```

**实现 C — D20_Dice（纯 CPU，GDI DIB，OpenMP 并行）**：公式同源，`jiange = lineNumber/3`。

**交叉验证结论**：
- A 与 B 逐像素对算，**差值恒为 0.068464**（纯常数相位差 ≈1.34 子像素 ≈2.74 视点），结构完全等价；差异源于 `px+1` vs `(px+0.5)` 取整约定，可用 deviation 补偿。
- Any2C1 视点方向与 3DGallery quilt **镜像**（视点顺序相反）。
- 40 视点在 1440px 行内各出现 34–37 次，分布均匀（Python 复算验证）。

### 3.5 术语对照表
| 3DGallery / 管道 | Any2C1 术语 | D20 变量 | 含义 |
|---|---|---|---|
| lineNumber | Lenticular Density | jiange×3 | 光栅周期（子像素） |
| obliquity | Slant Angle | stan | 倾斜斜率（tan θ） |
| deviation / centeroffset | — | pianyi(校准相关) | 相位偏移 |

---

## 4. 四个软件的逆向细节

### 4.1 3DGallery（`I:\3D\3d显示器\3DGallery\`，Electron v28，v2.3.1）
- 程序包 `resources\app.asar`（276MB），用工作区 `asar_tool.py` 提取：
  - `assets/index-DEzz72gb.js` — 播放器 + 交织 shader（核心）
  - `assets/Grating-B_hpcCOX.js` — 上传多图→云端合成页面
  - `background.js` / `preload.js` — 管道客户端、设备窗口（540×960）
- 云端合成产物（4320×4800 quilt mp4，实测分辨率）：`%APPDATA%\3DGallery\downloads\`
- API：`https://app.realplaybox.cn`（中文）/ `app.cubevi.com`
- 设备窗口走 IPC `open-device-window`，焦距调节 `adjustFocus/adjustOffset`

### 4.2 OpenstageAI（`I:\3D\3d显示器\OpenstageAI\`，参数服务端）
- `resources\app.asar` 内 `background.js`（941KB，已提取到 `openstage_ex\`）
- 密钥与 AES 解密见 §3.2
- `screen_params.json` 由旧版生成——用户参数丢失的根因

### 4.3 Any2C1（`I:\3D\3d显示器\Any2C1\`，原生 C++/D3D11 + onnxruntime + DirectML）
- 实时抓主屏 + 内置 Depth Anything v1（`depth_anything_vits14.onnx`，101MB，ViT-S/14）转光栅 3D
- 全局热键：Ctrl+Alt+1 隐藏 / 2 全屏3D（鼠标穿透）/ 3 分割预览；Ctrl+Alt+I 深度反转；Ctrl+Alt+D 画面翻转 180°
- **用户可覆写**（优先读取）：
  - `%LocalAppData%\Any2C1\screen_params.json`（光学参数，**已写入本机实测值**）
  - `%LocalAppData%\Any2C1\model\*.onnx`（可换 Depth Anything V2/V3、Distill Any Depth）
- exe 内明文 HLSL：`FullscreenVS.hlsl`、`ViewMapCS.hlsl`、`LenticularPS.hlsl`

### 4.4 D20_Dice（`I:\3D\3d显示器\D20_Dice\`，MinGW GCC + OpenMP + GDI DIB，纯 CPU 软件光栅）
- **带完整 DWARF 调试信息**（GCC 的 /4 /19 /31… 段；/19=.debug_info，RA=0xce400）
  - DIE 格式：`a1 01 <name>\0 05 <type_ref> 09 03 <addr32>`
  - imagebase 0x400000；.data VA 0x486000 起（file offset = 0x85600 + VA-0x486000）
- 关键全局变量（全 double）：
  - `jiange` @VA 486088，**初值 6.5379333**（= 光栅周期/物理像素，出厂回退值）
  - `stan` @VA 486080，**初值 0.1011**（obliquity 回退值）
  - `jianges`/`jiangel`/`jgnow`/`pianyi` 在 .bss → 校准搜索的上下界/当前值/偏移
- 常量池 @RA 638592：1440.0、2560.0、3.0、40.0、1.61803399(φ)、19.5、**0.36397023=tan(20°)**（证明 obliquity 单位是倾斜角正切）
- 中文串（GBK）："未连接到管道"、"发送命令失败，错误代码"、"读取响应失败，错误代码"
- **资源格式**：
  - `bg_rgbd.bmp`：**1080×960 = 左半 540×960 彩色 RGB | 右半 540×960 灰度深度**（已按像素验证：右半 100% 灰度）。这是官方"光栅图生成器"的输出规格
  - 皮肤：`dice_surface\` 下优先 `dice.bmp`（不存在则用 `01-20.bmp`；另有 golden/simple/wood 三套皮肤和 dice0-5.bmp 展开图）
  - 展开图 1551×732 = 正二十面体 5-10-5 三角形交错排布，**边长 a=282**（宽 5.5a、高 3×0.866a）
  - 单面 414×354（三角形底边两角在底边角落、顶点在顶边中点）
- 运行时写 `%APPDATA%\D20_Dice\bg.bmp`（背景缓存）与 `%APPDATA%\D20_Dice\data`（校准数据，**格式未知**）
- 操作：鼠标拖动掷骰 / 单击或空格随机掷；滚轮缩放；W/S 入屏出屏；R 还原；P 重新校准；ESC 退出
- 校准 = 标定光栅周期 `jiange`：单眼正对屏幕，鼠标调整使左绿/中白/右绿三线共线，点击确认
  - **对称解每隔 ≈0.159 重复一次**（相位回绕歧义）→ 微调必须限制在出厂值 ±0.075 内
- 已知瑕疵：`%APPDATA%\D20_Dice\install.json` 的 appAPath 记为 `I:\3D\D20_Dice\`，与实际 `I:\3D\3d显示器\D20_Dice\` 不符（仅影响 Uninstall.exe，主程序不读它）

### 4.5 Steam 壁纸（workshop/431960，均已订阅）
| ID | 名称 | 默认参数 |
|---|---|---|
| 3373116860 | 3d Wallpaper Player (clock) | linenumber 19.6153 |
| 3382012216 | Depth Maps C1 (RGB&D) | obliquity 0.103 |
| 3383610754 | rgbd-horizontal | linenumber 19.6401 / obliquity 0.10516 |

→ Wallpaper Engine 里应改填本机实测值 **19.6349 / 0.103813**（这是用户手动操作，未验证）。

---

## 5. 已交付成果（部署位置）

| 文件 | 位置 | 说明 |
|---|---|---|
| `Companion01_Driver.html`（v2，38KB） | 工作区根目录 | **独立驱动**，零依赖单文件 WebGL |
| `screen_params.json` | `%APPDATA%\3DGallery\`（434B） | 恢复的设备参数 |
| `screen_params.json` | `%LocalAppData%\Any2C1\`（115B） | Any2C1 光学覆写 |
| `pipe_probe.py` | 工作区 | 管道协议实测脚本（可运行） |
| `asar_tool.py` | 工作区 | asar 提取工具（list/extract） |
| `devconf.bin` | 工作区 | 解出的 deviceConfig 密文 |

### 驱动功能清单（v2）
- **模式A**：40 宫格图集（3DGallery 原厂公式，兼容其 4320×4800 mp4）
- **模式B**：RGB+深度实时视差（复刻 Any2C1 ViewMapCS + 16 步 POM），参数：depthFactor、深度反转、画面翻转、深度预处理
- **RGBD 并排图输入**（1080×960 左 RGB 右深度，兼容官方生成器输出）
- **光栅校准画面**（复刻 D20）：左绿/中白/右绿三线，左右绿条取相反深度使漂移反向对称；**实时读出左右偏移像素与不对称度**（量化判据）；鼠标拖动微调周期（限幅 ±0.075 防歧义）；结果存 localStorage
- 视点索引校准图、参数滑杆实时调节、派生量显示（jiange/周期数/倾斜角）、图集导出 PNG、全屏投副屏（F 键，H 隐藏面板）
- 出厂值下校准读数：左 −48.1px / 右 +25.5px（不对称 22.6px）；对称解 interval≈19.6682
- 已通过 node --check 语法校验、DOM id/uniform 引用完整性校验、数值交叉验证

---

## 6. 已验证结论清单

| # | 结论 | 验证方法 |
|---|---|---|
| 1 | 设备参数四元组真值 | 解密 deviceConfig.json + 管道实测，两路一致 |
| 2 | lineNumber 单位=子像素 | 220.0 整数周期 + D20 jiange=6.5379≈19.6138/3 + Any2C1 pitch=(W*3)/lineNumber 三路互证 |
| 3 | obliquity 单位=倾斜角正切 | D20 常量池 0.36397023=tan(20°) 精确值 |
| 4 | A/B 算法结构等价 | 逐像素对算，差值恒为常数 0.068464 |
| 5 | 40 视点均匀分布 | Python 复算 choice 函数，各视点 34–37 次 |
| 6 | bg_rgbd.bmp 布局 | 逐像素统计：右半 100% 灰度、左半 0% |
| 7 | 管道协议 | pipe_probe.py 实测收发成功 |
| 8 | quilt mp4 规格 = 4320×4800 | 手工解析 mp4 tkhd/stsd |

---

## 7. 缺失 / 不足 / 风险（接管者重点）

### 7.1 未做物理实测（最高优先级）
- **驱动从未在真实 Companion-01 屏幕上显示验证过**。所有验证都是数值层面的。
- 需要人工闭环：把驱动全屏投到副屏（拖窗口到副屏 → F 键 → 1:1 像素映射），单眼观察：
  1. 模式A 播放官方 mp4 是否有 3D 效果（判断视点顺序 natural/factory 哪个对）
  2. 模式B 是否出现内凹（pseudoscopic）→ 切深度反转
  3. 校准画面三线判读是否可行
- Windows 侧前提：副屏识别为 `OPC-0157-25`/`TPV-2288-IN`，分辨率设为**原生 1440×2560**（1:1 映射，否则相位整体错位）。**当前系统 EDID 实际显示什么 label 未查**（可用 PowerShell `Get-WmiObject WmiMonitorID` 或注册表 `HKLM\SYSTEM\CurrentControlSet\Enum\DISPLAY` 查）。

### 7.2 算法层未定项
- **A/B 之间 0.068464 常数相位差该归谁**：未确定哪个实现"更正确"（很可能都取决于屏幕贴装公差，最终靠校准吸收）。实测时用 deviation 滑杆扫。
- **校准对称解 19.6682 vs 出厂 19.6349 的物理意义未确认**：差 0.033。它可能补偿制造公差+眼睛位置，也可能只是我这套判据的特解。**D20 原版校准的精确绿条编码未反汇编确认**（只从变量名 jianges/jiangel/jgnow 推断校准对象是周期；没有反汇编器，无法读 .text 指令）。
- quilt 行序（5 行从上到下 vs 下到上）与原厂序的搭配：公式已逆向，但未上屏验证哪个组合正确。

### 7.3 D20_Dice 遗留
- `%APPDATA%\D20_Dice\data` 校准文件**格式未知**（未生成过，程序也没跑过）→ 无法预置校准结果；想搞清楚需要反汇编（无工具）或跑一次程序后 dump 该文件（推荐后者）。
- `install.json` 路径不一致未修复（改 `appAPath` 为 `I:\\3D\\3d显示器\\D20_Dice\\` 即可，注意 JSON 转义反斜杠）。
- D20 的鼠标校准是"左右移动"还是"上下移动"（即调周期还是调斜率）未从指令层确认——周期解释的旁证更强（三变量族）。

### 7.4 工具链限制
- **pip 不可用**：numpy/PIL/cv2 装不上 → Python 批量图像处理受限。替代：驱动的 JS canvas（已内置 RGB+D→40 视点图集生成、可导出 PNG）；或纯 Python BMP 读写（24bpp 手工解析已验证可行）。
- 无反汇编器（objdump/gdb/capstone 均无）→ 深挖 D20 .text 需先装工具（可尝试离线 whl 或让用户装 MinGW binutils）。

### 7.5 生态层
- Wallpaper Engine 壁纸参数填入（19.6349/0.103813）是用户手动操作，未回访确认效果。
- 官方"光栅图生成器"程序本身未在盘上找到（用户提到它生成的 background.bmp/bg_rgbd.bmp 格式已逆向）——若用户能提供安装包，可继续逆向其输入端格式。
- 云端 API（app.realplaybox.cn）的合成上传协议未深挖（非必需，本地已可生成 quilt）。

---

## 8. 建议下一步（按优先级）

1. **上屏实测闭环**（§7.1）：查 EDID label → 设原生分辨率 → 驱动全屏投副屏 → 逐项验证（视点顺序、深度方向、校准判读）。这一步完成后，§7.2 的三个未定项大都能当场判定。
2. 跑一次 D20_Dice 完成校准 → dump `%APPDATA%\D20_Dice\data` → 反推格式（比反汇编快得多）。
3. 修复 `install.json` 的 appAPath。
4. 若需要 Python 侧批量 quilt 生成：先解决 pip（离线包），或用驱动内置 JS 生成器导出。
5. 可选：逆向官方"光栅图生成器"（如用户能提供）。

---

## 9. 本地资产清单（工作区 `C:\Users\Administrator\WorkBuddy\2026-10-28-21-28-30\`）

| 路径 | 内容 |
|---|---|
| `Companion01_Driver.html` | **主交付物**：独立驱动 v2 |
| `pipe_probe.py` | 管道协议实测脚本（可直接运行） |
| `asar_tool.py` | asar list/extract 工具 |
| `devconf.bin` | deviceConfig 密文（解密命令见 §3.2） |
| `asar_extract\` | 3DGallery 提取物：`assets__index-DEzz72gb.js`（交织 shader）、`background.js`、`preload.js`、`assets__Grating-B_hpcCOX.js` 等 |
| `openstage_ex\` | OpenstageAI 提取物：`background.js`（密钥、管道服务端） |
| `openstage_filelist.txt` / `asar_extract\_filelist.txt` | asar 文件清单 |
| `.workbuddy\memory\2026-10-28.md` | 工作日志（本文档的浓缩版） |

**外部关键路径速查**：
- `I:\3D\3d显示器\{3DGallery, OpenstageAI, Any2C1, D20_Dice}\` — 四个程序
- `I:\3D\3d显示器\Any2C1\model\depth_anything_vits14.onnx` — 内置深度模型
- `E:\Game\Steam\steamapps\workshop\content\431960\{3373116860,3382012216,3383610754}` — 三款 Companion 壁纸
- `C:\Users\Administrator\AppData\Roaming\3DGallery\downloads\*.mp4` — 官方 4320×4800 quilt 样片（可直接喂给驱动模式A）
- 完整历史对话转录：`C:\Users\Administrator\.workbuddy\projects\c-Users-Administrator-WorkBuddy-2026-10-28-21-28-30\e8ec4906-0fa9-4c42-ba82-ba7835c6e4b5.jsonl`

---

## 10. 快速上手（接管者 5 分钟路径）

1. 读本文档 §3（核心数据）和 §5（交付物）。
2. 打开 `Companion01_Driver.html`：默认参数已是本机实测值，模式A 载入 `%APPDATA%\3DGallery\downloads\` 里任一 mp4 即可渲染。
3. 想复验参数：跑 `python pipe_probe.py`（工作区）。
4. 想复核算法：§3.4 的公式可直接用 Python 复算（见 §6 验证方法）。
5. 接着干活：从 §8 第 1 条开始。
