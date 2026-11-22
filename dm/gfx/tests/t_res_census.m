// The periodic residency census (nvn_mtl.m mtl_mem_stat, DM_NVN_RES_CENSUS): every 1,800 frames by default the log says what holds the GPU's memory, the residency set by kind
// with its largest objects (res_top) and the textures by holder (mem_census), as DM_CTL restop writes them. The memory hook runs every 300 frames; the census comes at frame 1,800
// and then once every 1,800 frames, not at each call. With the switch at 0 (argument "off") it never comes
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
// Calls the memory hook at these frames with stderr (where MLOG writes) captured: → the census headers written, the largest-object lines, and whether the totals line names each kind
static int run(const unsigned long long *frames, int n, int *largest, int *kinds) {
    *largest = 0; *kinds = 0;
    if (fflush(stderr)) return -1;
    int saved = dup(2); if (saved < 0) return -1;
    FILE *tmp = tmpfile(); if (!tmp) { close(saved); return -1; }
    if (dup2(fileno(tmp), 2) < 0) { fclose(tmp); close(saved); return -1; }
    for (int i = 0; i < n; i++) mtl_mem_stat(frames[i], 100);
    int flushed = fflush(stderr), restored = dup2(saved, 2); close(saved);
    if (flushed || restored < 0 || fseek(tmp, 0, SEEK_SET)) { fclose(tmp); return -1; }
    char line[8192]; int heads = 0;
    while (fgets(line, sizeof line, tmp)) {
        if (strstr(line, "residency census at frame ") && strstr(line, "the residency set holds ")) {
            heads++;
            *kinds = strstr(line, "textures ") && strstr(line, "heaps ") && strstr(line, "shared buffers ") && strstr(line, "private buffers ");
        }
        if (strstr(line, "  buffer ") || strstr(line, "  texture ") || strstr(line, "  heap: ")) (*largest)++;
    }
    fclose(tmp);
    return heads;
}
int main(int argc, char **argv) { @autoreleasepool {
    int off = argc > 1 && !strcmp(argv[1], "off");
    if (off) setenv("DM_NVN_RES_CENSUS", "0", 1);
    mtl_init();
    // Something in the set of each kind the census sorts: a shared buffer, a private buffer, a texture
    id<MTLBuffer> sb = [g_dev newBufferWithLength:24u << 20 options:MTLResourceStorageModeShared]; res_add(sb);
    id<MTLBuffer> pb = [g_dev newBufferWithLength:8u << 20 options:MTLResourceStorageModePrivate]; res_add(pb);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:512 height:512 mipmapped:NO]; td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> tx = [g_dev newTextureWithDescriptor:td]; res_add(tx); res_commit();
    unsigned long long frames[13]; for (int i = 0; i < 13; i++) frames[i] = 300ull * (unsigned long long)(i + 1);   // 300 .. 3900, as the frame hook calls it
    int largest = 0, kinds = 0, heads = run(frames, 13, &largest, &kinds);
    if (off) CHECK("DM_NVN_RES_CENSUS=0: no census", heads == 0);
    else {
        CHECK("a census every 1,800 frames: at frames 1800 and 3600", heads == 2);
        CHECK("its totals name every kind", kinds);
        CHECK("and it lists the largest objects", largest >= 3);
    }
    (void)sb; (void)pb; (void)tx;
    printf("t_res_census%s: %d checks, %d failed\n", off ? " off" : "", checks, failed);
    return failed != 0;
} }
