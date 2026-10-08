# Autorisation système facultative

**Bêta : installation, état, cache et activation vérifiés. Restauration et retrait restent à valider sur une machine de test.**

```bash
bash scripts/build.sh
bash scripts/install-admin.sh
./dist/dns-manager --admin-status
```

Le lanceur `dist/Installer autorisation DNS.command` effectue la même installation. Si la fenêtre macOS est annulée, les demandes administrateur standard restent actives.

## Portée

La règle `/etc/sudoers.d/dns-manager` vise le compte installateur et uniquement `/Library/PrivilegedHelperTools/org.dnsmanager.admin`. Les requêtes sont structurées : état, mode automatique/local, résolveur DoH/DNSCrypt, restauration, cache, démarrage/redémarrage et retrait de l'autorisation.

Le composant refuse les commandes libres, les autres modes et les connexions qui ne sont pas LAN ou Wi-Fi. Le client ne fournit pas de chemin de configuration. Un verrou sérialise les opérations. L'autorisation permet aux processus du compte installateur de demander ces actions DNS ; elle ne permet pas d'exécuter n'importe quel programme avec sudo. Aucun serveur d'administration permanent n'est ajouté.

## Fichiers

| Chemin | Contenu |
|---|---|
| `/Library/PrivilegedHelperTools/org.dnsmanager.admin` | Composant administrateur root |
| `/Library/PrivilegedHelperTools/org.dnsmanager.proxy` | Copie protégée du proxy |
| `/Library/Application Support/DNSManagerAdmin/dnscrypt-proxy.toml` | Configuration active après installation |
| `/Library/Application Support/DNSManagerAdmin/private/` | Métadonnées, verrou et récupération ; root, `0700` |
| `/etc/sudoers.d/dns-manager` | Autorisation limitée à cet exécutable |

L'installation conserve le label `sh.brew.dnscrypt-proxy`, sauvegarde sa définition et redémarre le service avec la même configuration. Les DNS des connexions ne changent pas. Après une mise à jour Homebrew, relancer l'installation pour actualiser la copie protégée avec l'autorisation macOS.

## Retirer

**Maintenance → Retirer l'autorisation durable**, ou :

```bash
./dist/dns-manager --admin-remove
```

Une confirmation est demandée. La règle et le composant administrateur sont retirés ; le proxy, sa configuration et les DNS sont conservés. Les prochaines opérations reviennent à la demande administrateur standard.

## English

This optional beta helper grants the installing account access to defined DNS actions. Requests are structured, paths are fixed, and arbitrary commands are rejected. Installation protects the proxy/configuration and restarts the existing service without changing interface DNS. Updates require an authorized reinstall. Removal revokes the helper access while preserving DNS state. Installation, status, cache flush and activation have been verified. Recovery and removal remain pending.
