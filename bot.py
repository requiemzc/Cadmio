# run the bot
import os
import io
import sys
import asyncio
import tempfile
import subprocess
import re

import discord
from discord.ext import commands
from dotenv import load_dotenv
import aiohttp

load_dotenv()

TOKEN = os.getenv("DISCORD_TOKEN")
LUNE_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "catlog.luau")
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
STUFF_DIR = os.path.join(SCRIPT_DIR, "stuff")
API_DUMP = os.path.join(STUFF_DIR, "API-Dump.json")
CLASSES_JSON = os.path.join(STUFF_DIR, "classes.json")
ENUMS_JSON = os.path.join(STUFF_DIR, "enums.json")
ASSETIDS_JSON = os.path.join(STUFF_DIR, "assetids.json")
LUNE_BIN = os.getenv("LUNE_BIN", "lune")
TIMEOUT_SECONDS = 30

# .deobf: the full dynamic deobfuscator pipeline (deobf/deob.py). It detects
# the obfuscator (Luraph v15, Ironbrew1, ...) and lifts/traces the script in a
# real Luau VM against a fake Roblox environment (deobf/envlog.luau + plugins,
# used exactly as they ship). The whole input file goes in byte-exact and the
# complete deobfuscated file comes back.
DEOBF_SCRIPT = os.path.join(SCRIPT_DIR, "deobf", "deob.py")
DEOBF_TIMEOUT = int(os.getenv("DEOBF_TIMEOUT", "600"))

NO_MENTIONS = discord.AllowedMentions.none()

def sanitize_output(text: str) -> str:
    ZWSP = '\u200b'
    text = text.replace("@everyone", "@" + ZWSP + "everyone")
    text = text.replace("@here", "@" + ZWSP + "here")
    text = re.sub(r'<@&(\d+)>', lambda m: '<@&' + ZWSP + m.group(1) + '>', text)
    text = re.sub(r'<@!?(\d+)>', lambda m: '<@' + ZWSP + m.group(1) + '>', text)
    text = re.sub(r'<#(\d+)>', lambda m: '<#' + ZWSP + m.group(1) + '>', text)
    return text

intents = discord.Intents.default()
intents.message_content = True

bot = commands.Bot(command_prefix=".", intents=intents, help_command=None, allowed_mentions=discord.AllowedMentions.none())

URL_PATTERN = re.compile(r'https?://\S+')

async def download_from_url(url: str) -> str | None:
    if "github.com" in url and "/blob/" in url:
        url = url.replace("github.com", "raw.githubusercontent.com").replace("/blob/", "/")
    elif "pastebin.com" in url and "/raw/" not in url:
        paste_id = url.split("/")[-1]
        url = f"https://pastebin.com/raw/{paste_id}"

    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(url, timeout=10) as response:
                if response.status == 200:
                    return await response.text(errors="ignore")
    except Exception:
        return None
    return None

async def extract_code(ctx: commands.Context, content: str) -> str | None:
    if ctx.message.attachments:
        att = ctx.message.attachments[0]
        data = await att.read()
        return data.decode("utf-8", errors="ignore")

    if ctx.message.reference:
        try:
            ref_msg = await ctx.channel.fetch_message(ctx.message.reference.message_id)
        except discord.NotFound:
            ref_msg = None
        if ref_msg:
            if ref_msg.attachments:
                data = await ref_msg.attachments[0].read()
                return data.decode("utf-8", errors="ignore")
            if ref_msg.content:
                content = ref_msg.content + "\n" + content

    match = URL_PATTERN.search(content)
    if match:
        url = match.group(0)
        code = await download_from_url(url)
        if code:
            return code

    if "```" in content:
        parts = content.split("```")
        if len(parts) >= 2:
            block = parts[1]
            first_line, _, rest = block.partition("\n")
            if first_line.strip().isalpha():
                return rest
            return block

    return None


def safe_filename(name: str, default: str = "input.lua") -> str:
    """A name safe to use as a temp-file basename (keeps the extension)."""
    name = os.path.basename((name or "").strip()).replace("\\", "/").split("/")[-1]
    name = re.sub(r"[^\w.\- ]+", "_", name)[:80].strip(". ")
    return name or default


async def extract_file(ctx: commands.Context, content: str) -> tuple[bytes | None, str]:
    """(bytes, filename) of the script to process: the attachment's exact
    bytes when there is one (or a replied-to one), else the extracted text."""
    if ctx.message.attachments:
        att = ctx.message.attachments[0]
        return await att.read(), att.filename

    if ctx.message.reference:
        try:
            ref_msg = await ctx.channel.fetch_message(ctx.message.reference.message_id)
        except discord.NotFound:
            ref_msg = None
        if ref_msg:
            if ref_msg.attachments:
                att = ref_msg.attachments[0]
                return await att.read(), att.filename

    code = await extract_code(ctx, content)   # link / ```lua block / replied text
    if code:
        return code.encode("utf-8"), "input.lua"
    return None, ""


def run_deobf(data: bytes, filename: str) -> tuple[bool, bytes | str, str]:
    """Run the full deobfuscator pipeline on the exact bytes of `filename`.

    Returns (ok, result, info): on success `result` is the COMPLETE
    deobfuscated file (raw bytes, nothing filtered), on failure the error
    text; `info` holds the pipeline's progress output (obfuscator detection,
    ...). Comments, markdown, whatever the file contains goes in as-is.
    """
    with tempfile.TemporaryDirectory() as tmp:
        input_path = os.path.join(tmp, safe_filename(filename))
        out_path = os.path.join(tmp, "deobfuscated.lua")

        with open(input_path, "wb") as f:      # byte-exact: no re-encoding
            f.write(data)

        cmd = [sys.executable, DEOBF_SCRIPT, input_path, "-o", out_path]
        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=DEOBF_TIMEOUT,
                cwd=tmp,
            )
        except FileNotFoundError:
            return False, "Could not find Python to run the pipeline.", ""
        except subprocess.TimeoutExpired:
            return False, f"exceeded the time limit ({DEOBF_TIMEOUT}s).", ""

        info = ((proc.stderr or "") + (proc.stdout or "")).strip()

        if proc.returncode == 0 and os.path.exists(out_path):
            with open(out_path, "rb") as f:    # the whole result file, exact
                return True, f.read(), info

        err = info or f"pipeline exited with code {proc.returncode}"
        return False, err[-1900:], info


