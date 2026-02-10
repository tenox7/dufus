#ifndef LZIP_H
#define LZIP_H

#include <stdbool.h>
#include <stdint.h>

typedef int State;

enum {
  min_dictionary_bits = 12,
  min_dictionary_size = 1 << min_dictionary_bits,
  max_dictionary_bits = 29,
  max_dictionary_size = 1 << max_dictionary_bits
};

#endif
