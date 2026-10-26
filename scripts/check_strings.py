#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 GPSSpoofer contributors
"""
檢查每個 .lproj/Localizable.strings 是否涵蓋原始碼中所有 L("…") 字串，且沒有多餘的 key。
key 是繁體中文原文，所以 zh-Hant 不需要翻譯檔。

用法：python3 scripts/check_strings.py          # 有缺漏時以非零狀態結束
      python3 scripts/check_strings.py --keys   # 列出所有 key（插值以 %lld / %@ 表示前的原樣）
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources/GPSSpoofer"
RESOURCES = SOURCES / "Resources"

CALL = re.compile(r'L\("((?:[^"\\\n]|\\.)*)"\)')
INTERPOLATION = re.compile(r"\\\((?:[^()]|\([^()]*\))*\)")
SPECIFIER = re.compile(r"%(?:lld|ld|d|@|lf|f)")
ENTRY = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', re.M)


def normalize(key: str) -> str:
    """插值在 Swift 原始碼是 \\(expr)，在 .strings 是 %lld / %@，比對時都換成同一個記號"""
    return SPECIFIER.sub("%#", INTERPOLATION.sub("%#", key))


def source_keys() -> dict[str, str]:
    keys = {}
    for path in sorted(SOURCES.glob("*.swift")):
        for match in CALL.finditer(path.read_text()):
            keys.setdefault(normalize(match.group(1)), match.group(1))
    # RouteEndBehavior 的顯示名稱以 rawValue 查表
    for match in re.finditer(r'case \w+ = "([^"]+)"', (SOURCES / "LocationController+Route.swift").read_text()):
        keys.setdefault(normalize(match.group(1)), match.group(1))
    return keys


def main() -> int:
    keys = source_keys()
    if "--keys" in sys.argv:
        print("\n".join(keys.values()))
        return 0
    failed = False
    for strings in sorted(RESOURCES.glob("*.lproj/Localizable.strings")):
        language = strings.parent.stem
        entries = {normalize(k): (k, v) for k, v in ENTRY.findall(strings.read_text())}
        if language == "zh-Hant":
            missing, unused = [], sorted(set(entries) - set(keys))
        else:
            missing = sorted(set(keys) - set(entries))
            unused = sorted(set(entries) - set(keys))
        mismatched = [k for k, (_, v) in entries.items() if k in keys and k.count("%#") != normalize(v).count("%#")]
        for label, items in (("缺少翻譯", missing), ("多餘的 key", unused), ("插值數量不符", mismatched)):
            for item in items:
                failed = True
                print(f"❌ {language}：{label}：{keys.get(item) or entries[item][0]}")
        if not (missing or unused or mismatched):
            print(f"✅ {language}：{len(entries)} 個字串")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
