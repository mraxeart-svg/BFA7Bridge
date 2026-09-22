#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

from androguard.core.dex import DEX
from loguru import logger


APK_BASE = Path("/home/flavor/xiaomi_glasses_base")

TARGETS = (
    "DeviceContactEngine;->call(",
    "DeviceContactEngine;->callTimeout(",
    "DeviceContactEngine;->callTimeoutWithData(",
    "DeviceContactEngine;->callWithData(",
    "DeviceContactEngine$Default;->call",
    "DeviceContactEngineImpl;->call(",
    "callTimeoutWithData",
)

NEARBY_TERMS = (
    "new-array",
    "fill-array-data",
    "const/4",
    "const/16",
    "const/8",
    "const-string",
    "invoke-",
    "move-result",
    "aput-byte",
    "array-length",
)


def interesting_output(output: str) -> bool:
    return any(target in output for target in TARGETS)


def main() -> None:
    logger.remove()
    for dex_path in sorted(APK_BASE.glob("classes*.dex")):
        dex = DEX(dex_path.read_bytes())
        for cls in dex.get_classes():
            for method in cls.get_methods():
                if not method.get_code():
                    continue
                lines = []
                hit_indices = []
                for index, ins in enumerate(method.get_instructions()):
                    name = ins.get_name()
                    output = ins.get_output()
                    lines.append((index, name, output))
                    if interesting_output(output):
                        hit_indices.append(index)
                if not hit_indices:
                    continue
                print()
                print(
                    f"### {dex_path.name} {method.get_class_name()}->"
                    f"{method.get_name()}{method.get_descriptor()}"
                )
                for hit in hit_indices:
                    print(f"-- hit {hit} --")
                    start = max(0, hit - 45)
                    end = min(len(lines), hit + 30)
                    for index, name, output in lines[start:end]:
                        marker = "*" if index == hit else " "
                        if (
                            marker == "*"
                            or any(term in name for term in NEARBY_TERMS)
                            or any(term in output for term in TARGETS)
                        ):
                            print(f"{marker}{index:04d}: {name:<20} {output}")


if __name__ == "__main__":
    main()
