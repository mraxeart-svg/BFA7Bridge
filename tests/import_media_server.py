"""Local HTTP fixtures for the macOS import-transfer tests; no real media."""
import json
import struct
import sys
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


PNG = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(b"\x00\xff\x00\x00\x00\xff\x00" * 2)) + chunk(b"IEND", b""))


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        status, mime = 200, "application/json"
        if self.path == "/v1/filelists":
            body = json.dumps([
                {"fileName": "IMG_TEST", "url": "filelists/LLHDR_TEST", "mimeType": "image/folder",
                 "size": len(PNG), "fileAdded": 2000},
                {"fileName": "older.png", "url": "older.png", "size": len(PNG), "fileAdded": 1000}
            ]).encode()
        elif self.path == "/v1/filelists/LLHDR_TEST":
            body = json.dumps([
                {"filename": "metadata.json", "size": 100},
                {"filename": "LLHDR_TEST-part.png", "size": len(PNG)}
            ]).encode()
        elif self.path == "/v1/filelists/LLHDR_EMPTY":
            body = b'[{"filename":"metadata.json"}]'
        elif self.path in ["/v1/files/LLHDR_TEST-part.png", "/v1/files/older.png", "/v1/files/slow.png"]:
            if self.path.endswith("slow.png"):
                time.sleep(2)
            body, mime = PNG, "image/png"
        elif self.path == "/v1/files/fake.png":
            body, mime = b'{"error":"not an image"}', "image/png"
        elif self.path == "/v1/files/truncated.png":
            body, mime = PNG[:16], "image/png"
        elif self.path == "/v1/files/redirect.png":
            self.send_response(302)
            self.send_header("Location", "/v1/files/older.png")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        else:
            status, body, mime = 404, b"not found", "text/plain"
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
