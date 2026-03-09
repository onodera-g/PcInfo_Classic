/*
 * fbprint.c - PSF2フォントを使ってフレームバッファに直接テキストを描画
 * stdin を読んでUTF-8テキストを/dev/fb0に描画する
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <zlib.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/fb.h>
#include <stdint.h>

#define PSF2_MAGIC 0x864ab572
#define MAX_GLYPHS 4096

typedef struct {
    uint32_t magic, version, hdrsize, flags, numglyph, bytesperglyph, height, width;
} PSF2Header;

static uint8_t *fb = NULL;
static int fb_width, fb_height, fb_bpp, fb_line;
static uint8_t *font_data = NULL;
static PSF2Header fhdr;
static uint32_t unicode_map[0x10000]; // codepoint -> glyph index
static int cursor_x = 0, cursor_y = 0;

/* ANSIエスケープシーケンスの色テーブル（16色、RGB565風） */
static uint32_t ansi_colors[16] = {
    0x000000, 0xAA0000, 0x00AA00, 0xAA5500,
    0x0000AA, 0xAA00AA, 0x00AAAA, 0xAAAAAA,
    0x555555, 0xFF5555, 0x55FF55, 0xFFFF55,
    0x5555FF, 0xFF55FF, 0x55FFFF, 0xFFFFFF,
};
static uint32_t fg_color = 0xAAAAAA;
static uint32_t bg_color = 0x000000;

static uint32_t pack_color(uint32_t rgb) {
    uint8_t r = (rgb >> 16) & 0xFF;
    uint8_t g = (rgb >> 8) & 0xFF;
    uint8_t b = rgb & 0xFF;
    if (fb_bpp == 2) {
        return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
    } else if (fb_bpp == 3 || fb_bpp == 4) {
        return rgb;
    }
    return rgb;
}

static void put_pixel(int x, int y, uint32_t color) {
    if (x < 0 || x >= fb_width || y < 0 || y >= fb_height) return;
    uint8_t *p = fb + y * fb_line + x * fb_bpp;
    uint32_t c = pack_color(color);
    if (fb_bpp == 2) {
        p[0] = c & 0xFF;
        p[1] = (c >> 8) & 0xFF;
    } else if (fb_bpp == 3) {
        p[0] = c & 0xFF;
        p[1] = (c >> 8) & 0xFF;
        p[2] = (c >> 16) & 0xFF;
    } else if (fb_bpp == 4) {
        p[0] = c & 0xFF;
        p[1] = (c >> 8) & 0xFF;
        p[2] = (c >> 16) & 0xFF;
        p[3] = 0;
    }
}

static int glyph_width(uint32_t cp) {
    /* CJK unified ideographs and common ranges */
    if (cp >= 0x1100 && cp <= 0x115F) return 2; // Hangul
    if (cp >= 0x2E80 && cp <= 0x303E) return 2; // CJK Radicals
    if (cp >= 0x3040 && cp <= 0x33FF) return 2; // Hiragana, Katakana, etc.
    if (cp >= 0x3400 && cp <= 0x4DBF) return 2; // CJK Ext-A
    if (cp >= 0x4E00 && cp <= 0x9FFF) return 2; // CJK Unified
    if (cp >= 0xAC00 && cp <= 0xD7AF) return 2; // Hangul
    if (cp >= 0xF900 && cp <= 0xFAFF) return 2; // CJK Compat
    if (cp >= 0xFE10 && cp <= 0xFE6F) return 2; // CJK Compat Forms
    if (cp >= 0xFF01 && cp <= 0xFF60) return 2; // Fullwidth
    if (cp >= 0xFFE0 && cp <= 0xFFE6) return 2; // Fullwidth
    return 1;
}

