"""Run interactively once to create a Telethon StringSession.

Usage: TELEGRAM_API_ID=... TELEGRAM_API_HASH=... python scripts_create_telegram_session.py
Keep the printed session string private. Never commit it to Git.
"""
import asyncio
import os
from telethon import TelegramClient
from telethon.sessions import StringSession

async def main():
    api_id = int(os.environ["TELEGRAM_API_ID"])
    api_hash = os.environ["TELEGRAM_API_HASH"]
    async with TelegramClient(StringSession(), api_id, api_hash) as client:
        print("\nTELEGRAM_SESSION=" + client.session.save())
        print("\nCopy this value into the backend environment. Do not share it.\n")

if __name__ == "__main__":
    asyncio.run(main())
