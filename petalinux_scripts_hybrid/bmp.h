// =============================================================================
// bmp.h
// Minimal BMP reader/writer for 24-bit RGB files. Reading converts to 8-bit
// grayscale via Rec. 601 luminance; writing produces 24-bit BGR with
// R=G=B=value so the file opens as a normal image in any viewer.
// =============================================================================
#ifndef BMP_H
#define BMP_H

#include <stdint.h>

// Read a 24-bit BMP from `path`, convert to 8-bit grayscale, allocate
// *gray (caller frees with free()), and return the image dimensions.
// Returns 0 on success, -1 on any failure with a diagnostic to stderr.
int bmp_read_gray(const char *path, uint8_t **gray, int *H, int *W);

// Write an 8-bit grayscale buffer as a 24-bit BMP (R=G=B=value).
// Returns 0 on success, -1 on failure.
int bmp_write_gray(const char *path, const uint8_t *gray, int H, int W);

#endif  // BMP_H
