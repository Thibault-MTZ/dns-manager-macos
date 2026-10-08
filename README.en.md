# DNS Manager for macOS

![Beta](https://img.shields.io/badge/version-0.1.0--beta.1-f59e0b)
![macOS](https://img.shields.io/badge/macOS-13%2B-111827?logo=apple)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift)

**Inspect and manage your Mac's DNS from a terminal app, with a menu bar status indicator.**

[Français](README.md) · [Architecture](docs/ARCHITECTURE.md) · [System authorization](docs/ADMIN.md) · [Changelog](CHANGELOG.md)

DNS Manager brings network connections, resolvers and DNS checks into a three-panel terminal interface. Select LAN or Wi-Fi, test a provider, and switch between network-provided DNS and a local encrypted proxy. VPN profiles appear separately to make their DNS settings understandable.

![Terminal UI in demonstration mode](docs/images/tui.png)

*Captured in demo mode with fictional data. No personal network information is displayed.*

## Features

| Feature | Purpose |
|---|---|
| Full-screen TUI | Arrow keys, panels, forms, results and colors |
| Two DNS modes | Automatic or local DNS using `127.0.0.1` and `::1` |
| Resolver management | Add, edit, test and select providers |
| Encrypted DNS | DoH / DNSCrypt via dnscrypt-proxy; automatic HTTPS stamps |
| Diagnostics | Native macOS resolution, doggo checks and response times |
| Network and VPN | LAN / Wi-Fi, macOS-exposed profiles and tunnel DNS |
| Menu bar app | Green / amber / red indicator and TUI launcher |
| Maintenance | Cache, service and tool installation / updates |
| Recovery | Save settings before changes and restore previous state |

Only public resolvers are preset: Cloudflare, Quad9 and Quad9 without threat blocking. Local DNS and custom providers are configured by the user. No private network is included by default.

## Dependencies

| Dependency | Role |
|---|---|
| macOS 13+ | Target platform |
| Swift 5.9+ and Apple Command Line Tools | Build tools; tested with Swift 6.4 on Apple Silicon |
| ncurses, Foundation, AppKit | Included with macOS |
| [doggo](https://github.com/mr-karan/doggo) | DNS checks and JSON results |
| [dnscrypt-proxy](https://github.com/DNSCrypt/dnscrypt-proxy) | Local encrypted DNS proxy |
| [Homebrew](https://brew.sh) | Tool installation and maintenance |
| [Ghostty](https://ghostty.org) | Optional; Apple's Terminal also works |

Python is **not** needed at runtime. Development tests use Python, `pyte` and optionally Pillow.

## Quick start

From the repository root:

```bash
xcode-select --install            # if Apple build tools are missing
brew install doggo dnscrypt-proxy
bash scripts/build.sh
./dist/dns-manager --tui
```

The build creates these launchers in `dist/`:

- **Lancer TUI.command** — Terminal.
- **Lancer TUI Ghostty.command** — Ghostty.
- **DNS Manager.app** — menu bar indicator without a Dock icon or settings window.
- **Installer autorisation DNS.command** — optional persistent system authorization.

First choose **Connexion → LAN or Wi-Fi**, then open **Résolveurs** to test a provider. Selecting a connection does not change DNS; activation requires confirmation.

```bash
./dist/dns-manager --demo          # fictional, read-only demonstration
./dist/dns-manager --version
./dist/dns-manager --status
./dist/dns-manager --check 127.0.0.1 example.com
./dist/dns-manager --check https://cloudflare-dns.com/dns-query example.com
./dist/dns-manager --audit-cache
```

## Keyboard controls

| Keys | Action |
|---|---|
| `↑` / `↓` | Navigate in the active panel |
| `←` / `→`, `Tab`, `Shift-Tab` | Switch panels |
| `Enter` | Select or open an action |
| `T` | Test a resolver or VPN DNS |
| `A` / `E` / `D` | Add / edit / remove a resolver |
| `R` | Refresh checks |
| `Page Up` / `Page Down` | Scroll details |
| `Esc` | Cancel or return to navigation |
| `?` / `Q` | Help / quit |

Minimum size: **64 × 18**. Three panels appear at **110 columns**; narrower windows use two. Checks run in the background and refresh every minute. `--simple` retains numbered menus.

## Settings and system access

Settings live in `~/Library/Application Support/DNSManager/`, outside Git. `settings.json` and `restore.json` use `0600` permissions. Passwords are not saved.

Without persistent authorization, system operations use the macOS administrator prompt. Resolver activation and restoration group privileged steps into a single transaction.

Persistent authorization is **optional and experimental in this beta**. The root-owned helper accepts defined DNS operations rather than arbitrary commands. Installation protects the configuration and a proxy copy and restarts the existing service. [Installation, updates and removal](docs/ADMIN.md).

## Beta status

The build, TUI, menu bar app, DNS checks and navigation have been verified on an Apple Silicon Mac. Core checks and PTY tests are included.

- The administrator component builds; its complete installation, activation, recovery and removal cycle still needs integration validation on a test machine.
- VPN detection depends on macOS-exposed data. VPN profiles, keys and routes are not changed.
- Plain DNS, DoT and DoQ are for **testing**; proxy activation uses DoH or DNSCrypt.
- The indicator reports resolution health, not encryption across every application.
- No universal binary or notarization in this first beta.
- The interface is currently French; documentation is French and English.

## Development checks

```bash
bash scripts/check.sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-dev.txt
.venv/bin/python scripts/test_terminal.py
.venv/bin/python scripts/test_terminal.py --preview
```

Tests isolate their settings and do not apply real DNS changes. The last command generates the README's generic preview. [Contributing](CONTRIBUTING.md) · [Quad9 notes](docs/QUAD9.md).

A distribution license has not yet been selected for this beta.
