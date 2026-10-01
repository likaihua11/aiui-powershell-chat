# aiui · 本地 AI 对话界面（Windows）

> **English** · A self-hosted AI chat UI for Windows — **single-file HTML frontend + zero-admin PowerShell backend**. No Python, no Node.js, no installer, no administrator rights. Talks to any OpenAI-compatible endpoint (Ollama, vLLM, LM Studio, DeepSeek, OpenAI). Highlights: SSE streaming, MCP tool calling, reusable skills, PC ⇄ phone conversation sync. The `mcp/` folder ships the **MCP service shell** (server + CLI client + toolchain + docs).

## 一、这是什么

零依赖、免安装、免管理员权限的**本地 AI 对话界面**。

| 部件 | 实现 |
|---|---|
| 前端 | `index.html` —— 单文件（原生 JS，无框架、无构建步骤） |
| 后端 | `serve.ps1` —— 纯 PowerShell（`System.Net.HttpListener`），Windows 自带 PowerShell 5.1 即可跑 |
| 上游 | 任意 **OpenAI 兼容**接口：本地 Ollama / vLLM / LM Studio，或云端 DeepSeek / OpenAI |
| 数据 | 对话与设置都是**本地 JSON 文件**，没有数据库、没有云账号 |

不装 Python、不装 Node.js、不装运行时、不要管理员权限。

## 二、功能

| 能力 | 说明 |
|---|---|
| **SSE 流式输出** | 回答逐字呈现；「思考过程」与「工具调用步骤」就地渲染 |
| **MCP 工具调用** | 接任意 Model Context Protocol 服务器；工具在**本机**执行，不在云端 |
| **技能（Skills）** | 往 `skills/` 丢一个 Markdown，按会话勾选启用，正文作为 system 消息注入 |
| **多会话** | 新建 / 切换 / 双击重命名 / 删除；标题取首条提问前 24 字 |
| **两端同步** | 同一局域网内，电脑与手机看到**同一份对话**、逐字生长，带回合锁（同时只一端生成） |
| **并发不冻结** | 长耗时路由跑在 runspace 池（1–6），模型回答 / 工具执行期间界面照常响应 |
| **Markdown 渲染** | 表格（含对齐）、任务列表、嵌套列表、引用块；代码块一键复制 |
| **全部落盘** | 历史与设置是纯 JSON 文件，可整体拷走做迁移 / 备份 |

## 三、快速开始

**最简单：双击 `start.bat`** —— 它会先确保**启动器**常驻，再确保**后端**在跑，最后打开浏览器。

等价命令行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File serve.ps1 -Port 8787 -Open
```

然后浏览器打开 `http://127.0.0.1:8787/`（加 `-Open` 会自动打开）。

一键更新（停旧进程并重启最新版）—— **双击 `restart.bat`**：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File update.ps1 -Port 8787 -Open
```

**判断后端是否在跑，一律用探针，不要看端口**：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File serve.ps1 -Port 8787 -Check   # 退出码 0=在跑 / 1=没在跑
```

`-Check` 只发一条 `/api/health` 并校验 `name == "aiui"`，不启动监听，可安全反复调用。

## 四、应用场景

- **本地私有对话**：模型跑在 Ollama / LM Studio，数据不出本机，断网可用。
- **本机自动化入口**：通过 MCP 让模型调用本机工具（读写文件、跑命令、查日志、连 Android 设备等），把「对话」变成「操作」。
- **多端接力**：PC 上写一半，拿起手机接着看，回答还在逐字长。
- **提示词沉淀**：把常用人设 / 工作流写成 `skills/*.md`，按会话勾选，不用每次粘贴。
- **教学 / 内网部署**：整包一个文件夹，拷到内网机器双击即用。

## 五、目录职责

| 文件 | 职责 |
|---|---|
| `index.html` | 前端界面：极简·大留白排版（侧栏收起、居中 600px、行高 2.0、输入仅一条底线） |
| `serve.ps1` | 本地后端：静态托管 + `/api/*`（见「六、接口契约」） |
| `launcher.ps1` | 常驻启动器（8788）：浏览器不能启动本地进程，它代劳；另供 `/api/ping`、`/api/launch`、`/api/restart` 与状态页 |
| `update.ps1` | 一键更新：停掉旧 `serve.ps1` 进程并重启最新版（含健康检查） |
| `start.bat` | **双击启动入口**：确保启动器 → 确保后端 → 打开浏览器；关窗即停后端 |
| `restart.bat` | **双击重启入口**：调 `update.ps1` 停旧起新并自动开页 |
| `lan-setup.bat` | 局域网 / 手机访问的一次性准备（需管理员，见「八」） |
| `mcp/` | MCP 服务壳：服务器 + 命令行客户端 + 工具链 + 文档 |