static void draw_glyph(uint32_t codepoint) {
    uint32_t idx = unicode_map[codepoint < 0x10000 ? codepoint : 0];
    if (idx == 0xFFFFFFFF) idx = 0; /* fallback to glyph 0 */
    
    uint8_t *glyph = font_data + idx * fhdr.bytesperglyph;
    int gw = fhdr.width;  /* 16 */
    int gh = fhdr.height; /* 16 */
    int bytes_per_row = (gw + 7) / 8;
    int ww = glyph_width(codepoint);
    
    for (int row = 0; row < gh; row++) {
        for (int col = 0; col < gw; col++) {
            int byte_idx = row * bytes_per_row + col / 8;
            int bit = 7 - (col % 8);
            int set = (glyph[byte_idx] >> bit) & 1;
            put_pixel(cursor_x + col, cursor_y + row, set ? fg_color : bg_color);
        }
    }
    /* 16px wide font: CJK (ww=2) advances 16px, ASCII (ww=1) advances 8px */
    cursor_x += (ww == 2) ? gw : gw / 2;
}

static void newline(void) {
    cursor_x = 0;
    cursor_y += fhdr.height;
    if (cursor_y + (int)fhdr.height > fb_height) {
        /* scroll: shift framebuffer up by one line */
        int line_bytes = fb_line;
        int char_h = fhdr.height;
        memmove(fb, fb + char_h * line_bytes, (fb_height - char_h) * line_bytes);
        /* clear last line */
        memset(fb + (fb_height - char_h) * line_bytes, 0, char_h * line_bytes);
        cursor_y -= char_h;
    }
}

/* Parse ANSI escape: ESC [ ... m */
static int parse_ansi(const uint8_t *buf, int len) {
    if (len < 2) return 0;
    if (buf[0] != '\033' || buf[1] != '[') return 0;
    int i = 2;
    int params[8]; int np = 0;
    params[0] = 0;
    while (i < len) {
        if (buf[i] >= '0' && buf[i] <= '9') {
            params[np] = params[np] * 10 + (buf[i] - '0');
        } else if (buf[i] == ';') {
            if (np < 7) { np++; params[np] = 0; }
        } else {
            /* terminator */
            char cmd = buf[i];
            int seq_len = i + 1;
            if (cmd == 'm') {
                for (int j = 0; j <= np; j++) {
                    int p = params[j];
                    if (p == 0) { fg_color = 0xAAAAAA; bg_color = 0x000000; }
                    else if (p == 1) { /* bold - brighten fg */ fg_color |= 0x555555; }
                    else if (p >= 30 && p <= 37) fg_color = ansi_colors[p - 30];
                    else if (p >= 90 && p <= 97) fg_color = ansi_colors[p - 90 + 8];
                    else if (p == 39) fg_color = 0xAAAAAA;
                    else if (p >= 40 && p <= 47) bg_color = ansi_colors[p - 40];
                    else if (p == 49) bg_color = 0x000000;
                }
            }
            return seq_len;
        }
        i++;
    }
    return 0;
}

/* Decode one UTF-8 codepoint from buf, return bytes consumed */
static int decode_utf8(const uint8_t *buf, int len, uint32_t *cp) {
    if (len < 1) return 0;
    uint8_t b = buf[0];
    if (b < 0x80) { *cp = b; return 1; }
    if (b < 0xC0) { *cp = 0xFFFD; return 1; } /* continuation byte */
    if (b < 0xE0) {
        if (len < 2) return 0;
        *cp = ((b & 0x1F) << 6) | (buf[1] & 0x3F);
        return 2;
    }
    if (b < 0xF0) {
        if (len < 3) return 0;
        *cp = ((b & 0x0F) << 12) | ((buf[1] & 0x3F) << 6) | (buf[2] & 0x3F);
        return 3;
    }
    if (len < 4) return 0;
    *cp = ((b & 0x07) << 18) | ((buf[1] & 0x3F) << 12) | ((buf[2] & 0x3F) << 6) | (buf[3] & 0x3F);
    return 4;
}

