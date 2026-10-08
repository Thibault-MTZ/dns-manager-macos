# Contribuer / Contributing

Conserver une app macOS générique. Utiliser des résolveurs publics et des domaines/adresses réservés à la documentation dans les exemples. Ne pas committer de paramètres réseau réels, exports VPN, clés, journaux ou captures personnelles.

```bash
bash scripts/build.sh
bash scripts/check.sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-dev.txt
.venv/bin/python scripts/test_terminal.py
```

`test_terminal.py --preview` génère la capture du README depuis le mode démo. Les tests isolent leurs paramètres et annulent la confirmation DNS.

Pour une version, mettre à jour `VERSION`, `AppRelease.version`, les badges et `CHANGELOG.md`, puis compiler avant de taguer. `dist/` reste hors Git. La licence de distribution reste à définir.

## English

Keep the app generic. Use public resolvers and documentation-reserved examples. Do not commit real network settings, VPN exports, keys, logs or personal screenshots. Run the checks above; UI tests use isolated settings. Update version metadata and changelog together before tagging. Generated binaries remain outside source control.
