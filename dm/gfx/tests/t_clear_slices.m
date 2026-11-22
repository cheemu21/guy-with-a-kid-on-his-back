// A whole-level texture clear over several layers or depth slices (clear_tex) is one layered pass (renderTargetArrayLength), not a pass per slice: it clears exactly the region's
// slices of a 3D texture and the view's layers of a 2D array, leaving the others, and DM_NVN_CLEAR_SLICES=1 (a pass per slice) gives the same texels. PRAGMATA clears a 128x192x128
// R32Uint 3D texture every frame (128 passes, 1.3-2.6 ms on an iPhone 18 Pro, V6)
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

enum { W = 8, H = 4, N = 6, OLD = 17, NEW = 7 };

int main(void) { @autoreleasepool {
    mtl_init(); id<MTLCommandQueue> queue = [g_dev newCommandQueue];
    struct { int target, z0, nz, has_layers, min_layer; const char *label; } cases[] = {
        {NVN_TEXTURE_TARGET_3D, 0, N, 0, 0, "whole 3D texture: every depth slice"},
        {NVN_TEXTURE_TARGET_3D, 2, 3, 0, 0, "3D region: depth slices 2-4 only"},
        {NVN_TEXTURE_TARGET_2D_ARRAY, 0, 3, 1, 2, "2D array through a view from layer 2: layers 2-4 only"},
        {NVN_TEXTURE_TARGET_3D, 0, 1, 0, 0, "one depth slice: no layered pass needed"},
    };
    for (unsigned i = 0; i < sizeof cases / sizeof *cases; i++) {
        tex_t t = {.magic = MAGIC('T', 'E', 'X', 0), .serial = 99701 + i};
        int is3d = cases[i].target == NVN_TEXTURE_TARGET_3D;
        t.d = (nvn_texdesc){.target = cases[i].target, .format = NVN_FORMAT_R32UI, .width = W, .height = H, .depth = N, .levels = 1, .samples = 1};
        MTLTextureDescriptor *d = tex_desc(&t, 0); d.usage |= MTLTextureUsageRenderTarget;
        id<MTLTexture> base = [g_dev newTextureWithDescriptor:d]; CHECK(base != nil, "target allocates"); if (!base) continue;
        CHECK((base.textureType == MTLTextureType3D) == is3d, "texture type");
        for (int z = 0; z < N; z++) {   // every slice starts at OLD
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = base; if (is3d) rp.colorAttachments[0].depthPlane = z; else rp.colorAttachments[0].slice = z;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.colorAttachments[0].clearColor = MTLClearColorMake(OLD, 0, 0, 0);
            id<MTLCommandBuffer> cb = [queue commandBuffer]; [[cb renderCommandEncoderWithDescriptor:rp] endEncoding]; [cb commit]; [cb waitUntilCompleted];
        }
        res_add(base); mtl_tex_init(&t); serial_put(t.serial, base);
        state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
        struct { op_hdr head; p_clear_tex clear; op_hdr end; } ops = {0};
        ops.head = (op_hdr){OP_CLEAR_TEX, sizeof(op_hdr) + sizeof(p_clear_tex)};
        ops.clear = (p_clear_tex){.tex = &t, .has_view = cases[i].has_layers, .is_uint = 1, .mask = 0xf, .r = {0, 0, cases[i].z0, W, H, cases[i].nz}};
        if (cases[i].has_layers) ops.clear.view = (view_t){.set_layers = 1, .min_layer = cases[i].min_layer};
        ops.clear.c.u[0] = NEW;
        ops.end = (op_hdr){OP_END, sizeof(op_hdr)};
        uint64_t p0 = g_clear_tex_passes;
        mtl_exec((const uint8_t *)&ops); mtl_sub_commit(); mtl_drain();
        CHECK(!mtl_last_commit_error(), "the clear completes");
        CHECK(g_clear_tex_passes - p0 == (getenv("DM_NVN_CLEAR_SLICES") ? (uint64_t)cases[i].nz : 1), "one pass for the whole region (a pass per slice with DM_NVN_CLEAR_SLICES=1)");
        int lo = (is3d ? 0 : cases[i].min_layer) + cases[i].z0, hi = lo + cases[i].nz, valid = 1;
        for (int z = 0; z < N; z++) {
            id<MTLBuffer> out = [g_dev newBufferWithLength:W * H * 4 options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> cb = [queue commandBuffer]; id<MTLBlitCommandEncoder> en = [cb blitCommandEncoder];
            [en copyFromTexture:base sourceSlice:is3d ? 0 : z sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, is3d ? z : 0) sourceSize:MTLSizeMake(W, H, 1)
                       toBuffer:out destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * H * 4];
            [en endEncoding]; [cb commit]; [cb waitUntilCompleted]; CHECK(cb.status == MTLCommandBufferStatusCompleted, "readback completes");
            const uint32_t *p = out.contents; uint32_t want = z >= lo && z < hi ? NEW : OLD;
            for (int k = 0; k < W * H; k++) valid &= p[k] == want;
        }
        CHECK(valid, cases[i].label); printf("%s: %s\n", cases[i].label, valid ? "PASS" : "FAIL");
        mtl_tex_release(&t);
    }
    printf("t_clear_slices: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
