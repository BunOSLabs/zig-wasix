#include <errno.h>
#include <common/net.h>
#include <sys/socket.h>

#include <assert.h>
#include <wasi/api.h>
#include <errno.h>
#include <string.h>

int bind(int socket, const struct sockaddr *restrict addr, socklen_t addrlen) {
  __wasi_addr_port_t peer_addr;
  __wasi_errno_t error = sockaddr_to_wasi(addr, addrlen, &peer_addr);
  if (error != 0) {
	errno = error;
    return -1;
  }

  error = __wasi_sock_bind(socket, &peer_addr);
  if (error != 0) {
    errno = error;
    return -1;
  }

  return 0;
}
