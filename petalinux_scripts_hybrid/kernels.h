// =============================================================================
// kernels.h
// Kernel library API: lookup, listing, SC encoding/decoding.
// =============================================================================
#ifndef KERNELS_H
#define KERNELS_H

#include "gemm_image.h"

// All kernels in a NULL-terminated array (defined in kernels.c).
extern const struct kernel_def gemm_kernels[];

// Look up by name. Returns NULL if not found.
const struct kernel_def *kernel_find(const char *name);

// Print a categorised listing of all kernels to stderr (used by --list).
void kernel_list_all(void);

// Bipolar SC encoder: map x in [-1, +1] to a 16-bit unsigned probability
// stream initial value used by the FPGA's stream generators.
uint16_t kernel_enc(double x);

// Decode a raw c_flat (sign-extended int32) into a signed double representing
// the convolution result. For averaging kernels this lands in roughly
// [0, 255]; for edge/emboss kernels it can be negative or large.
double  kernel_decode_signed(int32_t cf,
                             const struct kernel_def *kern,
                             int hw_kw);

// Map a signed convolution result to a uint8 pixel, applying the kernel's
// display rule (abs, offset, etc.). For DECODE_MAGNITUDE this is a no-op
// passthrough -- the caller is responsible for combining the two passes.
uint8_t kernel_signed_to_pixel(double v, enum decode_mode mode);

#endif  // KERNELS_H
