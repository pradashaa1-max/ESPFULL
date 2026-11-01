// Blind.mm — ослепляем Standarling: dyld, strstr, dlsym, dlopen, open
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <unistd.h>
#import <stdarg.h>
#import <string.h>
#import <stdio.h>
#import <limits.h>
#include "fishhook.h"

// ─── что скрываем ────────────────────────────────────────────────────────────
static const char* kHideImg[] = {
    "mark.dylib", "libhooker", "substitute", "substrate", "ellekit",
    NULL
};
static bool ShouldHideImg(const char* s) {
    if (!s) return false;
    for (int i = 0; kHideImg[i]; i++) if (strstr(s, kHideImg[i])) return true;
    return false;
}

static bool ShouldHideSym(const char* n) {
    if (!n) return false;
    if (strstr(n, "CoreUI_")) return true;
    if (strstr(n, "g_aim") || strstr(n, "g_silent")) return true;
    if (strstr(n, "g_esp") || strstr(n, "g_panel") || strstr(n, "g_fab")) return true;
    if (strstr(n, "g_bone") || strstr(n, "g_lang") || strstr(n, "g_menuColor")) return true;
    if (strstr(n, "g_hideRec") || strstr(n, "g_fov") || strstr(n, "g_smooth")) return true;
    if (strstr(n, "g_noRecoil") || strstr(n, "g_recoilPct")) return true;
    if (strstr(n, "g_menuOpen") || strstr(n, "CoreUI_SecureRoot")) return true;
    return false;
}

// ─── dyld ────────────────────────────────────────────────────────────────────
static uint32_t (*orig_count)(void);
static const char* (*orig_name)(uint32_t);
static const struct mach_header* (*orig_header)(uint32_t);

static uint32_t my_count(void) {
    uint32_t n = orig_count(), v = 0;
    for (uint32_t i = 0; i < n; i++) if (!ShouldHideImg(orig_name(i))) v++;
    return v;
}
static const char* my_name(uint32_t idx) {
    uint32_t n = orig_count(), v = 0;
    for (uint32_t i = 0; i < n; i++) {
        const char* nm = orig_name(i);
        if (ShouldHideImg(nm)) continue;
        if (v++ == idx) return nm;
    }
    return NULL;
}
static const struct mach_header* my_header(uint32_t idx) {
    uint32_t n = orig_count(), v = 0;
    for (uint32_t i = 0; i < n; i++) {
        const char* nm = orig_name(i);
        if (ShouldHideImg(nm)) continue;
        if (v++ == idx) return orig_header(i);
    }
    return NULL;
}

// ─── strstr ──────────────────────────────────────────────────────────────────
static char* (*orig_strstr)(const char*, const char*);
static char* my_strstr(const char* h, const char* n) {
    if (!h || !n) return NULL;
    if (ShouldHideImg(n)) return NULL;
    return orig_strstr(h, n);
}

// ─── dlsym ───────────────────────────────────────────────────────────────────
static void* (*orig_dlsym)(void*, const char*);
static void* my_dlsym(void* h, const char* n) {
    if (ShouldHideSym(n)) return NULL;
    return orig_dlsym(h, n);
}

// ─── dlopen ──────────────────────────────────────────────────────────────────
static void* (*orig_dlopen)(const char*, int);
static void* my_dlopen(const char* p, int f) {
    if (p && ShouldHideImg(p)) return NULL;
    return orig_dlopen(p, f);
}

// ─── open: подмена путей ─────────────────────────────────────────────────────
static char g_mainExe[PATH_MAX];
static char g_cleanExe[PATH_MAX];

static int (*orig_open)(const char*, int, ...);
static int my_open(const char* p, int f, ...) {
    va_list ap; va_start(ap, f);
    mode_t m = va_arg(ap, mode_t);
    va_end(ap);
    if (p) {
        // sr_host.txt / boot.log — отдаём /dev/null (mtime и файл не трогаем!)
        if (strstr(p, "sr_host.txt") || strstr(p, "boot.log") ||
            strstr(p, "com.icraze.gtatracker")) {
            return orig_open("/dev/null", O_RDONLY, 0);
        }
        // главный бинарник — подменяем на .clean копию (только на чтение)
        if (g_mainExe[0] && strcmp(p, g_mainExe) == 0 && g_cleanExe[0] &&
            !(f & (O_WRONLY | O_RDWR))) {
            return orig_open(g_cleanExe, f, m);
        }
    }
    return orig_open(p, f, m);
}

// ─── установка ───────────────────────────────────────────────────────────────
static void CalcPaths(void) {
    const char* nm = _dyld_get_image_name(0);
    if (nm) {
        snprintf(g_mainExe, sizeof(g_mainExe), "%s", nm);
        snprintf(g_cleanExe, sizeof(g_cleanExe), "%s.clean", nm);
    }
}

__attribute__((constructor))
static void MarkBlindInit(void) {
    CalcPaths();

    struct rebinding r[] = {
        {"dyld_image_count",      my_count,  (void**)&orig_count},
        {"dyld_get_image_name",   my_name,   (void**)&orig_name},
        {"dyld_get_image_header", my_header, (void**)&orig_header},
        {"strstr",                my_strstr, (void**)&orig_strstr},
        {"dlsym",                 my_dlsym,  (void**)&orig_dlsym},
        {"dlopen",                my_dlopen, (void**)&orig_dlopen},
        {"open",                  my_open,   (void**)&orig_open},
    };
    rebind_symbols(r, sizeof(r) / sizeof(r[0]));
}
