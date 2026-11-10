/* Filtered BGRA desktop scaling for the Windows DXGI bridge.
 * The input is a top-down BGRA surface. Output is tightly packed RGB24.
 * There is no image scaling at native size: callers use kvm_pixels_rgb() and
 * kvm_pixels_rgb_rect() to preserve the fast dirty-rectangle path.
 */
#ifndef KVM_RGB_SCALE_H
#define KVM_RGB_SCALE_H
#include "kvm_pixels.h"

/* Sample source-pixel CENTRES, using 16.16 fixed point and edge clamping.
 * Mapping centre-to-centre prevents a half-pixel shift on downscaled images.
 */
static inline uint64_t kvm_rgb_sample_coord(uint32_t index,
    uint32_t src_length,uint32_t dst_length) {
    uint64_t fixed=((uint64_t)(2u*index+1u)*src_length*32768u)/dst_length;
    uint64_t last=((uint64_t)(src_length-1u))<<16;
    fixed=fixed<=32768u ? 0 : fixed-32768u;
    return fixed>last ? last : fixed;
}

/* Map a pixel in the ROTATED view to the actual unrotated DXGI surface. */
static inline const uint8_t *kvm_rgb_rotated_pixel(const uint8_t *src,
    uint32_t stride,uint32_t sw,uint32_t sh,unsigned rotation,
    uint32_t x,uint32_t y) {
    uint32_t sx=x,sy=y;
    switch (rotation) {
        case 1: sx=y; sy=sh-1u-x; break;
        case 2: sx=sw-1u-x; sy=sh-1u-y; break;
        case 3: sx=sw-1u-y; sy=x; break;
        default: break;
    }
    return src+(size_t)sy*stride+(size_t)sx*4u;
}

/* Bilinear downscaling: smoother text / diagonal edges than nearest-neighbour
 * for GDI HALFTONE-like rendering. This is not bit-identical to GDI HALFTONE.
 * The optional LAZDESK_DXGI_FAST_SCALE=1 selects the old nearest path.
 */
static inline int kvm_rgb_bilinear_bgra(const uint8_t *src,size_t src_size,
    uint32_t stride,uint32_t sw,uint32_t sh,unsigned rotation,
    uint8_t *dst,size_t dst_capacity,uint32_t dw,uint32_t dh) {
    uint32_t x,y,rw=(rotation&1u)?sh:sw,rh=(rotation&1u)?sw:sh;
    if (!src || !dst || !kvm_dimensions(sw,sh) || !kvm_dimensions(dw,dh) ||
        rotation>3 || (uint64_t)stride< (uint64_t)sw*4u ||
        (uint64_t)(sh-1u)*stride+(uint64_t)sw*4u>src_size ||
        (uint64_t)dw*dh*3u>dst_capacity) return 0;
    for (y=0;y<dh;++y) {
        const uint64_t fy=kvm_rgb_sample_coord(y,rh,dh);
        const uint32_t y0=(uint32_t)(fy>>16),y1=(y0+1u<rh)?y0+1u:y0;
        const uint64_t wy=fy&65535u;
        for (x=0;x<dw;++x) {
            const uint64_t fx=kvm_rgb_sample_coord(x,rw,dw);
            const uint32_t x0=(uint32_t)(fx>>16),x1=(x0+1u<rw)?x0+1u:x0;
            const uint64_t wx=fx&65535u;
            const uint8_t *p00=kvm_rgb_rotated_pixel(src,stride,sw,sh,rotation,x0,y0);
            const uint8_t *p10=kvm_rgb_rotated_pixel(src,stride,sw,sh,rotation,x1,y0);
            const uint8_t *p01=kvm_rgb_rotated_pixel(src,stride,sw,sh,rotation,x0,y1);
            const uint8_t *p11=kvm_rgb_rotated_pixel(src,stride,sw,sh,rotation,x1,y1);
            uint8_t *out=dst+((size_t)y*dw+x)*3u;
            for (unsigned channel=0;channel<3u;++channel) {
                unsigned in=channel==0 ? 2u : (channel==2 ? 0u : 1u);
                uint64_t upper=(uint64_t)p00[in]*(65536u-wx)+(uint64_t)p10[in]*wx;
                uint64_t lower=(uint64_t)p01[in]*(65536u-wx)+(uint64_t)p11[in]*wx;
                out[channel]=(uint8_t)((upper*(65536u-wy)+lower*wy+0x80000000ULL)>>32);
            }
        }
    }
    return 1;
}
#endif
