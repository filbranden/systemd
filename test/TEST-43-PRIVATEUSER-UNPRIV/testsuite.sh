#!/bin/bash
set -ex
set -o pipefail

systemd-analyze log-level debug

runas() {
    declare userid=$1
    shift
    su "$userid" -c 'XDG_RUNTIME_DIR=/run/user/$UID "$@"' -- sh "$@"
}

runas nobody systemctl --user --wait is-system-running

runas nobody systemd-run --user --unit=test-private-users \
    -p PrivateUsers=yes -P echo hello

runas nobody systemd-run --user --unit=test-private-tmp-innerfile \
    -p PrivateUsers=yes -p PrivateTmp=yes \
    -P touch /tmp/innerfile.txt
# File should not exist outside the job's tmp directory.
test ! -e /tmp/innerfile.txt

touch /tmp/outerfile.txt
# File should not appear in unit's private tmp.
runas nobody systemd-run --user --unit=test-private-tmp-outerfile \
    -p PrivateUsers=yes -p PrivateTmp=yes \
    -P test ! -e /tmp/outerfile.txt

# Confirm that creating a file in home works
runas nobody systemd-run --user --unit=test-unprotected-home \
    -P touch /home/nobody/works.txt
test -e /home/nobody/works.txt

# Confirm that creating a file in home is blocked under read-only
runas nobody systemd-run --user --unit=test-protect-home-read-only \
    -p PrivateUsers=yes -p ProtectHome=read-only \
    -P bash -c '
        test -e /home/nobody/works.txt
        ! touch /home/nobody/blocked.txt
    '
test ! -e /home/nobody/blocked.txt

# Check that tmpfs hides the whole directory
runas nobody systemd-run --user --unit=test-protect-home-tmpfs \
    -p PrivateUsers=yes -p ProtectHome=tmpfs \
    -P test ! -e /home/nobody

systemd-analyze log-level info

echo OK > /testok

exit 0
