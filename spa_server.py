#!/usr/bin/env python3
"""Serves dist/ with SPA fallback: any path without a real file returns
index.html, exactly like the nginx.conf shipped for production. Mirrors the
deploy config so local verification actually matches what ships."""
import http.server
import os
import sys

DIST = sys.argv[1] if len(sys.argv) > 1 else "dist"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 4173


class SPAHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIST, **kwargs)

    def translate_path(self, path):
        clean = path.split("?")[0].split("#")[0]
        full = os.path.join(DIST, clean.lstrip("/"))
        if clean != "/" and not os.path.isfile(full):
            return os.path.join(DIST, "index.html")
        return super().translate_path(path)


if __name__ == "__main__":
    http.server.ThreadingHTTPServer(("", PORT), SPAHandler).serve_forever()
