# Audit cache / Quad9

**Outils → Audit cache / Quad9** ou `./dist/dns-manager --audit-cache` affiche les réglages en lecture seule.

[Quad9 recommande un cache et de la redondance](https://docs.quad9.net/Quad9_For_Organizations/DNS_Forwarder_Best_Practices/). Les exemples QNAME Minimization concernent notamment BIND et Unbound ; leur syntaxe ne s'applique pas à dnscrypt-proxy.

Le [modèle DNSCrypt](https://github.com/DNSCrypt/dnscrypt-proxy/blob/master/dnscrypt-proxy/example-dnscrypt-proxy.toml) distingue `require_dnssec`, filtre de sélection, de la validation locale. [Quad9 sans filtrage](https://docs.quad9.net/services/) ne bloque pas les domaines malveillants. Aucun fournisseur ni TTL n'est modifié par l'audit. Un test sur `::1` vérifie l'IPv6 local, pas Internet.

## English

Read-only audit. Quad9's caching advice is relevant, but BIND/Unbound syntax should not be copied into dnscrypt-proxy. `require_dnssec` concerns resolver selection. The unfiltered service does not provide threat blocking. No automatic provider or TTL change is applied.
