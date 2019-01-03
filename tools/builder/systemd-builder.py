#!/usr/bin/python3

import argparse
import os
import pwd
import subprocess
import sys

BUILDER_USERNAME = 'builder'
BUILDER_SRC_TREE = '/systemd'
BUILDER_DST_TREE = '/build'

PROGNAME = 'systemd-builder'

class Error(Exception):
    """Error in systemd-builder execution."""

# User management: Functions to create user "builder" and re-run the script
# under that user, if called as "root" for an unprivileged operation. The
# uid/gid of user "builder" are derived from the permissions of the mounted
# destination tree under /build, in order to match uid/gid of user outside of
# the container.

def create_builder_user(uid, gid):
    subprocess.check_call(['groupadd', '-g', str(gid), BUILDER_USERNAME])
    subprocess.check_call(['useradd', '-m', '-u', str(uid), '-g', str(gid), BUILDER_USERNAME])

def reexec_unprivileged(uid, gid):
    os.setgroups([])
    os.setgid(gid)
    os.setuid(uid)
    sys.stdout.flush()
    sys.stderr.flush()
    os.execv(os.path.realpath(__file__), sys.argv)

def expected_builder_user_credentials():
    if not os.path.ismount(BUILDER_DST_TREE):
        raise Error('Expected build tree [{}] to be a mount.'.format(BUILDER_DST_TREE))
    st = os.stat(BUILDER_DST_TREE)
    if st.st_uid < 1000 or st.st_gid < 1000:
        raise Error('Build tree UID/GID outside of user range: {}/{}'.format(st.st_uid, st.st_gid))
    return (st.st_uid, st.st_gid)

def check_builder_user_exists(uid, gid):
    # Returns True if user builder already exists and matches uid/gid.
    # Returns False if user builder (or group) does not exist yet.
    # Raises an Error if user builder exists but does not match uid/gid.
    try:
        pw = pwd.getpwnam(BUILDER_USERNAME)
    except KeyError:
        return False
    if pw.pw_uid != uid or pw.pw_gid != gid:
        raise Error('User {} already exists but does not match expected UID/GID: '
                    'actual {}/{} != expected {}/{}'.format(BUILDER_USERNAME, pw.pw_uid, pw.pw_gid, uid, gid))

def must_run_as_root(cmd):
    if os.geteuid() != 0:
        raise Error('Command {} must run as root.'.format(cmd))

def rerun_as_builder():
    if os.geteuid() != 0:
        # Assume running under correct user if we're running as non-root.
        return
    uid, gid = expected_builder_user_credentials()
    if not check_builder_user_exists(uid, gid):
        create_builder_user(uid, gid)
    reexec_unprivileged(uid, gid)

# Argument parser: Implement subcommands for operations. For now "build" is the
# common one, but we also want to support "setup" for configure the
# systemd-builder container.
#
# This can be further extended with specialized build types, such as
# "cov-build" for Coverity and potentially other specialized build
# configurations.

def create_parser():
    parser = argparse.ArgumentParser(prog=PROGNAME)
    subparsers = parser.add_subparsers(dest='subcommand', help='subcommands')
    subparsers.add_parser('setup', help='set up container for builder')
    subparsers.add_parser('build', help='build source tree')
    return parser

# Subcommands: These implement the actual commands such as "build" and "setup".
# More commands can be added for specialized builders.

def cmd_setup():
    must_run_as_root('setup')
    os.mkdir(BUILDER_SRC_TREE)
    os.mkdir(BUILDER_DST_TREE)

def check_src_tree():
    if not os.path.ismount(BUILDER_SRC_TREE):
        raise Error('Expected source tree [{}] to be a mount.'.format(BUILDER_SRC_TREE))
    # Look for a well-known file in the source tree.
    if not os.path.exists(os.path.join(BUILDER_SRC_TREE, 'src/core/main.c')):
        raise Error('Source tree [{}] does not look like it contains systemd sources.'.format(BUILDER_SRC_TREE))

def cmd_build():
    rerun_as_builder()
    check_src_tree()
    subprocess.check_call(['meson', BUILDER_DST_TREE], cwd=BUILDER_SRC_TREE)
    subprocess.check_call(['ninja'], cwd=BUILDER_DST_TREE)

COMMANDS = {
    'setup': cmd_setup,
    'build': cmd_build,
}

def run_main():
    parser = create_parser()
    opts = parser.parse_args()
    COMMANDS[opts.subcommand]()

def main(args):
    try:
        run_main()
    except Error as e:
        print('{}: {}'.format(PROGNAME, e), file=sys.stderr)
        return 1

if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
