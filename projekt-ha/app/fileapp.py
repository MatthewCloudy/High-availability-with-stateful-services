#!/usr/bin/env python3
"""
Prosty serwis HTTP do uploadu/pobierania plików.
Stan = pliki w /data/uploads/ (DRBD).

Endpointy:
    POST /upload?name=<plik>     - body=zawartość; zwraca {ok,sha256,size}
    GET  /files/<plik>           - pobranie
    GET  /health                 - {ok:true, node:<hostname>, mount:<bool>}
    GET  /                       - lista plików (debug)

Uruchamiać przez systemd (fileapp.service).
"""
import hashlib
import json
import os
import socket
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote

DATA_DIR = "/data/uploads"
LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = 8080


def _is_mounted(path: str) -> bool:
    """Czy /data jest faktycznie zamontowane (nie pusty katalog)?"""
    try:
        return os.path.ismount("/data")
    except Exception:
        return False


def _safe_name(name: str) -> str:
    """Tylko nazwa pliku — żadnych ../, slashy itd."""
    name = os.path.basename(unquote(name))
    if not name or name.startswith("."):
        raise ValueError("invalid filename")
    return name


class Handler(BaseHTTPRequestHandler):
    server_version = "fileapp/1.0"

    def _json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stderr.write(f"[fileapp] {self.address_string()} - {fmt % args}\n")

    # ----- GET -----
    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/health":
            return self._json(
                200,
                {
                    "ok": True,
                    "node": socket.gethostname(),
                    "mounted": _is_mounted(DATA_DIR),
                },
            )
        if u.path == "/":
            try:
                files = sorted(os.listdir(DATA_DIR))
            except FileNotFoundError:
                files = []
            return self._json(200, {"files": files, "node": socket.gethostname()})
        if u.path.startswith("/files/"):
            try:
                name = _safe_name(u.path[len("/files/"):])
                path = os.path.join(DATA_DIR, name)
                if not os.path.isfile(path):
                    return self._json(404, {"ok": False, "error": "not found"})
                size = os.path.getsize(path)
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(size))
                self.send_header(
                    "Content-Disposition", f'attachment; filename="{name}"'
                )
                self.end_headers()
                with open(path, "rb") as f:
                    while chunk := f.read(65536):
                        self.wfile.write(chunk)
                return
            except Exception as e:
                return self._json(400, {"ok": False, "error": str(e)})
        return self._json(404, {"ok": False, "error": "unknown path"})

    # ----- POST -----
    def do_POST(self):
        u = urlparse(self.path)
        if u.path != "/upload":
            return self._json(404, {"ok": False, "error": "unknown path"})

        # nazwa pliku z query lub z nagłówka X-Filename
        q = parse_qs(u.query)
        name = (q.get("name", [None])[0]) or self.headers.get("X-Filename")
        if not name:
            return self._json(400, {"ok": False, "error": "missing ?name="})

        try:
            name = _safe_name(name)
        except ValueError as e:
            return self._json(400, {"ok": False, "error": str(e)})

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0:
            return self._json(411, {"ok": False, "error": "Content-Length required"})

        if not _is_mounted(DATA_DIR.rsplit("/", 1)[0]):
            return self._json(
                503, {"ok": False, "error": "storage not mounted (this node is standby)"}
            )

        os.makedirs(DATA_DIR, exist_ok=True)

        # Atomowy zapis: write do .tmp w tym samym katalogu → fsync → rename.
        # Jeśli aplikacja zostanie ubita w trakcie, plik docelowy NIE pojawi się
        # niekompletny — to ważne dla "Test 5: awaria w trakcie uploadu".
        sha = hashlib.sha256()
        written = 0
        tmp_fd, tmp_path = tempfile.mkstemp(
            prefix=f".{name}.", suffix=".part", dir=DATA_DIR
        )
        try:
            with os.fdopen(tmp_fd, "wb") as out:
                remaining = length
                while remaining > 0:
                    chunk = self.rfile.read(min(65536, remaining))
                    if not chunk:
                        break
                    out.write(chunk)
                    sha.update(chunk)
                    written += len(chunk)
                    remaining -= len(chunk)
                out.flush()
                os.fsync(out.fileno())
            if written != length:
                os.unlink(tmp_path)
                return self._json(
                    400,
                    {
                        "ok": False,
                        "error": f"short read: got {written} expected {length}",
                    },
                )
            final = os.path.join(DATA_DIR, name)
            os.rename(tmp_path, final)
            # sync samego katalogu, żeby rename trafił na dysk
            dfd = os.open(DATA_DIR, os.O_DIRECTORY)
            os.fsync(dfd)
            os.close(dfd)
            return self._json(
                200,
                {
                    "ok": True,
                    "name": name,
                    "size": written,
                    "sha256": sha.hexdigest(),
                    "node": socket.gethostname(),
                },
            )
        except Exception as e:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            return self._json(500, {"ok": False, "error": str(e)})


def main():
    os.makedirs(DATA_DIR, exist_ok=True) if _is_mounted("/data") else None
    srv = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    print(f"[fileapp] listening on {LISTEN_HOST}:{LISTEN_PORT}, data={DATA_DIR}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
