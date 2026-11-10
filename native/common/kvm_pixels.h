/* LazDesk - bounded pixel conversion, no OS or graphics dependency.
 * Original code; public API of the optional native capture bridges. */
#ifndef KVM_PIXELS_H
#define KVM_PIXELS_H
#include <stdint.h>
#include <stddef.h>
#include <limits.h>
#define KVM_MAX_SIDE 32768u
#define KVM_MAX_PIXELS 67108864u
static inline int kvm_dimensions(uint32_t w, uint32_t h) {
    return w && h && w <= KVM_MAX_SIDE && h <= KVM_MAX_SIDE &&
           (uint64_t)w*h <= KVM_MAX_PIXELS;
}
/* src is a mapped packed 4-byte plane; offset points to its first row.
 * Negative stride and cropped/rotated images are deliberately validated,
 * rather than trusting the producer's buffer description.
 * rotation = clockwise 0..3 quarter turns of the cropped source.
 * rgb_order: 0=BGRA/BGRx, 1=RGBA/RGBx. Alpha is ignored for desktop images. */
static inline int kvm_pixels_rgb(const uint8_t *src, size_t size,
    size_t offset, int32_t stride, uint32_t sw, uint32_t sh,
    uint32_t cx, uint32_t cy, uint32_t cw, uint32_t ch,
    unsigned rotation, int rgb_order, uint8_t *dst, size_t capacity,
    uint32_t dw, uint32_t dh) {
    uint64_t abs_stride, span;
    uint32_t rw, rh, x, y;
    if (!src || !dst || !kvm_dimensions(sw,sh) || !kvm_dimensions(dw,dh) ||
        !cw || !ch || cx > sw || cy > sh || cw > sw-cx || ch > sh-cy ||
        rotation > 3 || (rgb_order != 0 && rgb_order != 1) || !stride ||
        (uint64_t)dw*dh*3 > capacity || offset > size || size > INT64_MAX) return 0;
    abs_stride = stride < 0 ? (uint64_t)(-(int64_t)stride) : (uint64_t)stride;
    if (abs_stride < (uint64_t)sw*4) return 0;
    span = (uint64_t)(sh-1)*abs_stride;
    if (stride < 0) {
        if (span > offset || (uint64_t)sw*4 > size-offset) return 0;
    } else {
        if (span > size-offset || (uint64_t)sw*4 > size-offset-span) return 0;
    }
    if (rotation == 0 && dw == cw && dh == ch) {
        const unsigned r = rgb_order ? 0u : 2u, b = rgb_order ? 2u : 0u;
        for (y=0; y<dh; ++y) {
            const uint8_t *p=src+(size_t)((int64_t)offset+
                (int64_t)(y+cy)*stride+(int64_t)cx*4);
            uint8_t *q=dst+(size_t)y*dw*3;
            /* No per-pixel divisions, coordinate transforms or branches. */
            for (x=0; x<dw; ++x, p+=4, q+=3) {
                q[0]=p[r]; q[1]=p[1]; q[2]=p[b];
            }
        }
        return 1;
    }
    rw = (rotation & 1) ? ch : cw; rh = (rotation & 1) ? cw : ch;
    for (y=0; y<dh; ++y) {
        uint32_t ry = (uint32_t)((uint64_t)y*rh/dh);
        for (x=0; x<dw; ++x) {
            uint32_t rx = (uint32_t)((uint64_t)x*rw/dw), sx, sy;
            int64_t pos;
            const uint8_t *p;
            uint8_t *q = dst+((size_t)y*dw+x)*3;
            switch (rotation) {
                case 1: sx=ry; sy=ch-1-rx; break;
                case 2: sx=cw-1-rx; sy=ch-1-ry; break;
                case 3: sx=cw-1-ry; sy=rx; break;
                default: sx=rx; sy=ry; break;
            }
            pos=(int64_t)offset+(int64_t)(sy+cy)*stride+(int64_t)(sx+cx)*4;
            p=src+(size_t)pos;
            q[0]=p[rgb_order ? 0 : 2]; q[1]=p[1]; q[2]=p[rgb_order ? 2 : 0];
        }
    }
    return 1;
}
/* Update a rectangle in a persistent, native-size RGB24 image from a
 * top-down BGRA plane. All bounds are checked before touching the output.
 * Rotation/downscaling continue to use kvm_pixels_rgb above. */
static inline int kvm_pixels_rgb_rect(const uint8_t *src,size_t size,
    uint32_t stride,uint32_t w,uint32_t h,uint32_t x,uint32_t y,
    uint32_t rw,uint32_t rh,uint8_t *dst,size_t capacity) {
    uint32_t row,col;
    if (!src || !dst || !kvm_dimensions(w,h) || !rw || !rh ||
        x>w || y>h || rw>w-x || rh>h-y || (uint64_t)stride<(uint64_t)w*4 ||
        (uint64_t)(h-1)*stride+(uint64_t)w*4>size ||
        (uint64_t)w*h*3>capacity) return 0;
    for (row=y;row<y+rh;++row) {
        const uint8_t *p=src+(size_t)row*stride+(size_t)x*4;
        uint8_t *q=dst+((size_t)row*w+x)*3;
        for (col=0;col<rw;++col,p+=4,q+=3) {
            q[0]=p[2]; q[1]=p[1]; q[2]=p[0];
        }
    }
    return 1;
}
#endif
