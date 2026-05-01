#!/usr/bin/env python3
"""
setup-discord.py — Automate Discord bot creation using AgentCore Browser + Nova Act

Creates 6 Discord bot applications (PM, Architect, Dev, QA, CloudOps, Auditor),
enables required intents, captures bot tokens, and invites them to your server.

Outputs a .env file with all bot tokens pre-filled.

Requirements:
    pip install -r requirements.txt

Usage:
    python setup-discord.py
    python setup-discord.py --roles pm architect dev   # subset of roles
    python setup-discord.py --headless                 # no live view
"""

import asyncio
import json
import os
import sys
import time
from pathlib import Path

from dotenv import load_dotenv
from nova_act import NovaAct
from rich.console import Console
from rich.table import Table

console = Console()

# ── Role definitions ──────────────────────────────────────────────
ROLES = {
    "pm":        {"name": "Team-PM",        "description": "Project Manager agent"},
    "architect": {"name": "Team-Architect",  "description": "Architect agent"},
    "dev":       {"name": "Team-Dev",        "description": "Full-Stack Developer agent"},
    "qa":        {"name": "Team-QA",         "description": "QA Engineer agent"},
    "cloudops":  {"name": "Team-CloudOps",   "description": "CloudOps Engineer agent"},
    "auditor":   {"name": "Team-Auditor",    "description": "Compliance Auditor agent"},
}

# Bot permissions: Send Messages, Send in Threads, Create Threads,
# Read History, Add Reactions, Manage Messages
BOT_PERMISSIONS = "397284550656"


def load_config():
    """Load configuration from .env file."""
    load_dotenv()
    config = {
        "discord_email": os.getenv("DISCORD_EMAIL"),
        "discord_password": os.getenv("DISCORD_PASSWORD"),
        "discord_server_id": os.getenv("DISCORD_SERVER_ID"),
        "nova_act_api_key": os.getenv("NOVA_ACT_API_KEY"),
        "aws_region": os.getenv("AWS_REGION", "us-west-2"),
        "team_prefix": os.getenv("TEAM_PREFIX", "Team"),
    }
    missing = [k for k in ["discord_email", "discord_password", "discord_server_id", "nova_act_api_key"]
               if not config[k]]
    if missing:
        console.print(f"[red]Missing required .env vars: {', '.join(missing)}[/red]")
        console.print("Copy .env.example to .env and fill in your values.")
        sys.exit(1)
    return config


async def login_to_discord(act: NovaAct, email: str, password: str):
    """Login to Discord Developer Portal."""
    console.print("[bold]Logging in to Discord Developer Portal...[/bold]")

    await act.execute("Navigate to https://discord.com/developers/applications")
    await asyncio.sleep(2)

    # Check if already logged in
    result = await act.execute(
        "Check if the page shows a list of applications or a 'New Application' button. "
        "If yes, respond with 'logged_in'. If it shows a login form, respond with 'need_login'."
    )

    if "need_login" in str(result).lower():
        await act.execute(f'Type "{email}" into the email input field')
        await act.execute(f'Type "{password}" into the password input field')
        await act.execute("Click the Login button")
        await asyncio.sleep(3)

        # Handle potential 2FA
        result = await act.execute(
            "Check if there is a 2FA/MFA code input field on the page. "
            "If yes, respond with 'need_2fa'. Otherwise respond with 'logged_in'."
        )
        if "need_2fa" in str(result).lower():
            console.print("[yellow]2FA required. Please enter your code in the browser live view.[/yellow]")
            console.print("[yellow]Waiting 30 seconds for 2FA...[/yellow]")
            await asyncio.sleep(30)

    console.print("[green]✓ Logged in to Discord Developer Portal[/green]")


