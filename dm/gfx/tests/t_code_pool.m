// A shader-code pool's own address keeps it out of the raw pool table (hle_nvn.c nvnMemoryPoolGetBufferAddress, upstream PR #1971 a1ba253): the GPU never reads shader code
// here, so asking for a SHADER_CODE pool's address does not make the table (and so the residency set) take it, while an ordinary pool's does, and a virtual pool with the
// shader-code flag is taken as before. With DM_NVN_CODE_POOL_RAW=1 (argument "raw") the code pool goes in, as before
#import <Foundation/Foundation.h>
#define nvn_game_fps nvn_game_fps_mtl_default
#define nvn_link_fps_cap nvn_link_fps_cap_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#undef nvn_link_fps_cap
#define g_ft g_ft_hle
#include "../nvn/hle_nvn.c"
#undef g_ft
uint64_t g_t0_ns;
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
static int in_table(const void *mem, size_t n) { pthread_mutex_lock(&g_mu); int r = addr_meets((uintptr_t)mem, (uintptr_t)mem + n); pthread_mutex_unlock(&g_mu); return r; }
static uint8_t *region(size_t n) { uint8_t *m = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (m == MAP_FAILED) abort(); return m; }
int main(int argc, char **argv) { @autoreleasepool {
    int raw = argc > 1 && !strcmp(argv[1], "raw");
    if (raw) setenv("DM_NVN_CODE_POOL_RAW", "1", 1);
    mtl_init();
    const size_t n = 1u << 20;
    pool_t code = {.magic = MAGIC('P','O','O','L'), .flags = NVN_MEMORY_POOL_FLAGS_SHADER_CODE | NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = region(n), .size = n};
    pool_t data = {.magic = MAGIC('P','O','O','L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = region(n), .size = n};
    mtl_pool_add(code.mem, n); mtl_pool_add(data.mem, n);
    CHECK("before: neither pool is in the table", !in_table(code.mem, n) && !in_table(data.mem, n));
    NVNbufferAddress ac = h_nvnMemoryPoolGetBufferAddress((const NVNmemoryPool *)&code);
    NVNbufferAddress ad = h_nvnMemoryPoolGetBufferAddress((const NVNmemoryPool *)&data);
    CHECK("each pool's address is its storage", ac == (NVNbufferAddress)(uintptr_t)code.mem && ad == (NVNbufferAddress)(uintptr_t)data.mem);
    CHECK("an ordinary pool's address puts it in the table", in_table(data.mem, n));
    if (raw) CHECK("DM_NVN_CODE_POOL_RAW=1: the shader-code pool goes in too, as before", in_table(code.mem, n));
    else {
        CHECK("a shader-code pool's own address leaves it out of the table", !in_table(code.mem, n));
        CHECK("and it is counted", g_code_pools_kept_out == 1 && g_code_pool_bytes_kept_out == n);
        mtl_pool_addressed(code.mem, n);   // what a buffer made in the pool does (nvnBufferInitialize → pool_mark_addressed)
        CHECK("a buffer made in it still puts it in", in_table(code.mem, n));
    }
    printf("t_code_pool%s: %d checks, %d failed\n", raw ? " raw" : "", checks, failed);
    return failed != 0;
} }