## 六、接口契约

| 接口 | 方法 | 入参 | 返回 |
|---|---|---|---|
| `/api/health` | GET | — | `{ok, name, version, time}` |
| `/api/models` | GET | `endpoint`、`apiKey`（query） | 上游 `/models` 原样透传；上游失败回 502 + `{ok:false, error}` |
| `/api/chat` | POST | `{endpoint, apiKey, model, messages, temperature, stream}` | `text/event-stream`，上游 SSE 原样流式透传 |
| `/api/memory` | GET / POST | GET: `key`；POST: 任意 JSON | 键值 blob 仓库，落 `..\jiyi\<key>.json`；key 限 `^[A-Za-z0-9_-]{1,64}$` |
| `/api/mcp/tools` | POST | `{servers:[…]}` | 聚合各 MCP 服务器 `tools/list`，回 `{ok, tools:[…], errors}` |
| `/api/mcp/call` | POST | `{server, tool, arguments}` | 转发 `tools/call`，回 `{ok, content, isError}` |
| `/api/skills` | GET | — | 扫描 `./skills/*.md`（frontmatter: name/description），回 `{ok, dir, skills:[…]}` |
| `/api/shutdown` | POST | —（仅限本机回环） | 优雅停机：正常退出服务循环、释放 http.sys 注册后再结束进程 |
| `/api/sync` | GET | `keys`、`sess`、`cid`、`act` | `{ok, revs:{key:版本}, turn:{…}}`；版本 = 文件 ticks + 长度；`turn` 是回合锁 |

长耗时路由（`/api/chat`、`/api/mcp/call`、`/api/mcp/tools`）跑在 runspace 池（上限 6、队列 24），主循环只处理轻量请求 —— 所以模型回答期间，静态页与 `/api/health` 仍即时响应。

## 七、技能（Skills）

- 技能 = `skills/<id>.md`，带 frontmatter（`name`、`description`）+ 正文；`id` 仅允许字母 / 数字 / `_` / `-`。
- 后端提供 `GET /api/skills` 扫描技能目录；`POST /api/chat` 时把**已启用**技能正文拼成一条 system 消息注入。
- 前端「设置 → 技能」勾选启用；新增技能后点「重新扫描技能」。

## 八、局域网 / 手机访问（可选）

把壳子挂到局域网，手机就能打开**同一个界面**；推理、工具调用、记忆落盘**全部仍发生在电脑上**。对话历史与服务端双写同步（每 1500ms 轮询 `/api/sync`），任一端发消息，另一端会显示出来，回答还会**逐字生长**；同一时刻只有一端在生成（回合锁）。

**① 一次性准备（管理员）**：右键「以管理员身份运行」`lan-setup.bat`，它做两件事：

- `netsh http add urlacl url=http://+:8787/ user=<当前用户>` —— 授权非管理员进程绑定 `+` 前缀；
- 添加入站防火墙规则（TCP 8787 / 允许）。

**② 启动**：双击 `start.bat`，或

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File serve.ps1 -Port 8787 -Open -Lan
```

后端窗口会打印 `http://<本机IP>:8787/  (LAN)`，手机连**同一 Wi-Fi** 打开该地址即可。

**③ 关掉局域网访问**（管理员）：

```powershell
netsh http delete urlacl url=http://+:8787/
Remove-NetFirewallRule -DisplayName 'aiui LAN 8787'
```

## 九、安全说明

> **没有鉴权**：局域网内任何人都能打开这个壳子，而 `/api/mcp/call` 能在本机执行命令、
> `/api/memory?key=settings` 能读到设置（含明文 `apiKey`）。**公共 / 不可信 Wi-Fi 下不要开。**

## 十、已知边界

