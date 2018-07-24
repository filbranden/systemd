/* SPDX-License-Identifier: LGPL-2.1+ */

#include "config.h"

#if ! HAVE_SELINUX
#error systemd-pwdlock is only built when SELinux is enabled.
#endif

#include <selinux/selinux.h>
#include <stdlib.h>
#include <string.h>

#include "exit-status.h"
#include "parse-util.h"
#include "selinux-util.h"
#include "socket-util.h"
#include "user-util.h"

int main(int argc, char *argv[]) {
        const char *root;
        const char *fdstr;
        char *selinux_context;
        int transport_fd;
        int lock_fd;
        int r;

        log_set_target(LOG_TARGET_AUTO);
        log_parse_environment();
        log_open();
        log_info("Starting systemd-pwdlock");

        if (argc < 1 || argc > 2) {
                log_error("Expecting a single optional argument, but got argc=%d instead", argc);
                return EXIT_FAILURE;
        }
        root = argv[1];

        fdstr = secure_getenv("SYSTEMD_PWDLOCK_TRANSPORT_FD");
        if (!fdstr) {
                log_error("Need environment variable SYSTEMD_PWDLOCK_TRANSPORT_FD to be set.");
                return EXIT_FAILURE;
        }

        r = safe_atoi(fdstr, &transport_fd);
        if (r < 0) {
                log_error_errno(r, "Can't parse fd [%s]", fdstr);
                return EXIT_FAILURE;
        }

        r = mac_selinux_init();
        if (r < 0) {
                log_error_errno(errno, "Failed to initalize SELinux: %m");
                return EXIT_FAILURE;
        }

        /* Actually take the lock on /etc/.pwd.lock here. */
        r = take_etc_passwd_lock(root);
        if (r < 0) {
                int error = r;
                /* Send the errno through the unix socket, as data. */
                if (send(transport_fd, &error, sizeof(error), 0) < 0) {
                        log_error_errno(-errno, "Failed to send error information (%s) through the socket fd %d: %m", strerror(-error), transport_fd);
                        return EXIT_FAILURE;
                }
                log_error_errno(error, "Taking .pwd.lock failed with: %s", strerror(-error));
                return EXIT_SUCCESS;
        }
        lock_fd = r;

        /* We need to set a SELinux context on the fd before returning it,
         * otherwise SELinux will complain about PID 1 having an open FD
         * to a file with the passwd_file_t context.
         *
         * Use the context of the /run/systemd directory (init_var_run_t),
         * which looks reasonable. (The selinux-policy must agree to this
         * relabeling.)
         *
         * To prevent hardcoding the SELinux context here, get it by
         * reading it from the /run/systemd directory.
         */
        r = getfilecon("/run/systemd", &selinux_context);
        if (r < 0) {
                log_error_errno(errno, "Failed to get SELinux context of /run/systemd: %m");
                return EXIT_FAILURE;
        }
        r = fsetfilecon(lock_fd, selinux_context);
        if (r < 0) {
                log_error_errno(errno, "Failed to set SELinux context %s on lock fd: %m", selinux_context);
                freecon(selinux_context);
                return EXIT_FAILURE;
        }
        freecon(selinux_context);

        /* Everything successful, so just send the FD to the lock file
         * back to systemd through the unix socket. */
        r = send_one_fd(transport_fd, lock_fd, MSG_DONTWAIT);
        if (r < 0) {
                log_error_errno(r, "Failed to send lock file descriptor %d through the socket fd %d: %m", lock_fd, transport_fd);
                return EXIT_FAILURE;
        }

        log_info("Successfully locked file and passed its FD %d to systemd.", lock_fd);
        return EXIT_SUCCESS;
}
