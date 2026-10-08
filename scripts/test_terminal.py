#!/usr/bin/env python3
"""Exercise the compiled TUI through a real PTY (pyte required for QA only).

All settings are redirected to a temporary directory. Only a cancelled DNS
confirmation is exercised; no system DNS or service action is performed.
"""
import codecs
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import sys
import shutil
import tempfile
import termios
import time

import pyte

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / ".build" / "ui-qa"
OUTPUT.mkdir(parents=True, exist_ok=True)


class Terminal:
    def __init__(self, directory, demo=False):
        self.master, self.slave = pty.openpty()
        self.original = termios.tcgetattr(self.slave)
        self.screen = pyte.Screen(140, 38)
        self.stream = pyte.Stream(self.screen)
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self.size(140, 38, notify=False)
        environment = dict(os.environ, TERM="xterm-256color", LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8", DNS_MANAGER_DATA_DIR=str(directory))
        self.process = subprocess.Popen([str(ROOT / "dist/dns-manager"), "--demo" if demo else "--tui"], stdin=self.slave, stdout=self.slave, stderr=self.slave, env=environment, start_new_session=True)

    def size(self, columns, rows, notify=True):
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
        self.screen.resize(lines=rows, columns=columns)
        if notify:
            os.kill(self.process.pid, signal.SIGWINCH)

    def drain(self, duration=0.2):
        deadline = time.monotonic() + duration
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.master], [], [], 0.05)
            if ready:
                data = os.read(self.master, 65536)
                if data:
                    self.stream.feed(self.decoder.decode(data))

    @property
    def text(self):
        return "\n".join(self.screen.display)

    def wait(self, condition, message, timeout=20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.drain()
            if condition():
                return
            if self.process.poll() is not None:
                break
        self.capture("failure")
        raise AssertionError(message + "\n" + self.text)

    def send(self, value):
        os.write(self.master, value.encode())
        self.drain()

    def capture(self, name):
        (OUTPUT / (name + ".txt")).write_text(self.text)
        try:
            from PIL import Image, ImageDraw, ImageFont
            font = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 15)
            cell_w, cell_h = 10, 22
            colors = {"default": "#cbd5e1", "white": "#e2e8f0", "black": "#07131f", "cyan": "#67e8f9", "green": "#86efac", "yellow": "#fde68a", "red": "#fca5a5", "blue": "#164e9c"}
            image = Image.new("RGB", (self.screen.columns * cell_w + 24, self.screen.lines * cell_h + 24), "#07131f")
            draw = ImageDraw.Draw(image)
            for y in range(self.screen.lines):
                for x in range(self.screen.columns):
                    cell = self.screen.buffer[y][x]
                    left, top = 12 + x * cell_w, 12 + y * cell_h
                    if cell.bg != "default":
                        draw.rectangle((left, top, left + cell_w, top + cell_h), fill=colors.get(cell.bg, "#07131f"))
                    draw.text((left, top), cell.data, font=font, fill=colors.get(cell.fg, "#cbd5e1"))
            image.save(OUTPUT / (name + ".png"))
        except ImportError:
            pass

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=5)
        os.close(self.master)
        os.close(self.slave)


DOWN = "\x1bOB"
RIGHT = "\x1bOC"
ESC = "\x1b"
ENTER = "\r"
TAB = "\t"

if "--preview" in sys.argv:
    with tempfile.TemporaryDirectory(prefix="dns-manager-preview-") as temporary:
        terminal = Terminal(Path(temporary), demo=True)
        try:
            terminal.wait(lambda: "État actualisé" in terminal.text, "Demo did not finish loading")
            terminal.send(DOWN + DOWN + DOWN + ENTER + "t")
            terminal.wait(lambda: "12 ms" in terminal.text, "Demo test missing")
            terminal.capture("preview")
            destination = ROOT / "docs/images"
            destination.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(OUTPUT / "preview.png", destination / "tui.png")
            terminal.send("q")
            terminal.process.wait(timeout=5)
            print("✓ Aperçu générique issu du mode démo, sans données réseau personnelles.")
        finally:
            terminal.close()
    sys.exit(0)

