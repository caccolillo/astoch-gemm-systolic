// =============================================================================
// bmp.c -- 24-bit BMP I/O with grayscale conversion / writing.
// =============================================================================
#include "bmp.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma pack(push, 1)
struct bmp_file_header {
    uint16_t bf_type;
    uint32_t bf_size;
    uint16_t bf_reserved1;
    uint16_t bf_reserved2;
    uint32_t bf_off_bits;
};
struct bmp_info_header {
    uint32_t bi_size;
    int32_t  bi_width;
    int32_t  bi_height;
    uint16_t bi_planes;
    uint16_t bi_bit_count;
    uint32_t bi_compression;
    uint32_t bi_size_image;
    int32_t  bi_xppm;
    int32_t  bi_yppm;
    uint32_t bi_clr_used;
    uint32_t bi_clr_important;
};
#pragma pack(pop)

int bmp_read_gray(const char *path, uint8_t **gray, int *H, int *W)
{
    FILE *f = fopen(path, "rb");
    if (!f) { perror("bmp open"); return -1; }
    struct bmp_file_header fh;
    struct bmp_info_header ih;
    if (fread(&fh, sizeof(fh), 1, f) != 1 ||
        fread(&ih, sizeof(ih), 1, f) != 1) {
        fprintf(stderr, "BMP header read failed\n");
        fclose(f); return -1;
    }
    if (fh.bf_type != 0x4D42) {
        fprintf(stderr, "Not a BMP (magic 0x%04X)\n", fh.bf_type);
        fclose(f); return -1;
    }
    if (ih.bi_bit_count != 24 || ih.bi_compression != 0) {
        fprintf(stderr, "Only 24-bit uncompressed BMPs are supported "
                        "(got %d-bit, compression=%u)\n",
                        ih.bi_bit_count, ih.bi_compression);
        fclose(f); return -1;
    }
    int w = ih.bi_width;
    int h = abs(ih.bi_height);
    int bottom_up = (ih.bi_height > 0);
    int row_bytes = (w * 3 + 3) & ~3;

    fseek(f, fh.bf_off_bits, SEEK_SET);
    uint8_t *g = malloc((size_t)h * w);
    if (!g) { fclose(f); return -1; }
    uint8_t *row = malloc(row_bytes);
    if (!row) { free(g); fclose(f); return -1; }

    for (int r_file = 0; r_file < h; r_file++) {
        if (fread(row, row_bytes, 1, f) != 1) {
            fprintf(stderr, "BMP truncated at row %d\n", r_file);
            free(row); free(g); fclose(f); return -1;
        }
        int r_img = bottom_up ? (h - 1 - r_file) : r_file;
        for (int c = 0; c < w; c++) {
            int b  = row[c*3 + 0];
            int gn = row[c*3 + 1];
            int rd = row[c*3 + 2];
            // Rec. 601 luminance with rounding.
            int y = (299*rd + 587*gn + 114*b + 500) / 1000;
            if (y > 255) y = 255;
            g[r_img * w + c] = (uint8_t)y;
        }
    }
    free(row);
    fclose(f);
    *gray = g;
    *H = h;
    *W = w;
    return 0;
}

int bmp_write_gray(const char *path, const uint8_t *gray, int H, int W)
{
    int row_bytes = (W * 3 + 3) & ~3;
    int pad = row_bytes - W * 3;
    uint32_t pixel_bytes = (uint32_t)row_bytes * H;

    struct bmp_file_header fh = {
        .bf_type     = 0x4D42,
        .bf_size     = sizeof(fh) + sizeof(struct bmp_info_header) + pixel_bytes,
        .bf_off_bits = sizeof(fh) + sizeof(struct bmp_info_header)
    };
    struct bmp_info_header ih = {
        .bi_size       = sizeof(ih),
        .bi_width      = W,
        .bi_height     = H,
        .bi_planes     = 1,
        .bi_bit_count  = 24,
        .bi_size_image = pixel_bytes
    };

    FILE *f = fopen(path, "wb");
    if (!f) { perror("bmp create"); return -1; }
    fwrite(&fh, sizeof(fh), 1, f);
    fwrite(&ih, sizeof(ih), 1, f);

    uint8_t padbuf[3] = {0,0,0};
    for (int r_img = H - 1; r_img >= 0; r_img--) {
        for (int c = 0; c < W; c++) {
            uint8_t v = gray[r_img * W + c];
            uint8_t pix[3] = {v, v, v};
            fwrite(pix, 3, 1, f);
        }
        if (pad) fwrite(padbuf, pad, 1, f);
    }
    fclose(f);
    return 0;
}
