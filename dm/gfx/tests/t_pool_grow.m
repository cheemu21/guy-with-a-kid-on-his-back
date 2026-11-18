// A large pool that grows beside itself (a sparse pool's run that a mapping next to it joins, hle_nvn.c vrun_set → mtl_pool_replace with keep): its buffers go over to the new pool
// (big_carry), raw global memory's pool table names them for what they hold and one new buffer, a part, for the pages added (big_cover), so a few MB added wire a few MB, not the whole
// pool again. PRAGMATA's runs of 500-940 MB grew 4 MB at a time and each join made a buffer of the whole run: the GPU ran out of memory on an iPhone 18 Pro. A pool replaced over pages
// that changed (no keep) still gives its buffers up, past BIG_PARTS parts one whole buffer takes their place, and the pool's removal takes every entry.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
static void table(void) { mtl_sub_begin(); CHECK("pool table made", gmem_map_gpu() != 0); CHECK("submission completes", mtl_wait(mtl_sub_commit(), 5000000000ull)); CHECK("no GPU error", !mtl_last_commit_error()); }
static int resident(id o) { pthread_mutex_lock(&g_res_mu); int r = [g_res_objects containsObject:o]; pthread_mutex_unlock(&g_res_mu); return r; }
// The table's entry for addr: the GPU address it gives must be that of a resident buffer of the pool whose contents are the guest's memory at addr
static int table_ok(uint64_t addr, const void *key) {
    const uint8_t *t = (const uint8_t *)gmem_map().contents; uint64_t e[3] = {0};
    int found = 0; for (int k = 1; k < DMSH_GMEM_MAP_ENTRIES && !found; k++) { memcpy(e, t + (size_t)k * DMSH_GMEM_MAP_ENTRY, sizeof e); if (e[0] == ~0ull) break; found = addr >= e[0] && addr < e[1]; }
    if (!found) { fprintf(stderr, "  no table entry holds %#llx\n", (unsigned long long)addr); for (int k = 1; k < 8; k++) { memcpy(e, t + (size_t)k * DMSH_GMEM_MAP_ENTRY, sizeof e); if (e[0] == ~0ull) break; fprintf(stderr, "  entry %d: %#llx..%#llx\n", k, (unsigned long long)e[0], (unsigned long long)e[1]); } return 0; }
    uint64_t gpu = addr + e[2];
    pthread_mutex_lock(&g_mu); int ok = 0;
    for (int i = 0; i < g_npool && !ok; i++) { id<MTLBuffer> b = g_pools[i].buf; uint64_t c = (uint64_t)(uintptr_t)b.contents;
        ok = g_pools[i].key == key && addr >= c && addr < c + b.length && gpu == b.gpuAddress + (addr - c) && resident(b); }
    pthread_mutex_unlock(&g_mu);
    return ok;
}
static uint64_t pool_mb(const void *key, int reach) { uint64_t mb = 0; pthread_mutex_lock(&g_mu); for (int i = 0; i < g_npool; i++) if (g_pools[i].key == key && (reach < 0 || g_pools[i].reach == reach)) mb += g_pools[i].buf.length; pthread_mutex_unlock(&g_mu); return mb >> 20; }
static int entries(const void *key) { int n = 0; pthread_mutex_lock(&g_mu); for (int i = 0; i < g_npool; i++) n += g_pools[i].key == key; pthread_mutex_unlock(&g_mu); return n; }
int main(void) { @autoreleasepool {
    mtl_init();
    const uint64_t MB = 1ull << 20, LEN = 1024 * MB;
    uint8_t *mem = mmap(NULL, LEN, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (mem == MAP_FAILED) abort();
    uint64_t base = (uint64_t)(uintptr_t)mem;
    int pools0 = g_npool;
    // A run of 600 MB whose address went out: the table gives it one buffer of the whole run, as before
    const void *cur = mem; uint64_t size = 600 * MB;
    mtl_pool_add(cur, size); mtl_pool_addressed(cur, size);
    table();
    CHECK("a new large pool: one whole buffer", g_nbig == 1 && g_big[0].full > 0 && pool_mb(cur, REACH_WHOLE) == 600);
    id<MTLBuffer> whole = nil; pthread_mutex_lock(&g_mu); whole = g_pools[g_big[0].full - 1].buf; pthread_mutex_unlock(&g_mu);
    CHECK("the table names it", table_ok(base + 100 * MB, cur));
    // The game maps 4 MB beside it: the run is replaced by one 4 MB longer, and its buffer goes over
    { const void *del[1] = {cur}, *add[1] = {cur}; uint64_t sz[1] = {size + 4 * MB}; unsigned char keep[1] = {1};
      mtl_pool_replace(del, 1, add, sz, 1, keep); size += 4 * MB; }
    CHECK("one large pool still", g_nbig == 1 && g_big[0].hi - g_big[0].lo == size && g_big[0].full == 0);
    CHECK("the old whole buffer is a part of the new pool, still resident", pool_mb(cur, REACH_PART) == 600 && resident(whole));
    table();
    CHECK("the table adds a part over the pages added only", pool_mb(cur, REACH_PART) <= 600 + 4 + 1 && pool_mb(cur, -1) <= 605 && g_big[0].full == 0);
    CHECK("the table names the kept buffer for the old pages", table_ok(base + 100 * MB, cur) && table_ok(base + 600 * MB - 64, cur));
    CHECK("and the part for the new ones", table_ok(base + 600 * MB + 16, cur) && table_ok(base + size - 64, cur));
    // Thirty more joins of 4 MB: wired once, about the pool's size, not thirty times
    for (int g = 0; g < 30; g++) { const void *del[1] = {cur}, *add[1] = {cur}; uint64_t sz[1] = {size + 4 * MB}; unsigned char keep[1] = {1};
        mtl_pool_replace(del, 1, add, sz, 1, keep); size += 4 * MB; table(); }
    CHECK("thirty joins: the parts add up to the pool", pool_mb(cur, -1) <= (size >> 20) + 32 && g_big[0].full == 0 && entries(cur) == 32);
    CHECK("the table reaches the newest pages", table_ok(base + size - 64, cur) && table_ok(base + 1, cur));
    // A join over pages that changed (a mapping over mapped pages): its buffers go, the new pool gets one whole buffer
    { const void *del[1] = {cur}, *add[1] = {cur}; uint64_t sz[1] = {size + 4 * MB}; unsigned char keep[1] = {0};
      mtl_pool_replace(del, 1, add, sz, 1, keep); size += 4 * MB; }
    CHECK("no part kept over changed pages", entries(cur) == 0);
    table();
    CHECK("one whole buffer again", g_big[0].full > 0 && entries(cur) == 1 && table_ok(base + size - 64, cur));
    mtl_drain(); defer_kick(); mtl_drain();
    CHECK("the old whole buffer left the residency set", !resident(whole));
    whole = nil;
    // Past BIG_PARTS parts one whole buffer takes their place
    uint64_t merged0 = g_big_merged; int joins = 0;
    for (; joins < BIG_PARTS + 1 && g_big_merged == merged0 && size + 4 * MB <= LEN; joins++) { const void *del[1] = {cur}, *add[1] = {cur}; uint64_t sz[1] = {size + 4 * MB}; unsigned char keep[1] = {1};
        mtl_pool_replace(del, 1, add, sz, 1, keep); size += 4 * MB; table(); }
    CHECK("merged once the parts reach BIG_PARTS", g_big_merged == merged0 + 1 && joins == BIG_PARTS);
    CHECK("into one whole buffer, the parts gone", g_big[0].full > 0 && pool_mb(cur, REACH_PART) == 0 && pool_mb(cur, REACH_WHOLE) == ((size + 16383) & ~16383ull) >> 20);
    CHECK("which the table names", table_ok(base + size - 64, cur) && table_ok(base + 1, cur));
    // A small run joined into a large one: its buffer goes over as a part
    uint8_t *m2 = mmap(NULL, LEN, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (m2 == MAP_FAILED) abort();
    mtl_pool_add(m2, 500 * MB); mtl_pool_addressed(m2, 520 * MB); table();
    CHECK("a small pool: one buffer", entries(m2) == 1 && g_nbig == 1);
    { const void *del[1] = {m2}, *add[1] = {m2}; uint64_t sz[1] = {520 * MB}; unsigned char keep[1] = {1}; mtl_pool_replace(del, 1, add, sz, 1, keep); }
    table();
    CHECK("grown past BIG_MIN: its buffer is a part, plus a part for the 20 MB added", g_nbig == 2 && pool_mb(m2, REACH_PART) <= 500 + 20 + 1 && table_ok((uint64_t)(uintptr_t)m2 + 510 * MB, m2) && table_ok((uint64_t)(uintptr_t)m2 + 5, m2));
    // The pools' removal takes every entry
    mtl_pool_del(cur); mtl_pool_del(m2); mtl_drain(); defer_kick(); mtl_drain();
    CHECK("nothing left", g_nbig == 0 && g_npool == pools0);
    printf("t_pool_grow: %d checks, %d failed (carried %llu, parts %llu / %llu MB, merged %llu)\n", checks, failed, (unsigned long long)g_big_carried, (unsigned long long)g_big_parts, (unsigned long long)g_big_part_mb, (unsigned long long)g_big_merged);
    return failed != 0;
} }
