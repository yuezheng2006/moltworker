#!/bin/bash
# Startup script for Moltbot in Cloudflare Sandbox
# This script:
# 1. Mounts R2 bucket using tigrisfs FUSE (if credentials provided)
# 2. Configures moltbot from environment variables
# 3. Starts the gateway

set -e

# Check if clawdbot gateway is already running - bail early if so
# Note: CLI is still named "clawdbot" until upstream renames it
if pgrep -f "clawdbot gateway" > /dev/null 2>&1; then
    echo "Moltbot gateway is already running, exiting."
    exit 0
fi

# Paths (clawdbot paths are used internally - upstream hasn't renamed yet)
CONFIG_DIR="/root/.clawdbot"
CONFIG_FILE="$CONFIG_DIR/clawdbot.json"
TEMPLATE_DIR="/root/.clawdbot-templates"
TEMPLATE_FILE="$TEMPLATE_DIR/moltbot.json.template"
R2_MOUNT_PATH="/data/moltbot"

echo "Config directory: $CONFIG_DIR"
echo "R2 mount path: $R2_MOUNT_PATH"

# Create directories
mkdir -p "$CONFIG_DIR"
mkdir -p "$R2_MOUNT_PATH"

# ============================================================
# MOUNT R2 BUCKET USING TIGRISFS
# ============================================================
# If R2 credentials are provided, mount the bucket using tigrisfs FUSE
# This provides direct read/write access to R2 as a filesystem

if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ] && [ -n "$R2_ACCOUNT_ID" ] && [ -n "$R2_BUCKET_NAME" ]; then
    echo "R2 credentials found, mounting bucket..."
    
    R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
    echo "R2 endpoint: $R2_ENDPOINT"
    echo "R2 bucket: $R2_BUCKET_NAME"
    
    # Check if already mounted
    if mount | grep -q "tigrisfs on $R2_MOUNT_PATH"; then
        echo "R2 bucket already mounted at $R2_MOUNT_PATH"
    else
        echo "Mounting R2 bucket to $R2_MOUNT_PATH..."
        # tigrisfs: -f runs in foreground, & backgrounds it in shell
        # This matches the recommended pattern from Cloudflare docs
        /usr/local/bin/tigrisfs --endpoint "$R2_ENDPOINT" -f "$R2_BUCKET_NAME" "$R2_MOUNT_PATH" &
        
        # Wait for mount (simple sleep like docs example)
        sleep 5
        
        # Verify mount
        echo "Mount status after sleep:"
        mount | grep fuse || echo "No FUSE mounts found"
        ls -la "$R2_MOUNT_PATH" 2>/dev/null && echo "Mount appears successful" || echo "Mount directory not accessible"
    fi
    
    # If R2 is mounted, use it for clawdbot config
    if mount | grep -q "$R2_MOUNT_PATH"; then
        echo "Contents of R2 mount:"
        ls -la "$R2_MOUNT_PATH" 2>/dev/null || echo "(empty or not accessible)"
        
        # Create clawdbot subdirectory in R2 if it doesn't exist
        mkdir -p "$R2_MOUNT_PATH/clawdbot" 2>/dev/null || true
        
        # Symlink the config directory to R2
        # This way all clawdbot state is persisted directly to R2
        if [ ! -L "$CONFIG_DIR" ]; then
            # Backup any existing local config
            if [ -d "$CONFIG_DIR" ] && [ "$(ls -A $CONFIG_DIR 2>/dev/null)" ]; then
                echo "Migrating existing config to R2..."
                cp -a "$CONFIG_DIR/." "$R2_MOUNT_PATH/clawdbot/" 2>/dev/null || true
            fi
            rm -rf "$CONFIG_DIR"
            ln -sf "$R2_MOUNT_PATH/clawdbot" "$CONFIG_DIR"
            echo "Config directory symlinked to R2: $CONFIG_DIR -> $R2_MOUNT_PATH/clawdbot"
        fi
        
        # Also symlink skills directory
        SKILLS_DIR="/root/clawd/skills"
        mkdir -p "$R2_MOUNT_PATH/skills" 2>/dev/null || true
        if [ ! -L "$SKILLS_DIR" ]; then
            # Backup any existing local skills
            if [ -d "$SKILLS_DIR" ] && [ "$(ls -A $SKILLS_DIR 2>/dev/null)" ]; then
                echo "Migrating existing skills to R2..."
                cp -a "$SKILLS_DIR/." "$R2_MOUNT_PATH/skills/" 2>/dev/null || true
            fi
            rm -rf "$SKILLS_DIR"
            ln -sf "$R2_MOUNT_PATH/skills" "$SKILLS_DIR"
            echo "Skills directory symlinked to R2: $SKILLS_DIR -> $R2_MOUNT_PATH/skills"
        fi
    fi
else
    echo "R2 credentials not configured, using local storage (not persistent)"
    echo "To enable persistence, set: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, R2_ACCOUNT_ID, R2_BUCKET_NAME"
fi

# Ensure config directory exists (whether symlink or real)
mkdir -p "$CONFIG_DIR" 2>/dev/null || true

