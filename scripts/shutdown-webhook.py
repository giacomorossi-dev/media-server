#!/usr/bin/env python3
"""Webhook di spegnimento gentile del media server.

  GET /shutdown?token=XXX

Sequenza, tutta in LAN (niente cloud):
  1. dice allo Shelly di aprire il rele' dopo CUT_DELAY_SECONDS
     (Switch.Set con toggle_after: il rele', gia' ON, si spegne dopo N secondi);
  2. avvia lo shutdown pulito (systemctl poweroff: ferma i container e smonta
     /mnt/media nell'ordine giusto).

Cosi' lo Shelly taglia la corrente SOLO dopo che l'OS ha smontato il disco.
Mini PC e Shelly sono entrambi sulla LAN, quindi la chiamata RPC funziona
sempre -- una *scena cloud* Shelly NON raggiungerebbe l'IP locale del mini PC.

  GET /shutdown?token=XXX&dry=1  -> non spegne; verifica token + raggiungibilita' Shelly

Config via /etc/mediaserver-shutdown.env (vedi mediaserver-shutdown.env.example).
"""
import os
import subprocess
import sys
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

ADDR = os.environ.get("LISTEN_ADDR", "0.0.0.0")
PORT = int(os.environ.get("LISTEN_PORT", "9977"))
TOKEN = os.environ.get("SHUTDOWN_TOKEN", "").strip()
POWEROFF_CMD = os.environ.get("POWEROFF_CMD", "sudo /usr/bin/systemctl poweroff").split()

SHELLY_IP = os.environ.get("SHELLY_IP", "").strip()
SHELLY_ID = os.environ.get("SHELLY_SWITCH_ID", "0").strip()
SHELLY_USER = os.environ.get("SHELLY_USER", "admin").strip()
SHELLY_PASS = os.environ.get("SHELLY_PASSWORD", "").strip()
CUT_DELAY = int(os.environ.get("CUT_DELAY_SECONDS", "120"))


def shelly_rpc(method, params):
    """Chiama l'RPC locale dello Shelly via GET. Ritorna (ok, testo)."""
    if not SHELLY_IP:
        return False, "SHELLY_IP non impostato in /etc/mediaserver-shutdown.env"
    url = f"http://{SHELLY_IP}/rpc/{method}?{urllib.parse.urlencode(params)}"
    opener = urllib.request.build_opener()
    if SHELLY_PASS:
        mgr = urllib.request.HTTPPasswordMgrWithDefaultRealm()
        mgr.add_password(None, f"http://{SHELLY_IP}/", SHELLY_USER, SHELLY_PASS)
        opener.add_handler(urllib.request.HTTPDigestAuthHandler(mgr))
    try:
        with opener.open(url, timeout=5) as resp:
            return True, resp.read().decode("utf-8", "replace")
    except Exception as e:
        return False, str(e)


def schedule_cut():
    # rele' gia' ON: on=true + toggle_after -> si spegne dopo CUT_DELAY secondi
    return shelly_rpc("Switch.Set", {"id": SHELLY_ID, "on": "true", "toggle_after": CUT_DELAY})


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
        if not TOKEN or query.get("token", [""])[0] != TOKEN:
            return self._reply(403, "token errato o mancante")

        if query.get("dry", ["0"])[0] in ("1", "true", "yes"):
            ok, txt = shelly_rpc("Switch.GetStatus", {"id": SHELLY_ID})
            return self._reply(200 if ok else 502,
                               f"DRY-RUN: token ok. Shelly raggiungibile={ok}. Risposta: {txt}")

        ok, txt = schedule_cut()
        if ok:
            self._reply(200, f"OK: lo Shelly aprira' il rele' tra {CUT_DELAY}s. Spengo il PC (shutdown pulito)...")
        else:
            self._reply(502, f"ATTENZIONE: taglio Shelly NON programmato ({txt}). "
                             f"Spengo comunque il PC; poi togli la corrente a mano.")
        try:
            self.wfile.flush()
        except Exception:
            pass
        subprocess.run(["sync"])
        # poweroff.target: ferma docker, smonta i FS, spegne. Prosegue anche se
        # questo service viene terminato durante lo shutdown.
        subprocess.Popen(POWEROFF_CMD)

    def log_message(self, fmt, *args):
        sys.stderr.write("[shutdown-webhook] " + (fmt % args) + "\n")


def main():
    sys.stderr.write(
        f"[shutdown-webhook] ascolto su {ADDR}:{PORT}; "
        f"Shelly={SHELLY_IP or '(non impostato)'}, cut={CUT_DELAY}s\n")
    HTTPServer((ADDR, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