int main(int argc, char **argv) {
    const char *fb_dev = "/dev/fb0";
    const char *font_path = "/usr/share/consolefonts/unifont_ja.psf.gz";
    
    if (argc >= 2) font_path = argv[1];
    if (argc >= 3) fb_dev = argv[2];

    /* Open framebuffer */
    int fbfd = open(fb_dev, O_RDWR);
    if (fbfd < 0) { perror("open fb"); return 1; }
    struct fb_var_screeninfo vinfo;
    struct fb_fix_screeninfo finfo;
    ioctl(fbfd, FBIOGET_VSCREENINFO, &vinfo);
    ioctl(fbfd, FBIOGET_FSCREENINFO, &finfo);
    fb_width = vinfo.xres;
    fb_height = vinfo.yres;
    fb_bpp = vinfo.bits_per_pixel / 8;
    fb_line = finfo.line_length;
    size_t fb_size = fb_line * fb_height;
    fb = mmap(NULL, fb_size, PROT_READ | PROT_WRITE, MAP_SHARED, fbfd, 0);
    if (fb == MAP_FAILED) { perror("mmap fb"); return 1; }
    memset(fb, 0, fb_size);

    /* Load PSF2 font */
    gzFile gz = gzopen(font_path, "rb");
    if (!gz) { fprintf(stderr, "cannot open font: %s\n", font_path); return 1; }
    static uint8_t raw[1<<21]; int raw_len = 0, n; /* 2MB buffer for large fonts */
    while ((n = gzread(gz, raw + raw_len, sizeof(raw) - raw_len)) > 0) raw_len += n;
    gzclose(gz);
    
    memcpy(&fhdr, raw, sizeof(PSF2Header));
    if (fhdr.magic != PSF2_MAGIC) { fprintf(stderr, "bad PSF2 magic\n"); return 1; }
    
    int glyph_end = fhdr.hdrsize + fhdr.numglyph * fhdr.bytesperglyph;
    font_data = raw + fhdr.hdrsize;
    
    /* Build unicode map */
    memset(unicode_map, 0xFF, sizeof(unicode_map));
    uint8_t *ut = raw + glyph_end;
    int ut_len = raw_len - glyph_end;
    int ui = 0; uint32_t glyph_idx = 0;
    while (ui < ut_len && glyph_idx < fhdr.numglyph) {
        if (ut[ui] == 0xFF) { glyph_idx++; ui++; continue; }
        if (ut[ui] == 0xFE) { ui++; continue; }
        uint32_t cp; int bytes = decode_utf8(ut + ui, ut_len - ui, &cp);
        if (bytes == 0) break;
        if (cp < 0x10000) unicode_map[cp] = glyph_idx;
        ui += bytes;
    }

    /* Process stdin */
    uint8_t buf[4096]; int buf_len = 0;
    while (1) {
        n = read(0, buf + buf_len, sizeof(buf) - buf_len - 1);
        if (n <= 0) break;
        buf_len += n;
        int i = 0;
        while (i < buf_len) {
            /* Check for ESC sequences */
            if (buf[i] == '\033') {
                int esc_len = parse_ansi(buf + i, buf_len - i);
                if (esc_len > 0) { i += esc_len; continue; }
                /* incomplete escape: wait for more data */
                if (buf_len - i < 16) break;
                i++; continue;
            }
            if (buf[i] == '\n') {
                newline();
                i++; continue;
            }
            if (buf[i] == '\r') { cursor_x = 0; i++; continue; }
            if (buf[i] == '\033') { i++; continue; } /* skip lone ESC */
            if (buf[i] < 0x20) { i++; continue; } /* skip control chars */
            
            /* Decode UTF-8 */
            uint32_t cp; int bytes = decode_utf8(buf + i, buf_len - i, &cp);
            if (bytes == 0) break; /* incomplete sequence */
            draw_glyph(cp);
            /* wrap at right edge */
            if (cursor_x + (int)fhdr.width > fb_width) newline();
            i += bytes;
        }
        memmove(buf, buf + i, buf_len - i);
        buf_len -= i;
    }
    munmap(fb, fb_size);
    close(fbfd);
    return 0;
}