# If config file still doesn't exist, create from template
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No existing config found, initializing from template..."
    if [ -f "$TEMPLATE_FILE" ]; then
        cp "$TEMPLATE_FILE" "$CONFIG_FILE"
    else
        # Create minimal config if template doesn't exist
        cat > "$CONFIG_FILE" << 'EOFCONFIG'
{
  "agents": {
    "defaults": {
      "workspace": "/root/clawd",
      "model": {
        "primary": "anthropic/claude-opus-4-5-20251101"
      }
    }
  },
  "gateway": {
    "port": 18789,
    "mode": "local"
  }
}
EOFCONFIG
    fi
else
    echo "Using existing config"
fi

# ============================================================
# UPDATE CONFIG FROM ENVIRONMENT VARIABLES
# ============================================================
node << EOFNODE
const fs = require('fs');

const configPath = '/root/.clawdbot/clawdbot.json';
console.log('Updating config at:', configPath);
let config = {};

try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
    console.log('Starting with empty config');
}

// Ensure nested objects exist
config.agents = config.agents || {};
config.agents.defaults = config.agents.defaults || {};
config.agents.defaults.model = config.agents.defaults.model || {};
config.gateway = config.gateway || {};

// Set default model to Opus 4.5
config.agents.defaults.model.primary = 'anthropic/claude-opus-4-5-20251101';
config.channels = config.channels || {};

// Clean up any broken anthropic provider config from previous runs
// (older versions didn't include required 'name' field)
if (config.models?.providers?.anthropic?.models) {
    const hasInvalidModels = config.models.providers.anthropic.models.some(m => !m.name);
    if (hasInvalidModels) {
        console.log('Removing broken anthropic provider config (missing model names)');
        delete config.models.providers.anthropic;
    }
}

// Gateway configuration
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];

// Set gateway token if provided
if (process.env.CLAWDBOT_GATEWAY_TOKEN) {
    config.gateway.auth = config.gateway.auth || {};
    config.gateway.auth.token = process.env.CLAWDBOT_GATEWAY_TOKEN;
}

// Allow insecure auth for dev mode
if (process.env.CLAWDBOT_DEV_MODE === 'true') {
    config.gateway.controlUi = config.gateway.controlUi || {};
    config.gateway.controlUi.allowInsecureAuth = true;
}

// Telegram configuration
if (process.env.TELEGRAM_BOT_TOKEN) {
    config.channels.telegram = config.channels.telegram || {};
    config.channels.telegram.botToken = process.env.TELEGRAM_BOT_TOKEN;
    config.channels.telegram.enabled = true;
    config.channels.telegram.dm = config.channels.telegram.dm || {};
    config.channels.telegram.dm.policy = process.env.TELEGRAM_DM_POLICY || 'pairing';
}

// Discord configuration
if (process.env.DISCORD_BOT_TOKEN) {
    config.channels.discord = config.channels.discord || {};
    config.channels.discord.token = process.env.DISCORD_BOT_TOKEN;
    config.channels.discord.enabled = true;
    config.channels.discord.dm = config.channels.discord.dm || {};
    config.channels.discord.dm.policy = process.env.DISCORD_DM_POLICY || 'pairing';
}

// Slack configuration
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = config.channels.slack || {};
    config.channels.slack.botToken = process.env.SLACK_BOT_TOKEN;
    config.channels.slack.appToken = process.env.SLACK_APP_TOKEN;
    config.channels.slack.enabled = true;
}

// Anthropic Base URL override (e.g., for Cloudflare AI Gateway)
// Usage: Set ANTHROPIC_BASE_URL to your AI Gateway endpoint like:
//   https://gateway.ai.cloudflare.com/v1/{account_id}/{gateway_id}/anthropic
if (process.env.ANTHROPIC_BASE_URL) {
    console.log('Configuring custom Anthropic base URL:', process.env.ANTHROPIC_BASE_URL);
    config.models = config.models || {};
    config.models.providers = config.models.providers || {};
    const providerConfig = {
        baseUrl: process.env.ANTHROPIC_BASE_URL,
        api: 'anthropic-messages',
        models: [
            { id: 'claude-sonnet-4-20250514', name: 'Claude Sonnet 4', contextWindow: 200000 },
            { id: 'claude-opus-4-5-20251101', name: 'Claude Opus 4.5', contextWindow: 200000 },
            { id: 'claude-haiku-3-5-20241022', name: 'Claude Haiku 3.5', contextWindow: 200000 },
        ]
    };
    // Include API key in provider config if set (required when using custom baseUrl)
    if (process.env.ANTHROPIC_API_KEY) {
        providerConfig.apiKey = process.env.ANTHROPIC_API_KEY;
    }
    config.models.providers.anthropic = providerConfig;
}

// Write updated config
fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration updated successfully');
console.log('Config:', JSON.stringify(config, null, 2));
EOFNODE

# ============================================================
# START GATEWAY
# ============================================================
echo "Starting Moltbot Gateway..."
echo "Gateway will be available on port 18789"

# Clean up stale lock files
rm -f /tmp/clawdbot-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

BIND_MODE="lan"
echo "Dev mode: ${CLAWDBOT_DEV_MODE:-false}, Bind mode: $BIND_MODE"

if [ -n "$CLAWDBOT_GATEWAY_TOKEN" ]; then
    echo "Starting gateway with token auth..."
    exec clawdbot gateway --port 18789 --verbose --allow-unconfigured --bind "$BIND_MODE" --token "$CLAWDBOT_GATEWAY_TOKEN"
else
    echo "Starting gateway with device pairing (no token)..."
    exec clawdbot gateway --port 18789 --verbose --allow-unconfigured --bind "$BIND_MODE"
fi
