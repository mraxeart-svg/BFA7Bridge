#!/usr/bin/env python3
"""Dump a loaded iOS process module through Frida.

This is intended for FairPlay-protected iOS apps where the on-disk Mach-O is
still encrypted but the module's __TEXT pages are decrypted in process memory.
It does not hook app functions; it only reads the target module address range in
chunks from inside the process.

Example:
  py -3.12 tools/dump_ios_module.py -H 127.0.0.1:27042 -p 1234 MIWBTCore MIWBTCore.mem.bin
"""

from __future__ import annotations

import argparse
import sys
import threading
from pathlib import Path

import frida

JS = r"""
'use strict';

function findModule(needle) {
  const modules = Process.enumerateModules();
  const lower = needle.toLowerCase();
  for (const module of modules) {
    if (module.name.toLowerCase() === lower) return module;
  }
  for (const module of modules) {
    if (module.name.toLowerCase().indexOf(lower) >= 0 || (module.path || '').toLowerCase().indexOf(lower) >= 0) {
      return module;
    }
  }
  return null;
}

rpc.exports = {
  dumpmodule(name, chunkSize) {
    const module = findModule(name);
    if (module === null) {
      send({ kind: 'error', message: 'module not found: ' + name });
      return false;
    }

    const size = module.size;
    const base = module.base;
    const step = Math.max(4096, Math.min(chunkSize || 65536, 262144));
    send({ kind: 'meta', name: module.name, path: module.path, base: base.toString(), size: size });

    for (let offset = 0; offset < size; offset += step) {
      const length = Math.min(step, size - offset);
      const address = base.add(offset);
      try {
        const bytes = Memory.readByteArray(address, length);
        if (bytes !== null) {
          send({ kind: 'chunk', offset: offset, size: length }, bytes);
        } else {
          send({ kind: 'hole', offset: offset, size: length, message: 'null read' });
        }
      } catch (error) {
        send({ kind: 'hole', offset: offset, size: length, message: String(error) });
      }
    }

    send({ kind: 'done' });
    return true;
  }
};
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("module", help="Loaded module name or substring, e.g. MIWBTCore")
    parser.add_argument("output", type=Path, help="Output dump path")
    parser.add_argument("-H", "--host", default="127.0.0.1:27042", help="Frida remote host")
    parser.add_argument("-p", "--pid", type=int, required=True, help="Target process PID")
    parser.add_argument("--chunk-size", type=int, default=65536, help="Read chunk size")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    done = threading.Event()
    failed: list[str] = []
    image: bytearray | None = None
    received = 0
    holes = 0

    def on_message(message, data):
        nonlocal image, received, holes
        if message.get("type") != "send":
            print(f"[frida] {message}", file=sys.stderr)
            return
        payload = message.get("payload", {})
        kind = payload.get("kind")
        if kind == "meta":
            size = int(payload["size"])
            image = bytearray(size)
            print(f"module={payload.get('name')} base={payload.get('base')} size={size} path={payload.get('path')}")
        elif kind == "chunk":
            if image is None:
                failed.append("received chunk before meta")
                done.set()
                return
            offset = int(payload["offset"])
            blob = bytes(data or b"")
            image[offset:offset + len(blob)] = blob
            received += len(blob)
            if received % (1024 * 1024) < len(blob):
                print(f"received={received} bytes")
        elif kind == "hole":
            holes += 1
            print(f"hole offset={payload.get('offset')} size={payload.get('size')} {payload.get('message')}")
        elif kind == "error":
            failed.append(str(payload.get("message")))
            done.set()
        elif kind == "done":
            done.set()

    manager = frida.get_device_manager()
    device = manager.add_remote_device(args.host)
    session = device.attach(args.pid)
    script = session.create_script(JS)
    script.on("message", on_message)
    script.load()

    try:
        ok = script.exports_sync.dumpmodule(args.module, args.chunk_size)
        if not ok:
            failed.append("dumpmodule returned false")
        done.wait(timeout=120)
    finally:
        script.unload()
        session.detach()

    if failed:
        print("ERROR: " + "; ".join(failed), file=sys.stderr)
        return 1
    if image is None:
        print("ERROR: no module metadata received", file=sys.stderr)
        return 1

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(image)
    print(f"wrote={args.output} bytes={len(image)} received={received} holes={holes}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