config = Path("/opt/homebrew/etc/dnscrypt-proxy.toml")
original_hash = hashlib.sha256(config.read_bytes()).hexdigest() if config.exists() else None

with tempfile.TemporaryDirectory(prefix="dns-manager-tui-qa-") as temporary:
    directory = Path(temporary)
    terminal = Terminal(directory)
    try:
        terminal.wait(lambda: "État actualisé" in terminal.text, "Initial DNS checks never finished")
        assert "Navigation" in terminal.text and "Détails / résultats" in terminal.text
        terminal.capture("dashboard")

        terminal.send(DOWN + ENTER)
        terminal.wait(lambda: "Connexion configurée" in terminal.text or "Connexion utilisée" in terminal.text, "Connection panel missing")
        terminal.send(ENTER)
        terminal.wait(lambda: (directory / "settings.json").exists() and "État actualisé" in terminal.text, "Connection selection did not persist")
        assert json.loads((directory / "settings.json").read_text())["service"]

        terminal.send(ESC)
        terminal.send(DOWN + ENTER)
        assert "Automatique (par défaut)" in terminal.text
        terminal.send(ENTER)
        assert "Confirmer" in terminal.text and "Annuler" in terminal.text
        terminal.send(ENTER)  # Cancel is selected by default: no DNS mutation.
        assert not (directory / "restore.json").exists()

        terminal.send(ESC)
        terminal.send(DOWN + ENTER)
        assert "Cloudflare" in terminal.text
        terminal.send(DOWN)
        assert "Quad9" in terminal.text
        terminal.send("t")
        terminal.wait(lambda: "ms" in terminal.text and "DERNIER TEST" in terminal.text, "Resolver test did not produce a result")
        terminal.capture("resolvers")

        terminal.send("a")
        assert "Ajouter un résolveur" in terminal.text
        terminal.send("qa-temp" + TAB + "Résolveur QA" + TAB + "https://cloudflare-dns.com/dns-query" + TAB + ENTER)
        saved = json.loads((directory / "settings.json").read_text())
        assert any(r["id"] == "qa-temp" and r["name"] == "Résolveur QA" for r in saved["resolvers"])
        terminal.send("e")
        assert "Modifier le résolveur" in terminal.text
        terminal.send(TAB + "\x15" + "QA corrigé" + TAB + TAB + ENTER)
        saved = json.loads((directory / "settings.json").read_text())
        assert any(r["id"] == "qa-temp" and r["name"] == "QA corrigé" for r in saved["resolvers"])
        terminal.send("d" + ENTER)
        assert any(r["id"] == "qa-temp" for r in json.loads((directory / "settings.json").read_text())["resolvers"])
        terminal.send("d" + TAB + ENTER)
        assert not any(r["id"] == "qa-temp" for r in json.loads((directory / "settings.json").read_text())["resolvers"])

        terminal.send(ESC)
        terminal.send(DOWN + ENTER)
        assert "VPN" in terminal.text
        terminal.capture("vpn")
        terminal.send(RIGHT)
        terminal.size(92, 28)
        terminal.wait(lambda: "Détails / résultats" in terminal.text, "Two-column layout missing after resize")
        terminal.capture("compact")
        terminal.size(60, 15)
        terminal.wait(lambda: "agrandir" in terminal.text, "Small-terminal hint missing")
        terminal.size(140, 38)
        terminal.send("?")
        assert "Raccourcis" in terminal.text
        terminal.send(ESC)
        terminal.send("q")
        terminal.process.wait(timeout=5)
        assert terminal.process.returncode == 0
        final = termios.tcgetattr(terminal.slave)
        assert final[3] & (termios.ECHO | termios.ICANON) == terminal.original[3] & (termios.ECHO | termios.ICANON), "Terminal mode was not restored"
        if original_hash:
            assert hashlib.sha256(config.read_bytes()).hexdigest() == original_hash, "System DNS config changed during UI tests"
        print("✓ TUI : flèches, panneaux, test réel, formulaires Unicode, ajout/modification/suppression isolés, confirmation annulée, redimensionnement et sortie propre.")
    finally:
        terminal.close()
