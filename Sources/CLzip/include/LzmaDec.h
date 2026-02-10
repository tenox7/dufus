/* LzmaDec.h -- LZMA Decoder
2009-02-07 : Igor Pavlov : Public domain */

#ifndef LZMADEC_H
#define LZMADEC_H

#include "lzip.h"

#define LZMA_PROPS_SIZE 5
#define LZMA_REQUIRED_INPUT_MAX 20

typedef struct
{
  int *probs;
  uint8_t *dic;
  const uint8_t *buf;
  uint32_t range, code;
  uint32_t dicPos;
  uint32_t dicBufSize;
  uint32_t processedPos;
  uint32_t checkDicSize;
  unsigned lc, lp, pb;
  State state;
  uint32_t reps[4];
  unsigned remainLen;
  uint32_t numProbs;
  unsigned tempBufSize;
  bool needFlush;
  uint8_t tempBuf[LZMA_REQUIRED_INPUT_MAX];
} CLzmaDec;

typedef enum
{
  LZMA_FINISH_ANY,
  LZMA_FINISH_END
} ELzmaFinishMode;

typedef enum
{
  LZMA_STATUS_NOT_SPECIFIED,
  LZMA_STATUS_FINISHED_WITH_MARK,
  LZMA_STATUS_NOT_FINISHED,
  LZMA_STATUS_NEEDS_MORE_INPUT,
  LZMA_STATUS_MAYBE_FINISHED_WITHOUT_MARK
} ELzmaStatus;

bool LzmaDec_Init(CLzmaDec *p, const uint8_t *raw_props);
void LzmaDec_Free(CLzmaDec *p);

bool LzmaDec_DecodeToBuf( CLzmaDec *p, uint8_t *dest, uint32_t *destLen,
                          const uint8_t *src, uint32_t *srcLen,
                          ELzmaFinishMode finishMode, ELzmaStatus *status );

#endif
