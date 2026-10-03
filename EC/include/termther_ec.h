/* The EasyConnect engine's C ABI, implemented in EC/src/ffi.rs.
 *
 * Every char * returned belongs to the caller and is freed with
 * ec_string_free. Functions marked "blocks" do network I/O and must not run
 * where waiting is a problem. An error is reported as NULL or -1, with a
 * message in *error when error is not NULL. No function panics or exits. */
#ifndef TERMTHER_EC_H
#define TERMTHER_EC_H

#include <stdint.h>

typedef struct EcSession EcSession;

/* Logs in and opens the tunnel. totp_secret, interface and dns may be NULL
 * or empty. Blocks. */
EcSession *ec_login(const char *gateway, const char *username, const char *password,
                    const char *totp_secret, const char *interface, const char *dns,
                    char **error);

/* Stops the tunnel. The handle stays valid until ec_free, so calls still
 * running on other threads finish, with an error. */
void ec_close(const EcSession *session);
/* Stops the tunnel if it is still up and releases the handle. */
void ec_free(EcSession *session);

char *ec_address(const EcSession *session);
/* {"ip":[{"from","to","portMin","portMax","protocol"}],"domains":[],"dns":[]} */
char *ec_routing_json(const EcSession *session);
/* Why the tunnel stopped carrying traffic, or NULL while it still does. */
char *ec_failure(const EcSession *session);
void ec_set_underlay(const EcSession *session, const char *interface, const char *dns);

/* Resolves with the gateway's DNS servers, through the tunnel. Blocks. */
char *ec_resolve(const EcSession *session, const char *host, char **error);
/* A connected descriptor to host:port inside the tunnel, or -1. Blocks. */
int32_t ec_dial(const EcSession *session, const char *host, uint16_t port, char **error);

/* 0: an EasyConnect gateway, 1: something else, 2: unreachable. Blocks. */
int32_t ec_probe(const char *gateway, const char *interface, const char *dns, char **detail);

void ec_string_free(char *string);

#endif