async def create_bot_application(act: NovaAct, app_name: str, description: str) -> dict:
    """Create a single Discord application and bot, return app_id and bot_token."""
    console.print(f"[bold]Creating application: {app_name}[/bold]")

    # Navigate to applications page
    await act.execute("Navigate to https://discord.com/developers/applications")
    await asyncio.sleep(2)

    # Create new application
    await act.execute("Click the 'New Application' button")
    await asyncio.sleep(1)
    await act.execute(f'Type "{app_name}" into the application name input field')
    await act.execute("Check the checkbox to agree to the Developer Terms of Service and Developer Policy if present")
    await act.execute("Click the 'Create' button to create the application")
    await asyncio.sleep(2)

    # Get application/client ID from URL
    result = await act.execute(
        "Look at the current page URL or the APPLICATION ID field on the page. "
        "Return ONLY the numeric application ID, nothing else."
    )
    app_id = "".join(c for c in str(result) if c.isdigit())

    # Set description
    await act.execute(f'Find the description text area and type "{description}"')
    await act.execute("Click the 'Save Changes' button if visible")
    await asyncio.sleep(1)

    # Enable Bot
    await act.execute("Click on 'Bot' in the left sidebar navigation")
    await asyncio.sleep(2)

    # Enable intents
    await act.execute(
        "Scroll down to the 'Privileged Gateway Intents' section. "
        "Enable the 'MESSAGE CONTENT INTENT' toggle if it is not already enabled."
    )
    await asyncio.sleep(1)
    await act.execute(
        "Enable the 'SERVER MEMBERS INTENT' toggle if it is not already enabled."
    )
    await act.execute("Click the 'Save Changes' button if visible")
    await asyncio.sleep(1)

    # Reset/get bot token
    await act.execute("Scroll up to the top of the Bot page")
    await asyncio.sleep(1)
    await act.execute("Click the 'Reset Token' button")
    await asyncio.sleep(1)
    await act.execute("If there is a confirmation dialog, click 'Yes, do it!' to confirm")
    await asyncio.sleep(2)

    # Capture the token
    result = await act.execute(
        "Find the bot token that was just generated. It should be visible on the page "
        "as a long string. Click the 'Copy' button next to it if available, "
        "or read the token value. Return ONLY the token string, nothing else."
    )
    bot_token = str(result).strip().strip('"').strip("'")

    console.print(f"[green]✓ Created {app_name} (ID: {app_id})[/green]")

    return {"app_id": app_id, "bot_token": bot_token, "name": app_name}


async def generate_invite_and_add_to_server(act: NovaAct, app_id: str, server_id: str, app_name: str):
    """Generate OAuth2 invite URL and add bot to server."""
    console.print(f"[bold]Inviting {app_name} to server...[/bold]")

    invite_url = (
        f"https://discord.com/oauth2/authorize"
        f"?client_id={app_id}"
        f"&permissions={BOT_PERMISSIONS}"
        f"&scope=bot"
        f"&guild_id={server_id}"
    )

    await act.execute(f"Navigate to {invite_url}")
    await asyncio.sleep(2)

    await act.execute(
        "On the authorization page, there should be a server selector dropdown. "
        "Make sure the correct server is selected, then click the 'Authorize' button."
    )
    await asyncio.sleep(2)

    # Handle captcha if present
    result = await act.execute(
        "Check if there is a CAPTCHA challenge on the page. "
        "If yes, respond with 'captcha'. If the page shows 'Authorized' or success, respond with 'done'."
    )
    if "captcha" in str(result).lower():
        console.print(f"[yellow]CAPTCHA detected for {app_name}. Please solve it in the live view.[/yellow]")
        await asyncio.sleep(20)

    console.print(f"[green]✓ {app_name} added to server[/green]")


async def create_channel_via_api(bot_token: str, server_id: str, channel_name: str = "team-agents") -> str:
    """Create a Discord channel using the REST API with one of the bot tokens."""
    import aiohttp

    url = f"https://discord.com/api/v10/guilds/{server_id}/channels"
    headers = {
        "Authorization": f"Bot {bot_token}",
        "Content-Type": "application/json",
    }
    payload = {
        "name": channel_name,
        "type": 0,  # text channel
        "topic": "OpenAB Software Team — multi-role agent collaboration channel",
    }

    async with aiohttp.ClientSession() as session:
        async with session.post(url, headers=headers, json=payload) as resp:
            if resp.status == 201:
                data = await resp.json()
                return data["id"]
            elif resp.status == 403:
                console.print(f"[yellow]Bot lacks MANAGE_CHANNELS permission. Create #{channel_name} manually.[/yellow]")
                return ""
            else:
                body = await resp.text()
                console.print(f"[yellow]Channel creation returned {resp.status}: {body}[/yellow]")
                return ""


def write_env_file(config: dict, bots: dict, channel_id: str):
    """Write the .env file with all discovered values."""
    env_path = Path(".env")

    # Preserve existing values
    existing = {}
    if env_path.exists():
        for line in env_path.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                existing[k.strip()] = v.strip()

    # Merge
    existing["AWS_REGION"] = existing.get("AWS_REGION", config["aws_region"])
    existing["CLUSTER_NAME"] = existing.get("CLUSTER_NAME", "openab-team")
    existing["KIRO_API_KEY"] = existing.get("KIRO_API_KEY", "")
    existing["GH_TOKEN"] = existing.get("GH_TOKEN", "")
    existing["DISCORD_SERVER_ID"] = config["discord_server_id"]

    if channel_id:
        existing["DISCORD_CHANNEL_ID"] = channel_id

    for role_key, bot_info in bots.items():
        env_key = f"BOT_TOKEN_{role_key.upper()}"
        existing[env_key] = bot_info["bot_token"]

    # Write
    lines = [
        "# ============================================================================",
        "# OpenAB Software Team — Auto-generated by setup-discord.py",
        "# ============================================================================",
        "",
        "# --- AWS ---",
        f"AWS_REGION={existing.get('AWS_REGION', 'us-east-1')}",
        f"CLUSTER_NAME={existing.get('CLUSTER_NAME', 'openab-team')}",
        f"NODE_INSTANCE_TYPE={existing.get('NODE_INSTANCE_TYPE', 't3.large')}",
        f"NODE_COUNT={existing.get('NODE_COUNT', '2')}",
        "",
        "# --- Discord ---",
        f"DISCORD_CHANNEL_ID={existing.get('DISCORD_CHANNEL_ID', '')}",
        f"DISCORD_SERVER_ID={existing.get('DISCORD_SERVER_ID', '')}",
        "",
        "# --- Kiro CLI ---",
        f"KIRO_API_KEY={existing.get('KIRO_API_KEY', '')}",
        "",
        "# --- GitHub (optional) ---",
        f"GH_TOKEN={existing.get('GH_TOKEN', '')}",
        "",
        "# --- Discord Bot Tokens (auto-generated) ---",
    ]
    for role_key in ROLES:
        env_key = f"BOT_TOKEN_{role_key.upper()}"
        lines.append(f"{env_key}={existing.get(env_key, '')}")

    env_path.write_text("\n".join(lines) + "\n")
    console.print(f"[green]✓ .env updated with all bot tokens[/green]")


