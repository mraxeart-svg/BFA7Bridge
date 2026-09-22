#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

from androguard.core.dex import DEX
from loguru import logger


APK_BASE = Path("/home/flavor/xiaomi_glasses_base")

WEAR_PACKET_MARKERS = (
    "Lcom/xiaomi/wear/protobuf/nano/WearProtos$WearPacket;",
    "Lcom/xiaomi/wearable/protocol/WearProtos$WearPacket;",
)

FIELD_MARKERS = (
    "->type I",
    "->id I",
    "->payloadCase_ I",
    "->payload_ Ljava/lang/Object;",
)

NOISY_METHODS = (
    "->clear()",
    "->writeTo(",
    "->computeSerializedSize(",
    "->mergeFrom(",
    "->emptyArray()",
    "->getPayloadCase(",
)


def is_wearpacket_hit(output: str) -> bool:
    if not any(marker in output for marker in WEAR_PACKET_MARKERS):
        return False
    if any(noise in output for noise in NOISY_METHODS):
        return False
    return "-><init>" in output or any(field in output for field in FIELD_MARKERS)


def main() -> None:
    logger.remove()
    for dex_path in sorted(APK_BASE.glob("classes*.dex")):
        dex = DEX(dex_path.read_bytes())
        for cls in dex.get_classes():
            for method in cls.get_methods():
                if not method.get_code():
                    continue

                lines: list[tuple[int, str, str]] = []
                hit_indices: list[int] = []
                for index, ins in enumerate(method.get_instructions()):
                    name = ins.get_name()
                    output = ins.get_output()
                    lines.append((index, name, output))
                    if is_wearpacket_hit(output):
                        hit_indices.append(index)

                if not hit_indices:
                    continue

                print()
                print(
                    f"### {dex_path.name} {method.get_class_name()}->"
                    f"{method.get_name()}{method.get_descriptor()}"
                )
                printed: set[int] = set()
                for hit in hit_indices:
                    print(f"-- hit {hit} --")
                    start = max(0, hit - 45)
                    end = min(len(lines), hit + 65)
                    for index, name, output in lines[start:end]:
                        if index in printed:
                            continue
                        printed.add(index)
                        marker = "*" if index == hit else " "
                        print(f"{marker}{index:04d}: {name:<20} {output}")


if __name__ == "__main__":
    main()
