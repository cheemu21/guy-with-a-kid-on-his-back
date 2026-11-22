// A compute dispatch's image and sampled-texture bindings take their storage's guest range (nvn_mtl.m cs_access_of): a texture in an ordinary pool gives its range, written only
// through a read-write image binding; nothing bound gives nothing; a buffer or linear texture (the GPU reaches it as memory) keeps the dispatch rangeless. The range then decides
// the barrier against the host's buffer copies (dispatch_enc_cs): a fill elsewhere leaves the dispatch free, a fill over the texture's storage orders it, and a rangeless dispatch
// after any copy takes a barrier, as before. PRAGMATA's image-writing dispatches were rangeless (~50,000 per 300 frames took a barrier on an iPhone 18 Pro, V5)
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
static tex_t make_tex(pool_t *p, uint8_t *mem, size_t off, uint64_t serial, uint32_t target, uint32_t flags) {
    tex_t t = {0}; t.magic = MAGIC('T', 'E', 'X', 0); t.has_layout = 1; t.serial = serial; t.pool = p; t.off = off; t.mem = mem + off;
    t.d = (nvn_texdesc){.target = target, .format = NVN_FORMAT_RGBA8, .width = 64, .height = 64, .depth = 1, .levels = 1, .samples = 1, .flags = flags};
    nvn_tex_layout(&t.d, &t.L); return t;
}
static NvShader *image_kernel(int kind, int rw) {
    NvShader *cs = [NvShader new]; cs->stage = 5; cs->rf.nb = 1; cs->rf.b[0] = (nvn_rbind){.kind = kind, .reg = 0, .rw = rw}; return cs;
}
int main(void) { @autoreleasepool {
    mtl_init();
    enum { LEN = 1 << 20 };
    uint8_t *mem = mmap(NULL, LEN, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (mem == MAP_FAILED) return 1;
    pool_t p = {.magic = MAGIC('P', 'O', 'O', 'L'), .mem = mem, .size = LEN, .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    mtl_pool_add(mem, LEN);
    tex_t img = make_tex(&p, mem, 0, 991001, NVN_TEXTURE_TARGET_2D, 0), lin = make_tex(&p, mem, 65536, 991002, NVN_TEXTURE_TARGET_2D, NVN_TEXTURE_FLAGS_LINEAR);
    mtl_tex_init(&img); mtl_tex_init(&lin);
    mtl_reg_tex(1, &img, NULL); mtl_reg_tex(2, &lin, NULL);
    S.tex_base = 0;
    uint64_t lo = (uint64_t)(uintptr_t)img.mem, hi = lo + img.L.size;

    // cs_access_of
    S.img[5][0] = 1;
    geo_access a = cs_access_of(image_kernel(NVN_RB_IMG, 1), 0);
    CHECK(!a.unknown && a.n == 1 && a.r[0].lo == lo && a.r[0].hi == hi, "a read-write image in an ordinary pool: its storage's range");
    CHECK(a.r[0].write, "written");
    a = cs_access_of(image_kernel(NVN_RB_IMG, 0), 0);
    CHECK(!a.unknown && a.n == 1 && !a.r[0].write, "a read-only image: its range, read");
    S.tex[5][0] = 1;
    a = cs_access_of(image_kernel(NVN_RB_TEX, 0), 0);
    CHECK(!a.unknown && a.n == 1 && a.r[0].lo == lo && !a.r[0].write, "a sampled texture: its range, read");
    S.img[5][0] = 0;
    a = cs_access_of(image_kernel(NVN_RB_IMG, 1), 0);
    CHECK(!a.unknown && a.n == 0, "nothing bound: nothing");
    S.img[5][0] = 2;
    a = cs_access_of(image_kernel(NVN_RB_IMG, 1), 0);
    CHECK(a.unknown, "a linear texture: the GPU reaches it as memory, rangeless");
    S.img[5][0] = 7;
    a = cs_access_of(image_kernel(NVN_RB_IMG, 1), 0);
    CHECK(a.unknown, "an ID with no texture: rangeless");

    // dispatch_enc_cs against the host's buffer copies (game ordering is the default)
    if (dbar_game() && dbar_unknown_game()) {
        NvShader *cs = image_kernel(NVN_RB_IMG, 1);
        S.img[5][0] = 1;
        mtl_sub_begin(); state_reset(); S.tex_base = 0; S.img[5][0] = 1;
        (void)blit_buf(0, 0, lo + LEN / 2, lo + LEN / 2 + 4096);   // a fill elsewhere in the pool
        uint64_t free0 = g_dbar_free, copy0 = g_dbar_copy, unk0 = g_dbar_unknown;
        (void)dispatch_enc_cs(cs, 0);
        CHECK(g_dbar_free == free0 + 1 && g_dbar_copy == copy0 && g_dbar_unknown == unk0, "after a fill elsewhere: no barrier");
        (void)blit_buf(0, 0, lo + 256, lo + 512);   // a fill over the image's storage
        copy0 = g_dbar_copy;
        (void)dispatch_enc_cs(cs, 0);
        CHECK(g_dbar_copy == copy0 + 1, "after a fill over its storage: ordered after it");
        S.img[5][0] = 2;   // rangeless again: after a copy it takes a barrier
        (void)blit_buf(0, 0, lo + LEN / 2, lo + LEN / 2 + 4096);
        unk0 = g_dbar_unknown;
        (void)dispatch_enc_cs(cs, 0);
        CHECK(g_dbar_unknown == unk0 + 1, "a rangeless dispatch after a copy: a barrier, as before");
        CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "the submission completes"); CHECK(!mtl_last_commit_error(), "no GPU error");
    } else printf("t_dispatch_image_range: game ordering off (DM_NVN_DISPATCH_BARRIER / DM_NVN_DISPATCH_RANGELESS), barrier checks skipped\n");
    printf("t_dispatch_image_range: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
