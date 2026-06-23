# TranslateApp — 划词翻译

macOS 极简划词翻译工具，利用本地 DeepSeek HTTP 代理实现全局划词翻译。

原生适配 Apple Silicon (M1/M2/M3/M4) 和 Intel Mac。

## 功能

- **全局快捷键** `Option+D` 触发翻译
- **任意应用**内选中文本即可翻译
- **自动语言检测**：中文↔英文
- **浮窗显示**：鼠标附近弹出，圆角毛玻璃风格
- **菜单栏常驻**：状态栏图标，不占 Dock 位置
- **CS 专业词典**：查词返回音标+释义+CS领域说明+例句
- **论文语境导入**：导入 CS 论文 PDF 提取术语，翻译时自动消歧
- 译文可选中复制，点击外部或 Esc 关闭浮窗，Cmd+/- 缩放字体
- 按 📌 固定浮窗，翻译时不会自动消失

## 前置要求

- macOS 13.0+（Ventura 或更高）
- Xcode Command Line Tools（`xcode-select --install`）
- 本地 DeepSeek 代理运行在 `http://localhost:8765`（见下方后端参考）
- Python 3 + pymupdf（仅论文导入需要，install.sh 会自动安装）

## 翻译后端

TranslateApp 本身不包含模型——它通过 OpenAI 兼容 API 连接到本地代理。

推荐使用 DeepSeek-V4 Proxy 作为后端，一行命令即可部署，支持 DeepSeek-V4 Pro（671B 参数，100 万上下文，深度推理）：

> **[deepseek-copilot-proxy](https://github.com/Camel-Prince/deepseek-copilot-proxy)**
> 一行命令，让 VS Code / Cursor 的 GitHub Copilot Chat 免费直连 DeepSeek V4 Pro，
> 同时暴露 `localhost:8765` 作为 OpenAI 兼容端点，供 TranslateApp 使用。

部署代理后，TranslateApp 即可通过 `http://localhost:8765/v1/chat/completions` 调用。

## 快速安装（推荐）

```bash
git clone <repo-url> translate
cd translate
bash install.sh
```

`install.sh` 会自动：
1. 检查 Swift / Xcode CLT
2. 安装 pymupdf（如需要）
3. 编译 app
4. 启动 app

## 手动构建

```bash
chmod +x build.sh
./build.sh
open build/TranslateApp.app
```

## 首次使用

1. 首次启动时系统弹窗请求**辅助功能权限**
2. 前往 **系统设置 → 隐私与安全性 → 辅助功能**，勾选 TranslateApp
3. 授权后在任意应用中选中文本，按 `Option+D` 即可翻译

## 项目结构

```
translate/
├── TranslateApp/           # Swift 源码
│   ├── main.swift          # 应用入口
│   ├── AppDelegate.swift   # 菜单栏 + 组件协调 + Python检测
│   ├── HotkeyManager.swift # Option+D 全局热键
│   ├── TextGrabber.swift   # 模拟 Cmd+C 获取选中文本
│   ├── TranslateService.swift # DeepSeek API + 词典
│   ├── PopupPanel.swift    # 毛玻璃浮窗 UI
│   ├── VocabularyDB.swift  # SQLite 本地词库 + 论文语境
│   ├── Info.plist          # 应用配置
│   └── AppIcon.icns        # 图标
├── scripts/
│   └── paper_translate.py  # 论文 PDF 全文翻译 + 术语提取
├── build.sh                # 一键编译
├── install.sh              # 新机一键安装
└── README.md
```

## 技术细节

| 组件 | 实现方式 |
|------|---------|
| 全局热键 | Carbon `RegisterEventHotKey` (fallback: NSEvent global monitor) |
| 取词 | 模拟 Cmd+C → 读 Pasteboard → 恢复原剪贴板 |
| 翻译 | URLSession async/await → localhost:8765 OpenAI-compatible API |
| 浮窗 | NSPanel `.resizable` + NSVisualEffectView + 智能自适配 |
| 语言检测 | CJK Unicode 比例 > 30% → 视作中文 |
| 本地词库 | SQLite WAL 模式，`.` 开头的隐藏文件 |
| 论文处理 | Python (pymupdf) → PDF 提取 → 分块翻译 → 术语抽取 |

## 自定义

- 修改 `HotkeyManager.swift` 中的 `kVK_ANSI_D` 和 `optionKey` 可更换快捷键
- 修改 `TranslateService.swift` 中的 `endpoint` 可更换翻译后端地址
- 论文导入后在菜单栏勾选/取消各论文语境，合并术语支持编辑
