/*
 * meminfo.c - SMBIOS Type 17 (Memory Device) parser
 *
 * Reads /sys/firmware/dmi/tables/DMI directly (no dmidecode needed,
 * world-readable on Linux 5.12+ / kernel 6.1+).
 *
 * Output per populated memory slot (one line each):
 *   size_mb|part_number|speed_mhz|ddr_type
 *
 * Build:
 *   gcc -O2 -static -o meminfo meminfo.c
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* SMBIOS memory type index -> string (per SMBIOS 3.x spec) */
static const char *MEM_TYPES[] = {
    "",             /* 0x00 - unused */
    "Other",        /* 0x01 */
    "Unknown",      /* 0x02 */
    "DRAM",         /* 0x03 */
    "EDRAM",        /* 0x04 */
    "VRAM",         /* 0x05 */
    "SRAM",         /* 0x06 */
    "RAM",          /* 0x07 */
    "ROM",          /* 0x08 */
    "FLASH",        /* 0x09 */
    "EEPROM",       /* 0x0A */
    "FEPROM",       /* 0x0B */
    "EPROM",        /* 0x0C */
    "CDRAM",        /* 0x0D */
    "3DRAM",        /* 0x0E */
    "SDRAM",        /* 0x0F */
    "SGRAM",        /* 0x10 */
    "RDRAM",        /* 0x11 */
    "DDR",          /* 0x12 */
    "DDR2",         /* 0x13 */
    "DDR2 FB-DIMM", /* 0x14 */
    "",             /* 0x15 Reserved */
    "",             /* 0x16 Reserved */
    "",             /* 0x17 Reserved */
    "DDR3",         /* 0x18 */
    "FBD2",         /* 0x19 */
    "DDR4",         /* 0x1A */
    "LPDDR",        /* 0x1B */
    "LPDDR2",       /* 0x1C */
    "LPDDR3",       /* 0x1D */
    "LPDDR4",       /* 0x1E */
    "",             /* 0x1F Logical non-volatile device */
    "HBM",          /* 0x20 */
    "HBM2",         /* 0x21 */
    "DDR5",         /* 0x22 */
    "LPDDR5",       /* 0x23 */
};
#define MEM_TYPES_COUNT ((int)(sizeof(MEM_TYPES)/sizeof(MEM_TYPES[0])))

/*
 * Get the n-th (1-based) string from the SMBIOS string table
 * that immediately follows the formatted structure data.
 */
static const char *get_smbios_string(const uint8_t *base, uint8_t struct_len, uint8_t idx)
{
    const uint8_t *s;
    int cur;

    if (idx == 0)
        return "";

    s = base + struct_len;
    for (cur = 1; cur < idx && *s != '\0'; cur++) {
        while (*s != '\0')
            s++;
        s++; /* skip null terminator */
    }
    return (const char *)s;
}

static uint16_t le16(const uint8_t *p)
{
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t le32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

int main(void)
{
    static const char *DMI_PATH = "/sys/firmware/dmi/tables/DMI";
    FILE *f;
    long file_size;
    uint8_t *table;
    const uint8_t *p, *end;

    f = fopen(DMI_PATH, "rb");
    if (!f) {
        fprintf(stderr, "Cannot open %s\n", DMI_PATH);
        return 1;
    }

    fseek(f, 0, SEEK_END);
    file_size = ftell(f);
    fseek(f, 0, SEEK_SET);

    if (file_size <= 0) {
        fclose(f);
        return 1;
    }

    table = malloc((size_t)file_size);
    if (!table) {
        fclose(f);
        return 1;
    }

    if ((long)fread(table, 1, (size_t)file_size, f) != file_size) {
        free(table);
        fclose(f);
        return 1;
    }
    fclose(f);

    p   = table;
    end = table + file_size;

    while (p < end - 4) {
        uint8_t  type     = p[0];
        uint8_t  slen     = p[1];    /* structure length (formatted area only) */

        if (slen < 4 || p + slen > end)
            break;

        if (type == 127) /* End-of-table */
            break;

        /* Type 17: Memory Device (SMBIOS 2.1+ minimum length = 0x1C = 28) */
        if (type == 17 && slen >= 0x1C) {
            uint16_t raw_size   = le16(p + 12); /* offset 0x0C */
            uint8_t  mem_type   = p[18];         /* offset 0x12 */
            uint16_t speed      = le16(p + 21);  /* offset 0x15 - max speed */
            uint8_t  pn_idx     = p[26];         /* offset 0x1A - part number */

            /* Configured speed (SMBIOS 2.7+, offset 0x20) preferred */
            uint16_t conf_speed = (slen >= 34) ? le16(p + 32) : 0;

            uint32_t size_mb = 0;
            if (raw_size == 0x7FFF && slen >= 32) {
                /* Extended size (>=32 GB slots), unit = MB */
                size_mb = le32(p + 28);
            } else if (raw_size != 0 && raw_size != 0xFFFF) {
                if (raw_size & 0x8000) {
                    /* Granularity = KB */
                    size_mb = (raw_size & 0x7FFF) / 1024;
                } else {
                    /* Granularity = MB */
                    size_mb = raw_size;
                }
            }

            /* Only output populated slots */
            if (size_mb > 0) {
                const char *pn    = get_smbios_string(p, slen, pn_idx);
                const char *dtype = (mem_type < MEM_TYPES_COUNT) ? MEM_TYPES[mem_type] : "";
                uint16_t disp_spd = conf_speed ? conf_speed : speed;

                /* Strip leading/trailing spaces from part number */
                while (*pn == ' ') pn++;
                const char *pn_end = pn + strlen(pn);
                while (pn_end > pn && *(pn_end - 1) == ' ') pn_end--;

                printf("%u|%.*s|%u|%s\n",
                       size_mb,
                       (int)(pn_end - pn), pn,
                       disp_spd,
                       dtype);
            }
        }

        /* Advance: skip formatted area + strings section (terminated by \0\0) */
        p += slen;
        while (p < end - 1 && !(p[0] == '\0' && p[1] == '\0'))
            p++;
        p += 2; /* skip the double-null terminator */
    }

    free(table);
    return 0;
}
