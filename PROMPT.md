# 项目启动 Prompt — 极简划词翻译工具

## 项目概述

构建一个 macOS 极简划词翻译工具，利用本地已部署的 DeepSeek HTTP 代理（`http://localhost:8765/v1/chat/completions`）实现全局划词翻译。要求能在 **任意应用**（WPS、VS Code、Chrome、Safari、Finder、Terminal 等）中通过全局快捷键触发翻译，并以浮窗形式展示结果。

## 技术架构

- **语言**: Swift + AppKit（原生 macOS，轻量无依赖）
- **翻译后端**: 本地 DeepSeek 代理 `POST http://localhost:8765/v1/chat/completions`
- **取词方式**: 模拟 Cmd+C 获取选中文本（通过 Pasteboard），无需 Accessibility API 权限
- **展示方式**: 无边框悬浮 NSPanel，显示在鼠标附近
- **交互方式**: 全局快捷键 `Option+D`（可自定义）触发翻译

## API 调用规格

```bash
curl -X POST http://localhost:8765/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer sk-placeholder" \
  -d '{
    "model": "deepseek-chat",
    "messages": [
      {"role": "system", "content": "你是一个翻译助手。将用户输入翻译为中文（如果输入是中文则翻译为英文）。只输出翻译结果，不要解释。"},
      {"role": "user", "content": "要翻译的文本"}
    ],
    "max_tokens": 2048,
    "stream": false
  }'
```

- Authorization header 中的 key 可以是任意值（代理会覆盖为真实 key）
- `stream: false` 简化实现，一次性返回结果
- 响应格式为标准 OpenAI `choices[0].message.content`

## 核心功能需求

### 1. 全局快捷键监听
- 注册全局热键 `Option+D`
- 使用 `CGEvent` tap 或 `NSEvent.addGlobalMonitorForEvents` 实现
- 需要在 Info.plist 声明辅助功能权限（或引导用户授权）

### 2. 获取选中文本
- 触发快捷键后：
  1. 保存当前剪贴板内容
  2. 模拟 `Cmd+C`（使用 CGEvent 模拟按键）
  3. 短暂延迟（50-100ms）后读取剪贴板
  4. 恢复原始剪贴板内容
- 如果剪贴板无变化（未选中文本），不做任何操作

### 3. 翻译请求
- 检测输入语言：纯 ASCII/拉丁字符 → 翻译为中文；含 CJK 字符 → 翻译为英文
- 调用本地代理 API，超时 10 秒
- 支持翻译中显示 loading 状态

### 4. 结果展示浮窗
- 无标题栏 NSPanel（`NSPanel.StyleMask = [.nonactivatingPanel, .borderless]`）
- 圆角 + 阴影 + 半透明背景（vibrancy effect）
- 显示位置：鼠标光标附近（避免超出屏幕）
- 内容：原文（灰色小字）+ 译文（正常大小）
- 点击浮窗外任意位置自动关闭
- 按 Esc 关闭
- 支持选中译文复制

### 5. 菜单栏图标
- 状态栏显示一个翻译图标（📖 或自定义 SF Symbol）
- 右键菜单：「设置快捷键」「退出」
- 左键单击：无操作或显示最近翻译

## 项目结构

```
translate/
├── TranslateApp/
│   ├── AppDelegate.swift          # 应用入口，菜单栏图标
│   ├── HotkeyManager.swift        # 全局快捷键注册与监听
│   ├── TextGrabber.swift          # 模拟 Cmd+C 获取选中文本
│   ├── TranslateService.swift     # 调用 DeepSeek API
│   ├── PopupPanel.swift           # 悬浮翻译结果窗口
│   ├── Assets.xcassets/           # 图标资源
│   └── Info.plist                 # 权限声明
├── TranslateApp.xcodeproj/
└── README.md
```

## 非功能需求

- **极简**：无多余功能，启动即用，代码量控制在 500 行以内
- **低资源占用**：常驻内存 < 20MB，无 Electron/WebView
- **快速响应**：从按下快捷键到显示结果 < 2 秒（取决于 API 延迟）
- **无需配置**：硬编码 `localhost:8765`，开箱即用
- **macOS 13+**：使用现代 Swift 并发（async/await）

## 注意事项

1. 模拟按键需要「辅助功能」权限，首次启动需引导用户在系统设置中授权
2. 浮窗使用 `.nonactivatingPanel` 确保不抢焦点（用户可以继续在原 App 操作）
3. 剪贴板操作要做好 save/restore，避免覆盖用户正在使用的剪贴板内容
4. API 请求失败时显示简短错误提示（如"翻译服务不可用"）
5. 应用应作为 LSUIElement（后台应用），不显示 Dock 图标

## 启动指令

请先创建完整的 Xcode 项目结构，实现上述所有功能。优先确保核心流程跑通（快捷键 → 取词 → 翻译 → 浮窗），再美化 UI。
