import argparse
import asyncio
import json
import os
from pathlib import Path
import re
import ssl
from typing import Optional

import certifi
import websockets

MODEL = "gpt-realtime-mini-2025-10-06"
CONFIG_PATH = Path("Moment/Moment/Config/Secrets.local.xcconfig")


def load_api_key() -> str:
    api_key = os.getenv("OPENAI_API_KEY")
    if api_key:
        return api_key.strip()

    if CONFIG_PATH.exists():
        text = CONFIG_PATH.read_text(encoding="utf-8")
        match = re.search(r"OPENAI_API_KEY\\s*=\\s*(.+)", text)
        if match:
            return match.group(1).strip()

    raise RuntimeError("OPENAI_API_KEY not found. Set env var or Secrets.local.xcconfig.")


def build_ssl_context(insecure: bool) -> ssl.SSLContext:
    context = ssl.create_default_context(cafile=certifi.where())
    if insecure:
        print("[warn] SSL verification disabled for debug purposes.")
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
    return context


async def run_session(proxy: Optional[str], insecure: bool) -> None:
    headers = {
        "Authorization": f"Bearer {load_api_key()}",
        "OpenAI-Beta": "realtime=v1",
    }
    uri = f"wss://api.openai.com/v1/realtime?model={MODEL}"
    print(f"Connecting to {MODEL} ...")
    if proxy:
        print(f"Using proxy: {proxy}")
    else:
        print("Proxy: none (direct connection)")

    ssl_context = build_ssl_context(insecure)

    async with websockets.connect(
        uri,
        additional_headers=headers,
        ping_interval=None,
        proxy=proxy,
        open_timeout=30,
        ssl=ssl_context,
    ) as ws:
        await ws.send(
            json.dumps(
                {
                    "type": "session.update",
                    "session": {
                        "modalities": ["text"],
                        "instructions": "You are a cheerful speaking coach helping me verbalize existing notes.",
                    },
                }
            )
        )
        print("Session update sent.")

        await ws.send(
            json.dumps(
                {
                    "type": "response.create",
                    "response": {
                        "modalities": ["text"],
                        "instructions": "Give me a short warm-up question about product strategy.",
                    },
                }
            )
        )
        print("Prompt request sent, awaiting stream ...")

        transcript: list[str] = []
        while True:
            data = json.loads(await ws.recv())
            event_type = data.get("type")
            if event_type == "session.updated":
                print("Session updated ack received.")
            elif event_type == "response.output_text.delta":
                transcript.append(data.get("delta", ""))
            elif event_type == "response.completed":
                print("Response completed:")
                print("".join(transcript))
                break
            elif event_type == "error":
                print("Server error:", data)
                break


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Test OpenAI Realtime connectivity.")
    parser.add_argument(
        "--proxy",
        default=os.getenv("HTTPS_PROXY") or os.getenv("ALL_PROXY"),
        help="Optional HTTP/HTTPS proxy, e.g. http://127.0.0.1:7890",
    )
    parser.add_argument(
        "--insecure",
        action="store_true",
        help="Skip TLS verification (only for debugging when intercepting proxies).",
    )
    return parser.parse_args()


if __name__ == "__main__":
    arguments = parse_args()
    try:
        asyncio.run(run_session(arguments.proxy, arguments.insecure))
    except KeyboardInterrupt:
        print("Cancelled by user.")

