#!/usr/bin/env python3
"""Webhook di spegnimento gentile del media server.

  GET /shutdown?token=XXX   -> sync + `systemctl poweroff`

Fa SOLO lo shutdown pulito del PC: systemd ferma i container Docker e smonta
/mnt/media nell'ordine giusto. A staccare la corrente ci pensa lo Shelly da
solo, 1-2 min dopo, tramite una scena nell'app Shelly.

  GET /shutdown?token=XXX&dry=1  -> non spegne, verifica solo raggiungibilita'/token

Config via variabili d'ambiente (vedi mediaserver-shutdown.env.example),
caricate dal service systemd da /etc/mediaserver-shutdown.env.
"""
import os
import subprocess
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

ADDR = os.environ.get("LISTEN_ADDR", "0.0.0.0")
PORT = int(os.environ.get("LISTEN_PORT", "9977"))
TOKEN = os.environ.get("SHUTDOWN_TOKEN", "").strip()
POWEROFF_CMD = os.environ.get("POWEROFF_CMD", "sudo /usr/bin/systemctl poweroff").split()


class Handler(BaseHTTPRequestHandler):
    def _reply(self, code, msg):
        body = (msg + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/shutdown":
            return self._reply(404, "not found")

        query = urllib.parse.parse_qs(parsed.query)
        # token OBBLIGATORIO: se non e' impostato o non combacia -> rifiuto.
        if not TOKEN or query.get("token", [""])[0] != TOKEN:
            return self._reply(403, "token errato o mancante")

        if query.get("dry", ["0"])[0] in ("1", "true", "yes"):
            return self._reply(200, "DRY-RUN ok: webhook raggiungibile e token valido. Nessuno spegnimento.")

        self._reply(200, "OK: spengo il media server (shutdown pulito). Lo Shelly stacchera' la corrente tra 1-2 min.")
        try:
            self.wfile.flush()
        except Exception:
            pass
        subprocess.run(["sync"])
        # systemctl poweroff avvia poweroff.target: ferma docker, smonta i FS,
        # poi spegne. Prosegue anche se questo service viene terminato.
        subprocess.Popen(POWEROFF_CMD)

    def log_message(self, fmt, *args):
        sys.stderr.write("[shutdown-webhook] " + (fmt % args) + "\n")


def main():
    sys.stderr.write(f"[shutdown-webhook] in ascolto su {ADDR}:{PORT}\n")
    HTTPServer((ADDR, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
