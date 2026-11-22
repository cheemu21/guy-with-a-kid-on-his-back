// A large pool's chunks and parts go once its whole buffer is made (nvn_mtl.m big_shed): a pool that grows a few MB at a time beside itself (a sparse pool's run, hle_nvn.c vrun_set
// → mtl_pool_replace with keep), with a lookup of unknown length after each step, keeps one buffer in the table, and the buffers it had before (its earlier whole buffers, carried as
// parts, and its chunks) are released once the work that may use them has run. PRAGMATA's run 0x7ce8000000 grew from 804 to 1,006 MB that way and kept 7-24 chunks and parts of
// 880-1,700 MB beside its whole buffer (iPhone 18 Pro, V12: GPU allocated 9.5-10.5 GB of an 8 GB working set). With DM_NVN_BIG_SHED=0 (argument "off") they stay, as before
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
enum { MB = 1u << 20 };
static int entries(const void *key) { int n = 0; pthread_mutex_lock(&g_mu); for (int i = 0; i < g_npool; i++) n += g_pools[i].key == key; pthread_mutex_unlock(&g_mu); return n; }
static id<MTLBuffer> lookup(uint64_t a, uint64_t len) { void *mb; uint64_t mo, g; return mtl_gpu_addr(a, len, &mb, &mo, &g) ? (__bridge id<MTLBuffer>)mb : nil; }
int main(int argc, char **argv) { @autoreleasepool {
    int off = argc > 1 && !strcmp(argv[1], "off");
    setenv("DM_NVN_BIG_GROW_MS", "0", 1);   // a new whole buffer at each step, as before big_part_for (t_big_grow checks that)
    if (off) setenv("DM_NVN_BIG_SHED", "0", 1);
    mtl_init();
    uint8_t *mem = mmap(NULL, 1200u * MB, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (mem == MAP_FAILED) return 1;
    uint64_t base = (uint64_t)(uintptr_t)mem, size = 804u * MB;
    const void *key = mem;
    mtl_pool_add(mem, size);
    __weak id<MTLBuffer> w_chunk[3], w_whole[6];
    @autoreleasepool {
        for (int k = 0; k < 3; k++) w_chunk[k] = lookup(base + (uint64_t)k * 100 * MB + 64, 4096);   // chunks of known length at three strides
        CHECK("three chunks", entries(key) == 3);
        w_whole[0] = lookup(base + 8, 1);   // a lookup of unknown length: the whole pool
        CHECK("the first whole buffer", w_whole[0] && w_whole[0].length >= size);
        CHECK(off ? "kept: chunks and the whole buffer" : "shed: the whole buffer alone", entries(key) == (off ? 4 : 1));
    }
    for (int step = 1; step <= 5; step++) {   // the run grows by 6 MB each time, the old one kept (its pages did not change)
        uint64_t nsize = size + 6u * MB;
        const void *del[1] = {key}, *add[1] = {mem}; uint64_t sz[1] = {nsize}; unsigned char keep[1] = {1};
        mtl_pool_replace(del, 1, add, sz, 1, keep);
        size = nsize;
        @autoreleasepool {
            CHECK("a lookup of known length still answers after the growth", lookup(base + 300 * MB, 4096) != nil);
            w_whole[step] = lookup(base + 16, 1);
            CHECK("a new whole buffer over the grown pool", w_whole[step] && w_whole[step].length >= size);
            if (!off) CHECK("shed: one buffer in the table", entries(key) == 1);
            else CHECK("kept: more than the whole buffer", entries(key) > 1);
        }
    }
    mtl_drain(); mtl_drain();
    @autoreleasepool { defer_kick(); }
    mtl_drain();
    int gone = 1; for (int k = 0; k < 3; k++) gone &= w_chunk[k] == nil; for (int s = 0; s < 5; s++) gone &= w_whole[s] == nil;
    if (!off) {
        CHECK("shed: the chunks and the earlier whole buffers are released once their work has run", gone);
        CHECK("the latest whole buffer lives", w_whole[5] != nil);
        CHECK("its lookups are the latest whole buffer", lookup(base + 500 * MB, 1) == w_whole[5] && lookup(base + 10 * MB, 4096) == w_whole[5]);
    } else CHECK("kept: they stay with the pool", !gone);
    mtl_pool_del(key); mtl_drain();
    printf("t_big_shed%s: %d checks, %d failed (shed %llu buffers, %llu MB)\n", off ? " off" : "", checks, failed, (unsigned long long)g_big_shed, (unsigned long long)g_big_shed_mb);
    return failed != 0;
} }