def print_summary(bots: dict, channel_id: str):
    """Print a summary table of created bots."""
    table = Table(title="Discord Bots Created")
    table.add_column("Role", style="cyan")
    table.add_column("Bot Name", style="green")
    table.add_column("App ID")
    table.add_column("Token", style="dim")

    for role_key, bot_info in bots.items():
        token_preview = bot_info["bot_token"][:20] + "..." if len(bot_info["bot_token"]) > 20 else "(empty)"
        table.add_row(role_key, bot_info["name"], bot_info["app_id"], token_preview)

    console.print(table)
    if channel_id:
        console.print(f"\nChannel ID: [bold]{channel_id}[/bold]")
    console.print("\n[bold green]All tokens saved to .env[/bold green]")
    console.print("Next step: fill in KIRO_API_KEY in .env, then run ./quickstart.sh")


async def main():
    import argparse

    parser = argparse.ArgumentParser(description="Setup Discord bots for OpenAB team")
    parser.add_argument("--roles", nargs="+", choices=list(ROLES.keys()),
                        default=list(ROLES.keys()), help="Roles to create (default: all)")
    parser.add_argument("--skip-invite", action="store_true", help="Skip server invite step")
    parser.add_argument("--skip-channel", action="store_true", help="Skip channel creation")
    parser.add_argument("--channel-name", default="team-agents", help="Channel name to create")
    args = parser.parse_args()

    config = load_config()
    roles_to_create = {k: ROLES[k] for k in args.roles}

    # Apply team prefix
    prefix = config["team_prefix"]
    for role_key, role_info in roles_to_create.items():
        role_info["name"] = f"{prefix}-{role_key.capitalize()}"

    console.print(f"[bold]Creating {len(roles_to_create)} Discord bots using AgentCore Browser + Nova Act[/bold]")
    console.print(f"Region: {config['aws_region']}")
    console.print(f"Roles: {', '.join(roles_to_create.keys())}")
    console.print()

    bots = {}

    # Use Nova Act with AgentCore Browser
    starting_url = "https://discord.com/developers/applications"

    async with NovaAct(
        starting_page=starting_url,
        api_key=config["nova_act_api_key"],
        browser_config={"region": config["aws_region"]},
    ) as act:
        # Step 1: Login
        await login_to_discord(act, config["discord_email"], config["discord_password"])

        # Step 2: Create each bot
        for role_key, role_info in roles_to_create.items():
            try:
                bot_info = await create_bot_application(
                    act, role_info["name"], role_info["description"]
                )
                bots[role_key] = bot_info
                console.print(f"[green]✓ {role_key} done[/green]\n")
                await asyncio.sleep(2)  # rate limit buffer
            except Exception as e:
                console.print(f"[red]✗ Failed to create {role_key}: {e}[/red]")
                bots[role_key] = {"app_id": "", "bot_token": "", "name": role_info["name"]}

        # Step 3: Invite bots to server
        if not args.skip_invite:
            for role_key, bot_info in bots.items():
                if bot_info["app_id"]:
                    try:
                        await generate_invite_and_add_to_server(
                            act, bot_info["app_id"],
                            config["discord_server_id"], bot_info["name"]
                        )
                        await asyncio.sleep(2)
                    except Exception as e:
                        console.print(f"[red]✗ Failed to invite {role_key}: {e}[/red]")

    # Step 4: Create channel (via REST API, outside browser session)
    channel_id = ""
    if not args.skip_channel:
        first_token = next((b["bot_token"] for b in bots.values() if b["bot_token"]), "")
        if first_token:
            channel_id = await create_channel_via_api(
                first_token, config["discord_server_id"], args.channel_name
            )

    # Step 5: Write .env and print summary
    write_env_file(config, bots, channel_id)
    print_summary(bots, channel_id)


if __name__ == "__main__":
    asyncio.run(main())
