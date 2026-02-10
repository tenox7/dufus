#include "recv_fd.h"
#include <sys/socket.h>
#include <string.h>

int recv_fd(int sock) {
    struct msghdr msg;
    char buf[1];
    struct iovec iov;
    char cmsgbuf[CMSG_SPACE(sizeof(int))];

    memset(&msg, 0, sizeof(msg));
    iov.iov_base = buf;
    iov.iov_len = 1;
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cmsgbuf;
    msg.msg_controllen = sizeof(cmsgbuf);

    if (recvmsg(sock, &msg, 0) < 0)
        return -1;

    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    if (!cmsg || cmsg->cmsg_type != SCM_RIGHTS)
        return -1;

    int fd;
    memcpy(&fd, CMSG_DATA(cmsg), sizeof(fd));
    return fd;
}
