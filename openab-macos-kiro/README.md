# OpenAB + Kiro CLI Agent — macOS Native Setup

Run an OpenAB agent with Kiro CLI natively on macOS (no Docker required). Works on legacy Macs.

## One-Line Install

```bash
curl -fsSL https://raw.githubusercontent.com/juntinyeh-worker/agent-outbound/openab-macos-kiro/openab-macos-kiro/install.sh | bash
```

## What It Does

1. Installs Homebrew (if missing)
2. Installs Rust, gh CLI, git, gettext via Homebrew
3. Installs Kiro CLI (`curl https://cli.kiro.dev/install | bash`)
4. Builds `openab` binary from source via Cargo
5. Downloads config files to `~/openab-agent`

## After Install

```bash
# 1. Authenticate Kiro CLI (one-time, opens browser)
kiro-cli login

# 2. Configure
cd ~/openab-agent
vim .env    # set DISCORD_BOT_TOKEN and DISCORD_CHANNEL_ID

# 3. Run
./start.sh
```

## Operations

```bash
./start.sh                    # start agent (background)
./stop.sh                     # stop agent
tail -f ~/openab-agent/openab.log  # view logs
```

## Requirements

- macOS 10.15+ (Catalina or newer for Homebrew)
- 1 Discord bot token
- Internet access for Kiro CLI auth + API calls

## File Structure

```
~/openab-agent/
├── config.toml          # agent config template
├── config.rendered.toml # rendered with actual values (gitignored)
├── .env                 # your secrets
├── start.sh             # launch agent
├── stop.sh              # stop agent
└── openab.log           # runtime logs
```