def run_lune(code: str) -> tuple[bool, str]:
    with tempfile.TemporaryDirectory() as tmp:
        input_path = os.path.join(tmp, "input.lua")
        output_path = os.path.join(tmp, "out.lua")

        with open(input_path, "w", encoding="utf-8") as f:
            f.write(code)

        cmd = [
            LUNE_BIN,
            "run",
            LUNE_SCRIPT,
            "--",
            input_path,
            f"out={output_path}",
            f"api_dump={API_DUMP}",
        ]

        # Pass the optional stuff/ files if they exist on disk. catlog.luau
        # falls back to its built-in lookup if these are omitted, but passing
        # them explicitly mirrors how api_dump is handled and lets the user
        # override them by editing the paths below.
        if os.path.isfile(CLASSES_JSON):
            cmd.append(f"classes={CLASSES_JSON}")
        if os.path.isfile(ENUMS_JSON):
            cmd.append(f"enums={ENUMS_JSON}")
        if os.path.isfile(ASSETIDS_JSON):
            cmd.append(f"assetids={ASSETIDS_JSON}")

        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=TIMEOUT_SECONDS,
                cwd=tmp,
            )
        except FileNotFoundError:
            return False, "Could not find the lune executable. Set LUNE_BIN in your .env."
        except subprocess.TimeoutExpired:
            return False, "exceeded the time limit."

        if proc.returncode != 0 and not os.path.exists(output_path):
            err = (proc.stderr or proc.stdout or "Unknown error").strip()
            return False, err[:1900]

        if os.path.exists(output_path):
            with open(output_path, "r", encoding="utf-8", errors="ignore") as f:
                return True, f.read()

        return False, (proc.stdout or "No output.").strip()[:1900]


@bot.command(name="l")
async def analyze(ctx: commands.Context, *, text: str = ""):
    code = await extract_code(ctx, text)

    if not code or not code.strip():
        await ctx.reply(
            "Attach a .lua/.luau file, reply to a message that has one, "
            "put the code in a ```lua ... ``` code block, or provide a valid code link.",
            allowed_mentions=NO_MENTIONS
        )
        return

    async with ctx.typing():
        loop = asyncio.get_running_loop()
        ok, result = await loop.run_in_executor(None, run_lune, code)

    result = sanitize_output(result)

    if not ok:
        await ctx.reply(f"Error:\n```\n{result}\n```", allowed_mentions=NO_MENTIONS)
        return

    if len(result) > 1900:
        file = discord.File(io.BytesIO(result.encode("utf-8")), filename="result.lua")
        await ctx.reply("done, attached file:", file=file, allowed_mentions=NO_MENTIONS)
    else:
        await ctx.reply(f"Result:\n```lua\n{result}\n```", allowed_mentions=NO_MENTIONS)


@bot.command(name="deobf")
async def deobf(ctx: commands.Context, *, text: str = ""):
    """Deobfuscate a protected Roblox script with the full pipeline.

    Exactly all of the file goes in (attach it, reply to it, link it or paste
    it in a ```lua block; comments/markdown included, nothing is filtered) and
    the complete deobfuscated file comes back as an attachment.
    """
    if not os.path.isfile(DEOBF_SCRIPT):
        await ctx.reply("deobf/deob.py not found next to bot.py.", allowed_mentions=NO_MENTIONS)
        return

    data, filename = await extract_file(ctx, text)

    if not data or not data.strip():
        await ctx.reply(
            "Attach a .lua/.luau file, reply to a message that has one, "
            "put the code in a ```lua ... ``` code block, or provide a valid code link.",
            allowed_mentions=NO_MENTIONS
        )
        return

    async with ctx.typing():
        loop = asyncio.get_running_loop()
        ok, result, info = await loop.run_in_executor(None, run_deobf, data, filename)

    if not ok:
        result = sanitize_output(result)
        await ctx.reply(f"Error:\n```\n{result}\n```", allowed_mentions=NO_MENTIONS)
        return

    detect = re.search(r"\[\*\] obfuscator: ([^\n]+)", info)
    detected = detect.group(1).strip() if detect else "unknown obfuscator"

    base = re.sub(r"(\.lua|\.luau|\.txt)?$", "", safe_filename(filename), count=1)
    out_name = (base or "input") + "_deobf.lua"

    file = discord.File(io.BytesIO(result), filename=out_name)
    preview = result.decode("utf-8", "ignore")

    msg = f"done ({detected}, {len(result):,} bytes)"
    if len(preview) <= 1500:
        preview = sanitize_output(preview)
        await ctx.reply(f"{msg}:\n```lua\n{preview}\n```", file=file,
                        allowed_mentions=NO_MENTIONS)
    else:
        await ctx.reply(f"{msg}, attached file:", file=file, allowed_mentions=NO_MENTIONS)


@bot.event
async def on_ready():
    print(f"Logged in as {bot.user} (ID: {bot.user.id})")


if __name__ == "__main__":
    if not TOKEN:
        raise SystemExit("Missing DISCORD_TOKEN in the .env file")
    bot.run(TOKEN)
