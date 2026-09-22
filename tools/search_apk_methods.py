#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

from androguard.core.dex import DEX
from loguru import logger


APK_BASE = Path("/home/flavor/xiaomi_glasses_base")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("terms", nargs="+")
    parser.add_argument("--context", type=int, default=50)
    return parser.parse_args()


def lower_terms(terms: list[str]) -> list[str]:
    return [term.lower() for term in terms]


def matches(text: str, terms: list[str]) -> bool:
    lower = text.lower()
    return any(term in lower for term in terms)


def main() -> None:
    args = parse_args()
    terms = lower_terms(args.terms)
    logger.remove()
    for dex_path in sorted(APK_BASE.glob("classes*.dex")):
        dex = DEX(dex_path.read_bytes())
        for cls in dex.get_classes():
            class_hit = matches(cls.get_name(), terms)
            for method in cls.get_methods():
                method_label = (
                    f"{method.get_class_name()}->{method.get_name()}"
                    f"{method.get_descriptor()}"
                )
                lines = []
                hit_indices = []
                if class_hit or matches(method_label, terms):
                    hit_indices.append(0)
                if method.get_code():
                    for index, ins in enumerate(method.get_instructions()):
                        text = f"{ins.get_name()} {ins.get_output()}"
                        lines.append((index, ins.get_name(), ins.get_output()))
                        if matches(text, terms):
                            hit_indices.append(index)
                if not hit_indices:
                    continue
                print()
                print(f"### {dex_path.name} {method_label}")
                if not lines:
                    continue
                printed = set()
                for hit in hit_indices:
                    start = max(0, hit - args.context)
                    end = min(len(lines), hit + args.context + 1)
                    print(f"-- hit {hit} --")
                    for index, name, output in lines[start:end]:
                        if index in printed:
                            continue
                        printed.add(index)
                        marker = "*" if index == hit else " "
                        print(f"{marker}{index:04d}: {name:<20} {output}")


if __name__ == "__main__":
    main()
