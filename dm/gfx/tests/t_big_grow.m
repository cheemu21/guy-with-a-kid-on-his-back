// A large pool that keeps growing answers lookups of unknown length with the buffer it already has (nvn_mtl.m big_part_for): PRAGMATA's sparse run grew 728 → 768 MB in 4 MB steps
// during its opening and each step made a new whole buffer of ~770 MB (53 in the run, GPU allocated 6.3 → 8.3 GB in 3 s, then a GPU hang on an iPhone 18 Pro, V14 / V15). While the
// pool grows, the last whole buffer (carried as a part) answers, so no new one is made; a lookup near the part's end, a pool grown far past it, or a pool that stopped growing for
// DM_NVN_BIG_GROW_MS gets one whole buffer again, and the parts go (big_shed). A part never answers from the per-thread lookup cache, so the whole buffer comes once growth stops
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
static int wholes(const void *key) { int n = 0; pthread_mutex_lock(&g_mu); for (int i = 0; i < g_npool; i++) n += g_pools[i].key == key && g_pools[i].reach == REACH_WHOLE; pthread_mutex_unlock(&g_mu); return n; }
static id<MTLBuffer> lookup(uint64_t a, uint64_t len, uint64_t *off) { void *mb; uint64_t mo, g; if (!mtl_gpu_addr(a, len, &mb, &mo, &g)) return nil; if (off) *off = mo; return (__bridge id<MTLBuffer>)mb; }
static uint64_t size;
static void grow(const void *key, uint8_t *mem, uint64_t by) {
    const void *del[1] = {key}, *add[1] = {mem}; uint64_t sz[1] = {size + by}; unsigned char keep[1] = {1};
    mtl_pool_replace(del, 1, add, sz, 1, keep); size += by;
}
int main(void) { @autoreleasepool {
    setenv("DM_NVN_BIG_GROW_MS", "300", 1);
    mtl_init();
    uint8_t *mem = mmap(NULL, 1200u * MB, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (mem == MAP_FAILED) return 1;
    uint64_t base = (uint64_t)(uintptr_t)mem; size = 728u * MB;
    const void *key = mem;
    mtl_pool_add(mem, size);
    id<MTLBuffer> w0 = lookup(base + 16, 1, NULL);
    CHECK("the first lookup of unknown length: one whole buffer", w0 && w0.length >= size && wholes(key) == 1);
    __weak id<MTLBuffer> ww0 = w0;
    uint64_t made0 = g_big_shed;
    for (int step = 0; step < 6; step++) {   // 4 MB a step, a lookup of unknown length after each: the whole buffer from before the steps answers
        grow(key, mem, 4u * MB);
        @autoreleasepool {
            uint64_t off = 0; id<MTLBuffer> b = lookup(base + 16, 1, &off);
            CHECK("while it grows, a lookup of unknown length takes the buffer it has", b == w0 && off == 16);
            CHECK("no new whole buffer", wholes(key) == 0);
            CHECK("a lookup of known length in the new pages still answers", lookup(base + size - 8192, 4096, NULL) != nil);
            CHECK("again from the same thread: answered the same way (not from a cached whole)", lookup(base + 16, 1, NULL) == w0);
        }
    }
    CHECK("nothing shed while it grew", g_big_shed == made0);
    CHECK("the part's answers are counted", g_big_part_answers >= 6);
    @autoreleasepool {   // an address the part reaches less than 64 MB past: a chunk from its stride to the pool's end (big_lookup, DM_NVN_BIG_TAIL), not a whole buffer
        uint64_t tails0 = g_big_tails, off = 0;
        id<MTLBuffer> b = lookup(base + 740u * MB + 32, 1, &off);
        uintptr_t lo = (uintptr_t)base + (((740u * MB) >> 24) << 24);
        CHECK("near the part's end: a chunk from its stride to the pool's end", b && b != w0 && g_big_tails <= tails0 + 1 && (uintptr_t)b.contents == lo && (uintptr_t)b.contents + b.length >= (uintptr_t)base + size && b.length < 64u * MB);
        CHECK("its offset is the address's", off == base + 740u * MB + 32 - lo);
        CHECK("no whole buffer", wholes(key) == 0);
        CHECK("the same lookup again: the same chunk", lookup(base + 740u * MB + 32, 1, NULL) == b);
        grow(key, mem, 4u * MB);   // it no longer reaches the end: lengthened, the shorter one to deferred release
        uint64_t freed0 = g_big_relen_freed;
        id<MTLBuffer> c = lookup(base + 740u * MB + 32, 1, NULL);
        CHECK("after a step: the chunk lengthened to the new end", c && c != b && (uintptr_t)c.contents + c.length >= (uintptr_t)base + size && wholes(key) == 0);
        CHECK("the shorter chunk is released, not kept with the pool", g_big_relen_freed == freed0 + 1);
        CHECK("a lookup low in the pool still takes the part", lookup(base + 16, 1, NULL) == w0);
        id<MTLBuffer> h = lookup(base + 100u * MB, 1, NULL);
        CHECK("a lookup the part reaches far past: the part", h == w0);
    }
    @autoreleasepool {   // more than half the pool to its end, with the part not reaching 64 MB past it (an address beyond the part): a whole buffer
        grow(key, mem, 4u * MB);
        id<MTLBuffer> b = lookup(base + size - 64, 1, NULL);   // in the last stride: a tail chunk
        CHECK("in the last stride: a tail chunk", b && b != w0 && b.length <= 16u * MB + 8u * MB && wholes(key) == 0);
        setenv("DM_NVN_BIG_GROW_MS", "300", 1);
        usleep(400000);   // growth stopped: the part no longer answers, and the stride-0 tail would be the whole pool
        id<MTLBuffer> w = lookup(base + 16, 1, NULL);
        CHECK("low in the pool once growth stopped: one whole buffer", w && w.length >= size && wholes(key) == 1);
        CHECK("its parts and chunks go (big_shed)", g_big_shed > made0 && entries(key) == 1);
    }
    @autoreleasepool {   // grown more than 256 MB past the part: a whole buffer at once
        grow(key, mem, 4u * MB);
        id<MTLBuffer> w1 = lookup(base + 16, 1, NULL);   // the whole buffer from just before, now a part
        CHECK("growing again: the last whole buffer answers", w1 && wholes(key) == 0);
        grow(key, mem, 70u * MB);   // 68 MB in one step made a whole buffer of 887 MB with 64 MB (V17): now under the 256 MB the part answers
        CHECK("grown 70 MB past it: the part still answers", lookup(base + 16, 1, NULL) == w1 && wholes(key) == 0);
        grow(key, mem, 300u * MB);
        id<MTLBuffer> b = lookup(base + 16, 1, NULL);
        CHECK("grown 300 MB past it (over DM_NVN_BIG_PART_GROWN_MB, 256): a new whole buffer", b && b != w1 && b.length >= size && wholes(key) == 1);
    }
    @autoreleasepool {   // growth stops: once DM_NVN_BIG_GROW_MS has passed, one whole buffer
        grow(key, mem, 4u * MB);
        id<MTLBuffer> p = lookup(base + 16, 1, NULL);
        CHECK("right after a step: the part", p && wholes(key) == 0);
        usleep(400000);
        id<MTLBuffer> b = lookup(base + 16, 1, NULL);
        CHECK("after the pool stopped growing: a whole buffer over all of it", b && b != p && b.length >= size && wholes(key) == 1 && entries(key) == 1);
        CHECK("which answers again", lookup(base + 16, 1, NULL) == b && lookup(base + size - 64, 1, NULL) == b);
    }
    w0 = nil;
    mtl_drain(); mtl_drain(); @autoreleasepool { defer_kick(); } mtl_drain();
    CHECK("the first whole buffer is released once its work has run", ww0 == nil);
    mtl_pool_del(key); mtl_drain();
    printf("t_big_grow: %d checks, %d failed (part answers %llu, shed %llu buffers, %llu MB)\n", checks, failed, (unsigned long long)g_big_part_answers, (unsigned long long)g_big_shed, (unsigned long long)g_big_shed_mb);
    return failed != 0;
} }
