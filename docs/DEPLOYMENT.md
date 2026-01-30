# OpenClaw 部署指南

在 Cloudflare Workers 上部署 OpenClaw AI 助手。

## 前置条件

- Node.js 22+
- Docker 或 OrbStack（用于构建容器镜像，镜像会推送到 Cloudflare 运行）
- Cloudflare 账户（需开通 [Containers 功能](https://developers.cloudflare.com/containers/)）
- AI 服务 API Key（Anthropic / OpenAI / MiniMax）

## 快速开始

```bash
# 克隆并安装依赖
git clone https://github.com/yuezheng2006/moltworker.git
cd moltworker
npm install

# 配置本地开发变量
cp .dev.vars.example .dev.vars
# 编辑 .dev.vars 填入 API Key

# 部署到 Cloudflare
npm run deploy
```

## 配置说明

### 必需配置

通过 `wrangler secret put <名称>` 设置：

| 名称 | 说明 |
|------|------|
| `ANTHROPIC_API_KEY` | AI 服务密钥（支持 Anthropic / MiniMax 等 Anthropic 兼容 API） |
| `MOLTBOT_GATEWAY_TOKEN` | Gateway 认证令牌 |

**AI 服务兼容性：**

支持任何兼容 **Anthropic API** 或 **OpenAI API** 格式的服务商。

| 服务商 | API 兼容 | 配置方式 |
|--------|----------|----------|
| Anthropic | Anthropic | 直接设置 `ANTHROPIC_API_KEY` |
| MiniMax | Anthropic | `ANTHROPIC_API_KEY` + `AI_GATEWAY_BASE_URL=https://api.minimax.chat/v1/anthropic` |
| OpenAI | OpenAI | `OPENAI_API_KEY` + `AI_GATEWAY_BASE_URL` 以 `/openai` 结尾 |
| 其他兼容服务 | Anthropic/OpenAI | 设置对应 Key + `AI_GATEWAY_BASE_URL`（以 `/anthropic` 或 `/openai` 结尾自动识别） |
| Cloudflare AI Gateway | 两者皆可 | `AI_GATEWAY_BASE_URL=https://gateway.ai.cloudflare.com/v1/{account}/{gateway}/{provider}` |

### 可选配置

| 名称 | 说明 |
|------|------|
| `AI_GATEWAY_BASE_URL` | 自定义 API 端点（MiniMax、Cloudflare AI Gateway 等） |
| `TELEGRAM_BOT_TOKEN` | Telegram 机器人 |
| `DISCORD_BOT_TOKEN` | Discord 机器人 |
| `FEISHU_APP_ID` | 飞书应用 ID |
| `FEISHU_APP_SECRET` | 飞书应用密钥 |

### R2 持久化存储

启用后可持久化设备配对和对话历史：

```bash
wrangler secret put R2_ACCESS_KEY_ID
wrangler secret put R2_SECRET_ACCESS_KEY
wrangler secret put CF_ACCOUNT_ID
```

## 系统架构

```
浏览器 / CLI
     │
     ▼
┌─────────────────────────────────┐
│     Cloudflare Worker           │
│  - 路由请求                      │
│  - 管理容器生命周期               │
│  - 处理认证                      │
└──────────────┬──────────────────┘
               │
               ▼
┌─────────────────────────────────┐
│     Sandbox 容器                 │
│  ┌───────────────────────────┐  │
│  │     OpenClaw Gateway      │  │
│  │  - 控制台 UI (18789)       │  │
│  │  - Agent 运行时            │  │
│  │  - 渠道集成                │  │
│  └───────────────────────────┘  │
│  ┌───────────────────────────┐  │
│  │   clawdbot-bridge         │  │
│  │  - 飞书长连接              │  │
│  └───────────────────────────┘  │
└─────────────────────────────────┘
```

## API 端点

| 路径 | 说明 |
|------|------|
| `/` | OpenClaw 控制台 |
| `/_admin/` | 设备管理 |
| `/api/status` | 健康检查 |
| `/api/admin/*` | 受保护的管理 API |

## CLI 连接

使用命令行连接已部署的 OpenClaw：

```bash
# 安装 CLI
npm install -g openclaw

# 连接（替换为你的 Worker URL 和令牌）
openclaw tui --url wss://your-worker.workers.dev --token YOUR_TOKEN
```

首次连接需在 `/_admin/` 页面批准设备。

## 渠道集成

### 飞书

1. 在 [open.feishu.cn](https://open.feishu.cn) 创建应用
2. 开启机器人能力
3. 配置密钥：
   ```bash
   wrangler secret put FEISHU_APP_ID
   wrangler secret put FEISHU_APP_SECRET
   ```
4. `clawdbot-bridge` 会自动通过 WebSocket 长连接接入

### Telegram / Discord / Slack

设置对应的 Bot Token 即可。详见 [OpenClaw 渠道文档](https://docs.openclaw.ai/channels)。

## 本地开发

```bash
# 本地运行（WebSocket 功能受限）
npm run start

# 运行测试
npm test

# 仅构建
npm run build
```

## 故障排查

### 检查状态

```bash
curl https://your-worker.workers.dev/api/status
```

### 查看日志

```bash
npx wrangler tail
```

### 调试路由

设置 `DEBUG_ROUTES=true` 后访问 `/debug/*`。

## 参考链接

- [OpenClaw 文档](https://docs.openclaw.ai/)
- [Cloudflare Containers](https://developers.cloudflare.com/containers/)