- **端口 LISTENING ≠ 后端在跑**：8787/8788 的 LISTENING 归属 http.sys 的**内核端点**。若某进程被杀而没释放注册，端口会一直 LISTENING、TCP 也能连上，但请求一律回 **503**，且新后端再也绑不上。所以存活判据必须是「HTTP 探针 + `name=aiui`」。真遇到残留：`netsh http show servicestate | findstr /i 8787` 查出注册它的 PID，结束该进程即可。`update.ps1` 因此**先调 `/api/shutdown` 请旧后端优雅退出**，超时才强杀兜底。
- **Markdown**：正文用自研简易渲染，未支持内联 HTML、脚注、数学公式。
- 界面**固定浅色**，不跟随系统暗色主题。
- **左栏在 ≤760px** 宽度下改为**抽屉**（顶栏「人设 / 技能」按钮），手机上也能切人设 / 勾技能。
- **两端同步的边界**：轮询间隔 1500ms（即最坏约 1.5 秒延迟）；每次整份拉取当前会话；图片不参与同步（另一端看不到、刷新后不回放）；回合锁是内存态，后端重启即清空。
- **电脑睡眠 = 服务冻结**：后端是电脑上的进程，机器一进睡眠，手机连不上、`/api/sync` 也断；**熄屏无影响**。部署到别的机器时请自行核对电源方案：`powercfg /q SCHEME_CURRENT SUB_SLEEP STANDBYIDLE`（`0x00000000` = 从不）。

## 十一、MCP 服务壳（`mcp/`）

`mcp/` 提供一套**自研的 MCP 服务端 + 命令行客户端 + 工具链**（不依赖官方 SDK）：

- `kb-local-mcp.ps1` —— MCP 服务器（stdio，JSON-RPC 2.0）。
- `call-tool.ps1` —— 命令行客户端：不经过 IDE 也能直接调用工具，不占上下文。
- `test-kb-local-mcp.ps1` —— 冒烟测试（自带断言，末尾输出 PASS / FAIL 计数）。
- `export-tools.ps1` / `gen-manual.ps1` —— 工具清单导出与手册生成。
- **工具插槽机制**：把 `*.tool.ps1` 丢进 `mcp/tools/`，服务端自动多出一个工具，**服务端代码与 IDE 注册都不用改**。

> 本仓库**不包含**具体的工具脚本本体（那属于使用者的本地沉淀），只发布这套**壳**与文档。详见 `mcp/README.md`。

## 十二、许可

本仓库尚未附带许可证文件，默认即**保留所有权利**。若打算复用或分发，请自行添加（MIT / Apache-2.0）。

---

## English

**aiui** is a self-hosted AI chat interface for Windows: a **single-file HTML frontend** plus a **zero-admin PowerShell backend**. No Python, no Node.js, no installer, no administrator rights — it runs on stock Windows PowerShell 5.1.

### Quick start

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File serve.ps1 -Port 8787 -Open
```

Then open `http://127.0.0.1:8787/`. On Windows you can simply double-click `start.bat` instead.

### Features

- **Any OpenAI-compatible upstream** — Ollama, vLLM, LM Studio, DeepSeek, OpenAI and friends.
- **SSE streaming** — replies appear token by token, with reasoning and tool-call steps rendered inline.
- **MCP tool calling** — Model Context Protocol (the protocol used by Claude Desktop); connect any local MCP server.
- **Skills** — drop a Markdown file into `skills/` and enable it per conversation; its body is injected as a system message.
- **PC ⇄ phone sync** — serve it over your LAN and both screens show the *same* conversation, growing word by word, with a turn lock so only one side generates at a time.
- **Everything on disk** — conversation history and settings are plain JSON files you own. No database, no cloud account.

### Architecture

| File | Role |
|---|---|
| `index.html` | Single-file frontend (vanilla JS, no framework, no build step) |
| `serve.ps1` | Backend: static hosting + `/api/chat` SSE proxy, `/api/memory`, `/api/sync`, `/api/mcp/*` |
| `launcher.ps1` | Resident helper on port 8788 — starts the backend on demand (browsers cannot spawn local processes) |
| `start.bat` / `restart.bat` / `update.ps1` | One-click start, restart and self-update |
| `mcp/` | Self-built MCP *service shell*: server + CLI client + toolchain + docs (the concrete tool scripts are not published) |

Long-running routes (`/api/chat`, `/api/mcp/call`, `/api/mcp/tools`) run in a runspace pool, so the UI never freezes while a model is answering or a tool is executing.

### Security note

There is **no authentication**. The LAN mode can execute local commands through `/api/mcp/call` and exposes settings via `/api/memory`. Do not run it on public or untrusted Wi-Fi.

### License

No license file has been added yet, which by default means **all rights reserved**. Add one (MIT / Apache-2.0) if you intend to reuse or distribute this code.
