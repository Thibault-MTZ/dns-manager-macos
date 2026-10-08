# Historique / Changelog

## 0.1.0-beta.2 — 2026-10-08

- Correction de la vérification du service : suppression du faux échec SIGPIPE sous `pipefail`.
- Validation de la seule règle sudo de l'app ; une erreur dans une règle extérieure ne provoque plus de retour arrière.
- Conservation de la configuration effectivement active lors de l'installation.
- IP du serveur HTTPS facultative pour éviter une boucle DNS avec un nom privé ; validation TLS conservée.
- Installation, état, deux vidages de cache et activation testés sans demande répétée de mot de passe. Restauration et retrait restent à vérifier.
- 18 scénarios du moteur et contrôles du TUI.

Installer fixes and optional HTTPS server IP support. Persistent DNS authorization, cache operations and activation verified; recovery and removal remain pending.

## 0.1.0-beta.1 — 2026-10-08

Première bêta générique de DNS Manager pour macOS.

- TUI en panneaux, navigation aux flèches et formulaires Unicode.
- Résolveurs publics par défaut et fournisseurs personnalisés.
- Modes automatique et proxy local chiffré.
- Tests doggo et résolution native macOS.
- Détection LAN / Wi-Fi et informations VPN exposées par macOS.
- Voyant de barre de menus et lanceurs Terminal / Ghostty.
- Transactions avec sauvegarde ; autorisation durable facultative, expérimentale.
- Audit du cache / Quad9 en lecture seule.
- Démonstration sans données personnelles et documentation FR / EN.

### Validation / Verification

Compilation locale, contrôles du moteur et tests du terminal. Le cycle privilégié doit encore être validé sur une machine de test. Pas de notarisation ni de binaire universel.

First generic macOS beta: panel-based TUI, resolver management, DNS checks, network/VPN information, menu bar indicator, optional experimental authorization, fictional demo mode and bilingual documentation.
