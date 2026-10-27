#!/bin/bash
# Installs the root helper and its sudoers rule. Run once, by hand, from Terminal:
#   sudo ./install-root.sh [path/to/multitul-ctl]
# Safe to re-run after every build that changes multitul-ctl.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "запусти через sudo: sudo $0" >&2
    exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
USER_NAME="${SUDO_USER:?run via sudo}"
USER_HOME="$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | awk '{print $2}')"
BIN_SRC="${1:-$USER_HOME/Applications/Multitul.app/Contents/Resources/multitul-ctl}"
SUDOERS_SRC="$HERE/multitul.sudoers"
[ -f "$SUDOERS_SRC" ] || SUDOERS_SRC="$USER_HOME/Applications/Multitul.app/Contents/Resources/root/multitul.sudoers"

BIN_DST=/usr/local/libexec/multitul-ctl
SUDOERS_DST=/etc/sudoers.d/multitul

[ -f "$BIN_SRC" ] || { echo "нет бинарника: $BIN_SRC" >&2; exit 1; }
[ -f "$SUDOERS_SRC" ] || { echo "нет файла правила: $SUDOERS_SRC" >&2; exit 1; }

TMP_SUDOERS="$(mktemp /tmp/multitul-sudoers.XXXXXX)"
trap 'rm -f "$TMP_SUDOERS"' EXIT
sed "s/__USER__/$USER_NAME/" "$SUDOERS_SRC" > "$TMP_SUDOERS"
chmod 440 "$TMP_SUDOERS"
if ! /usr/sbin/visudo -cf "$TMP_SUDOERS" >/dev/null; then
    echo "visudo отверг правило, ничего не установлено" >&2
    exit 1
fi

mkdir -p /usr/local/libexec
chown root:wheel /usr/local/libexec
chmod 755 /usr/local/libexec

install -o root -g wheel -m 755 "$BIN_SRC" "$BIN_DST.new"
mv -f "$BIN_DST.new" "$BIN_DST"

install -o root -g wheel -m 440 "$TMP_SUDOERS" "$SUDOERS_DST.new"
/usr/sbin/visudo -cf "$SUDOERS_DST.new" >/dev/null
mv -f "$SUDOERS_DST.new" "$SUDOERS_DST"

echo "установлено: $BIN_DST, $SUDOERS_DST"
echo "проверка: sudo -n $BIN_DST selftest"
sudo -u "$USER_NAME" sudo -n "$BIN_DST" selftest
