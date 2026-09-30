#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 GPSSpoofer contributors
"""
iPhone 定位模擬後端（給 macOS App 呼叫）。

協定：stdin / stdout 逐行 JSON。
  請求: {"id": 1, "cmd": "list"}
        {"id": 2, "cmd": "connect", "udid": "..."}
        {"id": 3, "cmd": "set", "lat": 25.03, "lon": 121.56}
        {"id": 4, "cmd": "clear"}
        {"id": 5, "cmd": "disconnect"}
  回應: {"id": 1, "ok": true, "result": ...} 或 {"id": 1, "ok": false, "error": "..."}

iOS 17+ 的 DVT 定位模擬在連線關閉時就會失效，所以這個程序會一直保持連線，
直到收到 disconnect 或 stdin 關閉。
"""

import asyncio
import contextlib
import json
import logging
import platform
import sys
from typing import Any, Optional

from packaging.version import Version

from pymobiledevice3 import usbmux
from pymobiledevice3.exceptions import AlreadyMountedError, UserspaceTunnelUnavailableError
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation
from pymobiledevice3.services.mobile_image_mounter import auto_mount
from pymobiledevice3.services.simulate_location import DtSimulateLocation

logging.basicConfig(stream=sys.stderr, level=logging.INFO, format="[helper] %(levelname)s %(message)s")
logger = logging.getLogger("location_helper")

IOS_17 = Version("17.0")


async def list_devices() -> list[dict[str, Any]]:
    devices = []
    seen = set()
    for mux_device in await usbmux.list_devices():
        if mux_device.serial in seen:
            continue
        seen.add(mux_device.serial)
        entry = {"udid": mux_device.serial, "connection": mux_device.connection_type}
        try:
            lockdown = await create_using_usbmux(serial=mux_device.serial, autopair=False)
            try:
                entry["name"] = lockdown.display_name or await lockdown.get_value(key="DeviceName")
                entry["version"] = lockdown.product_version
            finally:
                await lockdown.close()
        except Exception as e:  # 裝置未信任、鎖定等狀況仍列出，讓使用者知道有接上
            entry["name"] = "(無法讀取)"
            entry["version"] = ""
            entry["error"] = str(e)
        devices.append(entry)
    return devices


async def open_tunnel(stack: contextlib.AsyncExitStack, udid: str):
    """依序嘗試：macOS native tunnel → userspace tunnel → tunneld，前兩者都不需要 root。

    native 優先：userspace tunnel 在較新的 iOS 上傳 cryptex DDI 時會被 cryptexd 中斷。
    """
    if platform.system() == "Darwin":
        from pymobiledevice3.remote.native_tunnel import NativeRemotedTunnel

        try:
            return await stack.enter_async_context(NativeRemotedTunnel(serial=udid))
        except Exception as e:
            logger.info("native tunnel 不可用（%r），改用 userspace tunnel", e)

    from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel

    try:
        return await stack.enter_async_context(UserspaceRsdTunnel(serial=udid))
    except UserspaceTunnelUnavailableError as e:
        logger.info("userspace tunnel 不可用（%s），改用 tunneld", e)

    from pymobiledevice3.tunneld.api import get_tunneld_devices

    rsds = await get_tunneld_devices()
    chosen = None
    for rsd in rsds:
        if rsd.udid == udid and chosen is None:
            chosen = rsd
        else:
            await rsd.close()
    if chosen is None:
        raise RuntimeError("找不到可用的 tunnel，請先執行 scripts/start_tunneld.sh")
    stack.push_async_callback(chosen.close)
    return chosen


async def mount_developer_image(lockdown) -> None:
    try:
        await auto_mount(lockdown)
        logger.info("Developer Disk Image 掛載完成")
    except AlreadyMountedError:
        pass


class Session:
    def __init__(self) -> None:
        self.stack: Optional[contextlib.AsyncExitStack] = None
        self.simulator = None
        self.udid: Optional[str] = None
        self.version: Optional[str] = None

    async def connect(self, udid: str) -> dict[str, Any]:
        await self.disconnect()
        stack = contextlib.AsyncExitStack()
        try:
            lockdown = await create_using_usbmux(serial=udid)
            stack.push_async_callback(lockdown.close)
            version = lockdown.product_version

            if Version(version) >= IOS_17:
                # iOS 17+ 的 personalized DDI（cryptex）只能透過 RSD tunnel 掛載
                rsd = await open_tunnel(stack, udid)
                await mount_developer_image(rsd)
                dvt = await stack.enter_async_context(DvtProvider(rsd))
                simulator = await stack.enter_async_context(LocationSimulation(dvt))
            else:
                await mount_developer_image(lockdown)
                simulator = DtSimulateLocation(lockdown)
        except BaseException:
            await stack.aclose()
            raise

        self.stack, self.simulator, self.udid, self.version = stack, simulator, udid, version
        return {"udid": udid, "version": version}

    async def disconnect(self) -> None:
        if self.stack is not None:
            with contextlib.suppress(Exception):
                await self.stack.aclose()
        self.stack = self.simulator = self.udid = self.version = None

    def _require(self):
        if self.simulator is None:
            raise RuntimeError("尚未連線到裝置")
        return self.simulator

    async def set(self, lat: float, lon: float) -> None:
        if not (-90 <= lat <= 90 and -180 <= lon <= 180):
            raise ValueError("經緯度超出範圍")
        await self._require().set(lat, lon)

    async def clear(self) -> None:
        await self._require().clear()


async def handle(session: Session, request: dict[str, Any]) -> Any:
    cmd = request.get("cmd")
    if cmd == "list":
        return await list_devices()
    if cmd == "connect":
        return await session.connect(request["udid"])
    if cmd == "set":
        await session.set(float(request["lat"]), float(request["lon"]))
        return None
    if cmd == "clear":
        await session.clear()
        return None
    if cmd == "disconnect":
        await session.disconnect()
        return None
    raise ValueError(f"未知的指令: {cmd}")


def reply(payload: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


async def main() -> None:
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader()
    await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)

    session = Session()
    reply({"event": "ready"})
    try:
        while line := await reader.readline():
            line = line.strip()
            if not line:
                continue
            request_id = None
            try:
                request = json.loads(line)
                request_id = request.get("id")
                result = await handle(session, request)
                reply({"id": request_id, "ok": True, "result": result})
            except Exception as e:
                logger.exception("指令失敗")
                reply({"id": request_id, "ok": False, "error": f"{type(e).__name__}: {e}"})
    finally:
        await session.disconnect()


if __name__ == "__main__":
    asyncio.run(main())
