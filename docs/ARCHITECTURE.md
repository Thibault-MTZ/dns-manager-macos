# Architecture

Le moteur est partagé entre le TUI et le voyant. L'app n'est pas un résolveur : dnscrypt-proxy assure le forwarding chiffré et doggo effectue les tests.

```text
DNSManagerCLI ───────┐
  TUI + commandes   │
                    ├── DNSManagerCore ── macOS / doggo / dnscrypt-proxy
DNSManagerMenu ──────┘          │
  voyant                       └── AdminBridge ── composant root facultatif
```

| Répertoire | Rôle |
|---|---|
| `Sources/DNSManagerCore` | Modèles, persistance, processus, contrôles et transactions |
| `Sources/DNSManagerCLI` | TUI, menus simples et commandes |
| `Sources/CTerminal` | Pont C vers ncurses fourni par macOS |
| `Sources/DNSManagerMenu` | AppKit, voyant et ouverture du TUI |
| `Sources/DNSManagerAdmin` | Actions système définies, exécutées avec droits root |
| `Tests/DNSManagerCoreTests` | Vérifications sans XCTest |
| `scripts` | Compilation, installation facultative et tests de terminal |

**Automatique** reprend les DNS du réseau. **DNS local** utilise `127.0.0.1` et `::1`. Les règles par domaine et les DNS VPN restent gérés par macOS et leurs clients.

Les contrôles tournent en arrière-plan. Le mode `--demo` utilise des données fictives et bloque les actions système et l'enregistrement des paramètres. Les réglages utilisateur sont hors Git ; l'ancien schéma reste lisible et le nouveau utilise un `lanResolver` facultatif.

## English

The CLI and menu bar share the core. ncurses handles terminal rendering; doggo performs explicit checks and dnscrypt-proxy forwards encrypted DNS. An optional root-owned helper accepts structured requests. Background checks keep navigation responsive. Demo data is fictional, and user settings remain outside Git.
