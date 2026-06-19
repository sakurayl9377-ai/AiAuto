# CC Switch 登录与 API 接入教程

这份教程用于 CodeMate Setup 安装 CC Switch 后的下一步配置。目标是让用户能真正用上 Codex、Claude Code、Cursor 等 AI 编程工具。

## 先选一种使用路线

### 路线 A：官方登录

适合已经有官方账号、订阅或团队权限，并且当前网络可以稳定访问官方服务的用户。

1. 在 `Install Tools` 页安装需要的工具，例如 Codex 桌面版、Codex 命令行版、Claude Code 或 Cursor。
2. 打开对应工具。
3. 按工具内提示选择官方账号登录。
4. 登录成功后，新建或打开一个项目，发送一个简单问题测试是否可用。
5. 如果工具一直卡在登录、模型连接失败，或你希望多个工具共用同一套 OpenAI-compatible 配置，可以改用路线 B。

提示：官方登录的入口和账号要求由各工具官方决定。CodeMate 只负责安装、检测和配置辅助，不会代替用户创建账号、绕过验证或保存官方账号密码。

## 路线 B：API Key / 中转站 / OpenAI-compatible 网关

适合使用自备 API Key、企业网关、中转站、OpenRouter、本地 OpenAI-compatible 服务等场景。

### 1. 获取 Base URL、API Key、Model

通常在 API 服务站或网关后台可以找到这些信息：

- `Base URL`：接口根地址。常见示例是 `https://api.openai.com`、`https://openrouter.ai/api`、`http://127.0.0.1:11434`。
- `API Key`：密钥或令牌，常见名称是 `API Key`、`Secret Key`、`Token`、`Bearer Token`。
- `Model`：模型名称，例如官方或网关后台列出的模型 ID。

CodeMate 的 `Provider Test` 页要求 Base URL 填“根地址”，不要手动加 `/v1`。程序会在本地测试和生成 CC Switch 配置时自动拼接 `/v1`。

示例：

| 服务给你的地址 | 在 CodeMate 里填写 |
| --- | --- |
| `https://api.example.com/v1` | `https://api.example.com` |
| `https://openrouter.ai/api/v1` | `https://openrouter.ai/api` |
| `http://127.0.0.1:11434/v1` | `http://127.0.0.1:11434` |

如果服务后台只写了“OpenAI-compatible endpoint”，一般复制其中的根地址即可。若服务要求自定义请求头、额外参数或非 OpenAI-compatible 协议，当前 CodeMate Provider Test 可能无法直接支持。

### 2. 在 Provider Test 页测试

1. 打开 CodeMate Setup 的 `Provider Test` 页。
2. 在 `Provider` 下拉框中选择服务类型。
   - OpenAI Official：官方 OpenAI API。
   - OpenRouter：OpenRouter 网关。
   - Local OpenAI-Compatible：本地 OpenAI-compatible 服务。
   - Custom OpenAI-Compatible：其他中转站或自建网关。
3. 填写 `Base URL`。只填根地址，不要带 `/v1`。
4. 填写 `API Key`。
5. 填写 `Model`。如果不确定，先用服务后台推荐的模型 ID。
6. 点击 `Test Locally`。
7. 看到 `Success: True` 或模型列表/测试响应成功后，再进入下一步。

测试请求从本机直接发出。CodeMate 不会把 API Key 上传到 CodeMate 后台；导出的诊断信息也会对密钥做脱敏。

### 3. 在 CC Switch 页生成配置

1. 打开 CodeMate Setup 的 `CC Switch` 页。
2. 在 `Profile Name` 填一个容易识别的名称，例如 `OpenRouter GPT` 或 `Company Gateway`。
3. 点击 `Generate`。
4. 下方会显示：
   - `Deep Link`：用于一键导入 CC Switch 的链接。
   - `Redacted Profile`：脱敏后的配置预览。
5. 点击 `Copy Link` 复制 deep link，或点击 `Open Link` 直接唤起 CC Switch 导入。
6. 也可以点击 `Save JSON` 保存配置文件，再在 CC Switch 中手动导入。

### 4. 导入并切换 CC Switch 配置

1. 确认 CC Switch 已安装并能打开。
2. 使用 CodeMate 生成的 `Open Link` 或 `Copy Link` 导入配置。
3. 在 CC Switch 中选择刚导入的 profile。
4. 应用或切换到该配置。
5. 重新打开目标工具，或重启相关终端窗口。
6. 在 Codex、Claude Code、Cursor 等工具里发起一次简单测试。

如果工具仍然不可用，请回到 `Provider Test` 页重新测试 Base URL、API Key 和 Model 是否有效。

## 常见问题

### Base URL 到底填什么？

填服务根地址，不要带 `/v1`。CodeMate 会自动拼接 `/v1`。

例如服务文档写 `https://api.example.com/v1/chat/completions`，你应填写 `https://api.example.com`。

### API Key 从哪里来？

从你使用的服务后台获取。常见位置包括：

- 官方 API 平台的 API Keys 页面。
- 中转站或网关后台的“令牌”“密钥”“API Key”“Token”页面。
- 企业内部网关管理员发放的凭据。
- 本地服务工具生成或约定的 Key。

不要把 API Key 发给陌生人，也不要贴到公开 issue、截图或聊天记录里。

### Model 填什么？

填服务后台提供的模型 ID。不同平台模型名不一定一样。Provider Test 成功获取模型列表时，可以从输出中的 `Models` 部分选择。

### Provider Test 成功，但工具还是不能用怎么办？

1. 确认已经在 `CC Switch` 页生成并导入 profile。
2. 确认 CC Switch 当前切换到该 profile。
3. 重启 Codex、Claude Code、Cursor 或终端窗口。
4. 检查目标工具是否支持 CC Switch 当前生成的目标配置。
5. 回到 Provider Test 再测一次，排除 Key 过期、余额不足、模型名错误等问题。

### 官方登录和 API Key 路线可以同时保留吗？

可以。官方登录适合官方账号体验，API Key 路线适合自备模型供应商或网关。CC Switch 的价值是让多个工具之间更方便地切换配置。

## 安全说明

- CodeMate 的 Provider Test 在本机发起请求。
- CodeMate 生成 CC Switch 配置时会使用你输入的 API Key，但不会上传到 CodeMate 后台。
- 保存 JSON 配置时，真实配置可能包含 API Key，请妥善保管。
- 分享截图或日志前，确认 API Key 已脱敏。
