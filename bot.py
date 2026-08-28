# run the bot
import os
import io
import asyncio
import tempfile
import subprocess
import re
import sys

import discord
from discord.ext import commands
from dotenv import load_dotenv
import aiohttp

# Make the cadmio_postproc module importable whether the bot is run from
# its own directory or from elsewhere. cadmio_postproc.py provides:
#   - minify_lua()          : strip comments + redundant whitespace
#   - cadmio_lz_compress()  : LZSS-style compression (pure-Luau decodeable)
#   - zstd_raw_wrap()       : wrap in a real zstd frame (raw blocks only)
#   - build_bootstrap()     : full pipeline -> self-contained Lua bootstrap
#                            with inline base64 + zstd raw + Cadmio-LZ decoders
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)
import cadmio_postproc

load_dotenv()

TOKEN = os.getenv("DISCORD_TOKEN")
LUNE_SCRIPT = os.path.join(_SCRIPT_DIR, "catlog.luau")
STUFF_DIR = os.path.join(_SCRIPT_DIR, "stuff")
API_DUMP = os.path.join(STUFF_DIR, "API-Dump.json")
CLASSES_JSON = os.path.join(STUFF_DIR, "classes.json")
ENUMS_JSON = os.path.join(STUFF_DIR, "enums.json")
ASSETIDS_JSON = os.path.join(STUFF_DIR, "assetids.json")
LUNE_BIN = os.getenv("LUNE_BIN", "lune")
TIMEOUT_SECONDS = 30

# Always-on post-processing pipeline:
#   catlog output -> minify -> Cadmio-LZ compress -> zstd raw-frame wrap
#                  -> base64 -> embed in self-contained Lua bootstrap.
# The bootstrap decodes everything at runtime using only bit32 / string /
# table ops — no executor zstd API needed, no RC4, no external files.
# It is fully Roblox/Delta compatible.
POSTPROC_ALWAYS_ON = True  # set to False to disable (debugging only)

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


def run_lune(code: str) -> tuple[bool, str]:
    """Run catlog.luau on `code` via lune, returning (success, output_or_error)."""
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


def postprocess(obfuscated_lua: str) -> tuple[bool, str]:
    """
    Apply the always-on Cadmio post-processing pipeline:
        minify -> Cadmio-LZ compress -> zstd raw-frame wrap -> base64
        -> embed in self-contained Lua bootstrap with inline decoders.

    Returns (success, final_lua_or_error_message).
    """
    try:
        bootstrap = cadmio_postproc.build_bootstrap(obfuscated_lua)
        return True, bootstrap
    except Exception as exc:
        # If post-processing fails, fall back to the raw obfuscated output so
        # the user still gets something usable. We surface the error in a
        # trailing comment so it's visible but doesn't break execution.
        err_msg = f"-- [Cadmio postproc fallback] zstd/minify pipeline failed: {exc!r}\n"
        return False, err_msg + obfuscated_lua


@bot.command(name="l")
async def analyze(ctx: commands.Context, *, text: str = ""):
    """
    Obfuscate the given Lua/Luau source.

    Accepts: file attachment, replied message, ```lua``` code block, or URL.
    Pipeline (always on):
        catlog obfuscate  ->  minify  ->  Cadmio-LZ compress
                          ->  zstd raw-frame wrap  ->  base64
                          ->  self-contained Lua bootstrap (run-ready in
                              Roblox/Delta, no executor zstd API required)
    """
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

        if not ok:
            result = sanitize_output(result)
            await ctx.reply(f"Error:\n```\n{result}\n```", allowed_mentions=NO_MENTIONS)
            return

        # Always-on minify + zstd-wrap integration
        if POSTPROC_ALWAYS_ON:
            ok_pp, final_result = await loop.run_in_executor(None, postprocess, result)
            if not ok_pp:
                # Postproc fell back to raw obfuscated output (with a comment
                # explaining the failure). Still deliver something usable.
                pass
            result = final_result

    result = sanitize_output(result)

    if len(result) > 1900:
        file = discord.File(io.BytesIO(result.encode("utf-8")), filename="result.lua")
        await ctx.reply("done, attached file:", file=file, allowed_mentions=NO_MENTIONS)
    else:
        await ctx.reply(f"Result:\n```lua\n{result}\n```", allowed_mentions=NO_MENTIONS)


@bot.event
async def on_ready():
    print(f"Logged in as {bot.user} (ID: {bot.user.id})")
    if POSTPROC_ALWAYS_ON:
        print("[Cadmio] post-processing pipeline (minify + Cadmio-LZ + zstd raw-frame + base64 bootstrap) is ALWAYS ON for .l")


if __name__ == "__main__":
    if not TOKEN:
        raise SystemExit("Missing DISCORD_TOKEN in the .env file")
    bot.run(TOKEN)
