#ifndef WIPEFS_H
#define WIPEFS_H

#include <sys/types.h>

typedef struct __wipefs_ctx *wipefs_ctx;

int wipefs_alloc(int fd, size_t block_size, wipefs_ctx *handle);
int wipefs_include_blocks(wipefs_ctx handle, off_t block_offset, off_t nblocks);
int wipefs_except_blocks(wipefs_ctx handle, off_t block_offset, off_t nblocks);
int wipefs_wipe(wipefs_ctx handle);
void wipefs_free(wipefs_ctx *handle);

#include "recv_fd.h"

#endif
