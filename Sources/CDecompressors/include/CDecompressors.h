#ifndef CDECOMPRESSORS_H
#define CDECOMPRESSORS_H

#include <zlib.h>
#include <bzlib.h>

#include <stdint.h>
#include <stddef.h>

// lzma — minimal declarations matching xz-utils ABI
// SDK ships liblzma.dylib but no header

typedef enum {
    LZMA_OK                = 0,
    LZMA_STREAM_END        = 1,
    LZMA_NO_CHECK          = 2,
    LZMA_UNSUPPORTED_CHECK = 3,
    LZMA_GET_CHECK         = 4,
    LZMA_MEM_ERROR         = 5,
    LZMA_MEMLIMIT_ERROR    = 6,
    LZMA_FORMAT_ERROR      = 7,
    LZMA_OPTIONS_ERROR     = 8,
    LZMA_DATA_ERROR        = 9,
    LZMA_BUF_ERROR         = 10,
    LZMA_PROG_ERROR        = 11,
} lzma_ret;

typedef enum {
    LZMA_RUN         = 0,
    LZMA_SYNC_FLUSH  = 1,
    LZMA_FULL_FLUSH  = 2,
    LZMA_FINISH      = 3,
    LZMA_FULL_BARRIER = 4,
} lzma_action;

#define LZMA_CONCATENATED 0x08

typedef struct {
    const uint8_t *next_in;
    size_t         avail_in;
    uint64_t       total_in;
    uint8_t       *next_out;
    size_t         avail_out;
    uint64_t       total_out;
    const void    *allocator;
    void          *internal;
    void          *reserved_ptr1;
    void          *reserved_ptr2;
    void          *reserved_ptr3;
    void          *reserved_ptr4;
    uint64_t       reserved_int1;
    uint64_t       reserved_int2;
    size_t         reserved_int3;
    size_t         reserved_int4;
    uint32_t       reserved_enum1;
    uint32_t       reserved_enum2;
} lzma_stream;

lzma_ret lzma_stream_decoder(lzma_stream *strm, uint64_t memlimit, uint32_t flags);
lzma_ret lzma_code(lzma_stream *strm, lzma_action action);
void     lzma_end(lzma_stream *strm);

#endif
