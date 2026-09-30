#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 GPSSpoofer contributors
"""
從 PyInstaller 打包結果收集所有內附套件的授權聲明，產生 THIRD_PARTY_LICENSES.txt。
散布 DMG 時必須附上，MIT、BSD、Apache 等授權都要求保留原始授權聲明。

用法：.venv/bin/python scripts/collect_licenses.py <PyInstaller 的 _internal 目錄> <輸出檔>
"""

import sys
import sysconfig
from email.parser import Parser
from pathlib import Path

LICENSE_PREFIXES = ("LICENSE", "LICENCE", "COPYING", "NOTICE", "AUTHORS")
SEPARATOR = "=" * 78


def license_name(metadata) -> str:
    if expression := metadata.get("License-Expression"):
        return expression
    license_field = (metadata.get("License") or "").strip()
    if license_field and "\n" not in license_field and len(license_field) < 80:
        return license_field
    classifiers = [c.split("::")[-1].strip() for c in metadata.get_all("Classifier") or [] if c.startswith("License ::")]
    return ", ".join(classifiers) or "（未標示）"


def license_files(dist_info: Path) -> list[Path]:
    files = sorted(p for p in (dist_info / "licenses").rglob("*") if p.is_file()) if (dist_info / "licenses").is_dir() else []
    files += sorted(p for p in dist_info.iterdir() if p.is_file() and p.name.upper().startswith(LICENSE_PREFIXES))
    return files


def main() -> None:
    internal, output = Path(sys.argv[1]), Path(sys.argv[2])
    sections = []
    missing = []

    for dist_info in sorted(internal.glob("*.dist-info"), key=lambda p: p.name.lower()):
        metadata = Parser().parsestr((dist_info / "METADATA").read_text(errors="replace"))
        name, version = metadata["Name"], metadata["Version"]
        body = [f"{SEPARATOR}\n{name} {version}\n授權：{license_name(metadata)}"]
        if home := metadata.get("Home-page") or next(
            (u.split(",", 1)[1].strip() for u in metadata.get_all("Project-URL") or [] if "," in u), None
        ):
            body.append(f"來源：{home}")
        files = license_files(dist_info)
        if not files:
            missing.append(name)
            body.append("（套件未附授權檔，請見上方來源）")
        for f in files:
            body.append(f"\n--- {f.relative_to(dist_info)} ---\n{f.read_text(errors='replace').strip()}")
        sections.append("\n".join(body))

    python_license = Path(sysconfig.get_paths()["stdlib"]) / "LICENSE.txt"
    if python_license.exists():
        sections.insert(0, f"{SEPARATOR}\nPython {sys.version.split()[0]}\n授權：PSF-2.0\n\n{python_license.read_text().strip()}")

    header = (
        "GPSSpoofer 內附的第三方軟體授權聲明\n"
        "GPSSpoofer 本身以 GPL-3.0-or-later 授權，完整條文見 LICENSE。\n"
        f"以下共 {len(sections)} 個元件。\n"
    )
    output.write_text(header + "\n" + "\n\n".join(sections) + "\n")
    print(f"✅ {output}（{len(sections)} 個元件，{len(missing)} 個未附授權檔）")
    if missing:
        print("   未附授權檔：" + ", ".join(missing))


if __name__ == "__main__":
    main()
