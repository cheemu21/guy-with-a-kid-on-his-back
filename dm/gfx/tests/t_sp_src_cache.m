// The sparse gather's source buffers are kept from batch to batch (nvn_mtl.m spc_get, DM_NVN_SP_SRC_CACHE): pages far apart in a large pool (BIG_MIN) each take a zero-copy
// buffer over their own memory in the first batch, and a later batch gets the same buffers back without making any; buffers unused for SPC_IDLE batches go with the open batch
// and are retired with it. With DM_NVN_SP_SRC_CACHE=0 (argument "off") every batch makes its own, as before. PRAGMATA's streamed 8192x4096 BC6H texture made 7,073 of these at
// each of 136 whole re-uploads, 10-30 ms of the submit thread each (iPhone 18 Pro, V11)
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

enum { POOL_SIZE = 768u << 20, N = 100, STEP = 2u << 20 };   // pages 2 MB apart: past SP_GAP, each a span of its own

static uint8_t *g_mem;
static uint64_t batch(uint64_t addr[N]) {   // one upload batch looking up every page; returns how many source buffers it made
    uint64_t m0 = g_up_src_made;
    up_begin();
    for (int i = 0; i < N; i++) { uint64_t g = 0; CHECK("the page gets a GPU address", sp_src_gpu((uint64_t)(uintptr_t)(g_mem + i * STEP), 0x1000, &g) && g); addr[i] = g; }
    up_flush(); mtl_drain();
    return g_up_src_made - m0;
}
int main(int argc, char **argv) { @autoreleasepool {
    int off = argc > 1 && !strcmp(argv[1], "off");
    if (off) setenv("DM_NVN_SP_SRC_CACHE", "0", 1);
    mtl_init();
    g_mem = mmap(NULL, POOL_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (g_mem == MAP_FAILED) return 1;
    for (int i = 0; i < N; i++) g_mem[(size_t)i * STEP] = (uint8_t)i;
    mtl_pool_add(g_mem, POOL_SIZE); nvn_dirty_add_range(g_mem, POOL_SIZE);
    uint64_t a1[N], a2[N];
    uint64_t made1 = batch(a1), made2 = batch(a2);
    if (off) {
        CHECK("cache off: every batch makes its buffers", made1 == N && made2 == N);
        printf("t_sp_src_cache off: %d checks, %d failed\n", checks, failed); return failed != 0;
    }
    CHECK("first batch: a buffer for each page", made1 == N && g_spc_made == N);
    CHECK("second batch: none made, all reused", made2 == 0 && g_spc_hits == N);
    int same = 1; for (int i = 0; i < N; i++) same &= a1[i] == a2[i];
    CHECK("the same GPU addresses", same);
    int over = 1;   // each buffer lies over the guest's own memory (zero-copy)
    up_begin();
    for (int i = 0; i < N; i++) { uint64_t o = 0; id<MTLBuffer> b = spc_get((uint64_t)(uintptr_t)(g_mem + i * STEP), 0x1000, &o);
        over &= b && (uint8_t *)b.contents + o == g_mem + (size_t)i * STEP && ((uint8_t *)b.contents)[o] == (uint8_t)i; }
    CHECK("each buffer reads the page itself", over);
    // Idle past SPC_IDLE batches: let go with the open batch, retired when it has run
    for (unsigned i = 0; i < SPC_N; i++) if (g_spc[i].a) g_spc[i].used = g_up_seq - SPC_IDLE - 1;
    NSUInteger k0 = g_up_keep.count; spc_sweep();
    CHECK("idle buffers are let go", g_spc_n == 0 && g_spc_gone == N && g_up_keep.count == k0 + N);
    up_flush(); mtl_drain();
    CHECK("the batch holding them completes", !mtl_last_commit_error());
    uint64_t a3[N]; uint64_t made3 = batch(a3);
    CHECK("after they went: made again", made3 == N && g_spc_n == N);
    printf("t_sp_src_cache: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
