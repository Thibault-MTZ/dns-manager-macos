#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_UID="$(/usr/bin/id -u)"
INSTALL_USER="$(/usr/bin/id -un)"
if ! [[ "$INSTALL_USER" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]; then
    echo "Nom du compte incompatible avec cette installation." >&2
    exit 1
fi
INSTALL_PREFIX="/opt/homebrew"
if [ ! -x "$INSTALL_PREFIX/sbin/dnscrypt-proxy" ]; then INSTALL_PREFIX="/usr/local"; fi
if [ ! -x "$INSTALL_PREFIX/sbin/dnscrypt-proxy" ]; then echo "Installe dnscrypt-proxy avant le composant administrateur." >&2; exit 1; fi
if [ ! -x "$PROJECT_DIR/dist/dns-manager-admin" ]; then echo "Exécute bash scripts/build.sh avant cette installation." >&2; exit 1; fi
STAGE_DIR="$(mktemp -d /private/tmp/dnsmanager-admin.XXXXXXXX)"
trap 'rm -rf "$STAGE_DIR"' EXIT
chmod 700 "$STAGE_DIR"
cp "$PROJECT_DIR/dist/dns-manager-admin" "$STAGE_DIR/helper"
printf '{"uid":%s,"prefix":"%s"}\n' "$INSTALL_UID" "$INSTALL_PREFIX" > "$STAGE_DIR/installation.json"
printf '%s ALL=(root) NOPASSWD: /Library/PrivilegedHelperTools/org.dnsmanager.admin\n' "$INSTALL_USER" > "$STAGE_DIR/sudoers"
cat > "$STAGE_DIR/install.sh" <<'INSTALL'
#!/bin/bash
set -euo pipefail
STAGE_DIR="$(cd "$(dirname "$0")" && pwd)"
ADMIN_BASE="/Library/Application Support/DNSManagerAdmin"
ADMIN_DIR="$ADMIN_BASE/private"
HELPER="/Library/PrivilegedHelperTools/org.dnsmanager.admin"
PROXY="/Library/PrivilegedHelperTools/org.dnsmanager.proxy"
CONFIG="$ADMIN_BASE/dnscrypt-proxy.toml"
SERVICE="/Library/LaunchDaemons/sh.brew.dnscrypt-proxy.plist"
RULE="/etc/sudoers.d/dns-manager"
INSTALL_PREFIX="$(/usr/bin/plutil -extract prefix raw -o - "$STAGE_DIR/installation.json")"
case "$INSTALL_PREFIX" in /opt/homebrew|/usr/local) ;; *) exit 1 ;; esac
for protected in "$ADMIN_BASE" "$ADMIN_DIR" "$HELPER" "$PROXY" "$CONFIG" "$RULE"; do
    if [ -L "$protected" ]; then echo 'Chemin administrateur symbolique refusé.' >&2; exit 1; fi
done
/usr/sbin/visudo -cf "$STAGE_DIR/sudoers"
# Do not replace an unrelated sudoers rule.
if [ -e "$RULE" ] && ! /usr/bin/grep -q 'NOPASSWD: /Library/PrivilegedHelperTools/org.dnsmanager.admin$' "$RULE"; then
    echo 'La règle dns-manager existe et ne correspond pas à cette app.' >&2
    exit 1
