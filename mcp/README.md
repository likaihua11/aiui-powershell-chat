# MCP 服务壳（`mcp/`）

> 一套**自研的、零依赖的** MCP（Model Context Protocol）服务端 + 命令行客户端 + 工具链。
> 不使用官方 SDK，纯 PowerShell 实现，Windows 自带的 PowerShell 5.1 即可运行。

## 一、这是什么

MCP 是模型与「工具」之间的协议（Claude Desktop 使用的那套）。本目录提供的是它的**壳**：

| 文件 | 作用 |
|---|---|
| `kb-local-mcp.ps1` | MCP **服务器**：走 stdio，JSON-RPC 2.0，实现 `initialize` / `tools/list` / `tools/call` / `ping` |
| `call-tool.ps1` | **命令行客户端**：不经过 IDE 也能直接调用工具（`list` / `schema` / `run`），不占模型上下文 |
| `test-kb-local-mcp.ps1` | **冒烟测试**：自带断言，末尾输出 PASS / FAIL 计数 |
| `export-tools.ps1` | 导出 `tools/list` 快照（JSON），供手册生成使用 |
| `gen-manual.ps1` | 由快照生成工具手册（Markdown） |

> 具体的**工具脚本本体**（`tools/*.tool.ps1`）属于使用者的本地沉淀，**本仓库不发布**。

## 二、核心设计：工具插槽

**把 `*.tool.ps1` 丢进 `mcp/tools/`，服务端就自动多出一个工具** —— 服务端代码不用改，IDE 注册也不用改（重启 IDE 生效）。

`tools/_disabled/` 下的工具**不挂载**（不进 `tools/list`、不占 token），但可以用 `call-tool.ps1` 直接调用。

这带来两个好处：

1. **省上下文**：只挂载常用的几个，其余按需调用 —— `tools/list` 的体积直接等于你要付的 token 成本。
2. **易沉淀**：新工具 = 新增一个文件，没有注册表、没有配置文件。

## 三、怎么跑

```powershell
# 1) 启动服务端（前台，等 stdin；正常使用由宿主 IDE 拉起，不用手跑）
powershell -NoProfile -ExecutionPolicy Bypass -File mcp\kb-local-mcp.ps1

# 2) 冒烟测试（推荐先跑这个，不需要 IDE）
powershell -NoProfile -ExecutionPolicy Bypass -File mcp\test-kb-local-mcp.ps1

# 3) 重建工具手册（先导出快照并校验，再重生成）
powershell -NoProfile -ExecutionPolicy Bypass -File mcp\export-tools.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File mcp\gen-manual.ps1

# 4) 调用未挂载的工具（不进模型上下文，不必改挂载状态）
powershell -NoProfile -ExecutionPolicy Bypass -File mcp\call-tool.ps1 list
powershell -NoProfile -ExecutionPolicy Bypass -File mcp\call-tool.ps1 schema <工具名>
powershell -NoProfile -ExecutionPolicy Bypass -File mcp\call-tool.ps1 run <工具名> k=v ...
```

服务端的数据根目录默认取**脚本上一级目录**（可移植），可用 `-Root <你的资料目录>` 覆盖。

命令行客户端的两个约定：

- `run <工具名> k=v` —— 推荐写法，免引号转义；
- `run <工具名> '<JSON>'` —— 值里含逗号 / 花括号时用 `-ArgsFile args.json`。

（`powershell.exe -File` 会吞掉参数里的双引号，`call-tool.ps1` 内置了自动修回。）

## 四、写一个新工具

`*.tool.ps1` 的约定 —— **头部注释即元数据**：

```powershell
# name: my_tool
# description: 一句话说明这个工具干什么、什么时候该用它。
# params: [{"name":"action","type":"string","description":"要做的事"}]
# timeout: 30
```

硬性要求：

- 参数只从 **stdin** 读 JSON；
- 结果以 **UTF-8 无 BOM** 直写 stdout；
- 用**退出码**表示成败；
- 头部 `params` 必须是合法 JSON Schema。

写完必须跑 `test-kb-local-mcp.ps1` 冒烟，末尾 `FAIL=0` 才算过。

## 五、边界与已知约束

- 语料检索是**纯本地**的，不联网，毫秒级；`-Root` 指到很大的目录会线性变慢。
- 工具在**本机**执行，能力边界 = 当前用户的权限，**没有任何沙箱**。
- 经 MCP 通道起的子进程，其环境变量可能被宿主程序改写（例如 `PATHEXT` / `ComSpec`），脚本内做了环境自愈。
- 服务端不内置鉴权：谁能起它，谁就能用它的全部工具。