fi
/bin/mkdir -p "$ADMIN_BASE" "$ADMIN_DIR" /Library/PrivilegedHelperTools /etc/sudoers.d
/usr/sbin/chown root:wheel "$ADMIN_BASE"
/bin/chmod 755 "$ADMIN_BASE"
/usr/sbin/chown root:wheel "$ADMIN_DIR"
/bin/chmod 700 "$ADMIN_DIR"
if [ ! -e "$ADMIN_DIR/original-service.plist" ] && [ -f "$SERVICE" ]; then /bin/cp -p "$SERVICE" "$ADMIN_DIR/original-service.plist"; fi
if [ -f "$SERVICE" ]; then /bin/cp -p "$SERVICE" "$ADMIN_DIR/before-install.plist"; fi
if [ -e "$RULE" ]; then /bin/cp -p "$RULE" "$STAGE_DIR/previous-rule"; fi
rollback() {
    rc=$?
    if [ "$rc" -ne 0 ]; then
        if [ -f "$STAGE_DIR/previous-rule" ]; then /bin/cp -p "$STAGE_DIR/previous-rule" "$RULE"; else /bin/rm -f "$RULE"; fi
        if [ -f "$ADMIN_DIR/before-install.plist" ]; then
            /bin/launchctl bootout system/sh.brew.dnscrypt-proxy >/dev/null 2>&1 || true
            /bin/cp -p "$ADMIN_DIR/before-install.plist" "$SERVICE"
            /bin/launchctl bootstrap system "$SERVICE" || true
        fi
    fi
    exit "$rc"
}
trap rollback EXIT
/usr/bin/install -m 755 -o root -g wheel "$STAGE_DIR/helper" "$HELPER.new"
/bin/mv -f "$HELPER.new" "$HELPER"
/usr/bin/install -m 600 -o root -g wheel "$STAGE_DIR/installation.json" "$ADMIN_DIR/installation.json"
ACTIVE_CONFIG="$INSTALL_PREFIX/etc/dnscrypt-proxy.toml"
if [ -f "$SERVICE" ]; then
    ACTIVE_CONFIG="$(/usr/bin/plutil -extract ProgramArguments.2 raw -o - "$SERVICE")"
fi
case "$ACTIVE_CONFIG" in "$INSTALL_PREFIX/etc/dnscrypt-proxy.toml"|"$CONFIG") ;; *) echo 'Configuration active inattendue.' >&2; exit 1 ;; esac
if [ "$ACTIVE_CONFIG" != "$CONFIG" ]; then /usr/bin/install -m 644 -o root -g wheel "$ACTIVE_CONFIG" "$CONFIG"; fi
/usr/bin/install -m 755 -o root -g wheel "$INSTALL_PREFIX/sbin/dnscrypt-proxy" "$PROXY.new"
/bin/mv -f "$PROXY.new" "$PROXY"
"$PROXY" -config "$CONFIG" -check
cat > "$ADMIN_DIR/new-service.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>sh.brew.dnscrypt-proxy</string>
<key>ProgramArguments</key><array><string>$PROXY</string><string>-config</string><string>$CONFIG</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>WorkingDirectory</key><string>$ADMIN_BASE</string>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$ADMIN_DIR/new-service.plist"
/bin/launchctl bootout system/sh.brew.dnscrypt-proxy >/dev/null 2>&1 || true
/usr/bin/install -m 644 -o root -g wheel "$ADMIN_DIR/new-service.plist" "$SERVICE"
/bin/launchctl bootstrap system "$SERVICE"
/bin/sleep 1
# A grep -q pipeline can close early and make launchctl return SIGPIPE (141)
# under pipefail, falsely rolling back an otherwise successful installation.
/bin/launchctl print system/sh.brew.dnscrypt-proxy > "$ADMIN_DIR/service-status.txt"
/usr/bin/grep -q 'state = running' "$ADMIN_DIR/service-status.txt"
/usr/bin/install -m 440 -o root -g wheel "$STAGE_DIR/sudoers" "$RULE"
# Validate only this app's rule. Pre-existing unrelated rules may have their
# own permission errors; they must not make this installation roll back.
/usr/sbin/visudo -cf "$RULE"
trap - EXIT
INSTALL
chmod 700 "$STAGE_DIR/install.sh"
export DNS_MANAGER_INSTALL_SCRIPT="$STAGE_DIR/install.sh"
/usr/bin/osascript <<'APPLESCRIPT'
set installationScript to system attribute "DNS_MANAGER_INSTALL_SCRIPT"
do shell script "/bin/bash " & quoted form of installationScript with administrator privileges
APPLESCRIPT
/usr/bin/sudo -n /Library/PrivilegedHelperTools/org.dnsmanager.admin '{"action":"status"}'
