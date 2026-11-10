/* LazDesk: checked virtual-desktop geometry and RGB24 composition.
 * Independent of Win32/DXGI so the actual layout math can be regression tested.
 */
#ifndef KVM_DESKTOP_MERGE_H
#define KVM_DESKTOP_MERGE_H
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include "kvm_pixels.h"

struct KvmDesktopRect {
    int32_t left, top, right, bottom;
};

static inline int kvm_project_monitor(KvmDesktopRect desktop,
    KvmDesktopRect monitor, uint32_t dest_w, uint32_t dest_h,
    KvmDesktopRect *projected) {
    int64_t sw=(int64_t)desktop.right-desktop.left;
    int64_t sh=(int64_t)desktop.bottom-desktop.top;
    if (!projected || sw<=0 || sh<=0 || !kvm_dimensions(dest_w,dest_h) ||
        monitor.left<desktop.left || monitor.top<desktop.top ||
        monitor.right>desktop.right || monitor.bottom>desktop.bottom ||
        monitor.right<=monitor.left || monitor.bottom<=monitor.top) return 0;
    // Scale EDGES (not widths) so adjacent monitors share exact seam pixels,
    // including negative desktop origins and different monitor heights.
    projected->left=(int32_t)(((int64_t)monitor.left-desktop.left)*dest_w/sw);
    projected->top=(int32_t)(((int64_t)monitor.top-desktop.top)*dest_h/sh);
    projected->right=(int32_t)(((int64_t)monitor.right-desktop.left)*dest_w/sw);
    projected->bottom=(int32_t)(((int64_t)monitor.bottom-desktop.top)*dest_h/sh);
    return projected->right>projected->left && projected->bottom>projected->top &&
        projected->right<=(int32_t)dest_w && projected->bottom<=(int32_t)dest_h;
}

static inline int kvm_merge_rgb24(uint8_t *destination,size_t dest_capacity,
    uint32_t dest_w,uint32_t dest_h,KvmDesktopRect region,
    const uint8_t *source,size_t src_capacity) {
    int64_t width=(int64_t)region.right-region.left;
    int64_t height=(int64_t)region.bottom-region.top;
    if (!destination || !source || !kvm_dimensions(dest_w,dest_h) ||
        width<1 || height<1 || region.left<0 || region.top<0 ||
        region.right>(int32_t)dest_w || region.bottom>(int32_t)dest_h ||
        (uint64_t)width*height*3>src_capacity ||
        (uint64_t)dest_w*dest_h*3>dest_capacity) return 0;
    for (int64_t y=0;y<height;++y)
        memcpy(destination+(((size_t)region.top+(size_t)y)*dest_w+region.left)*3,
            source+(size_t)y*(size_t)width*3,(size_t)width*3);
    return 1;
}
/* Copy one dirty rectangle from a cached monitor RGB24 image into its
 * projected virtual-desktop rectangle. Only valid for an unrotated monitor
 * at native resolution: no scaling or pixel-coordinate remapping is needed.
 */
static inline int kvm_merge_rgb24_damage(uint8_t *destination,size_t dest_capacity,
    uint32_t dest_w,uint32_t dest_h,KvmDesktopRect monitor,
    const uint8_t *source,size_t src_capacity,KvmDesktopRect dirty) {
    int64_t width=(int64_t)monitor.right-monitor.left;
    int64_t height=(int64_t)monitor.bottom-monitor.top;
    int64_t rw=(int64_t)dirty.right-dirty.left;
    int64_t rh=(int64_t)dirty.bottom-dirty.top;
    if (!destination || !source || !kvm_dimensions(dest_w,dest_h) ||
        width<1 || height<1 || dirty.left<0 || dirty.top<0 ||
        rw<1 || rh<1 || dirty.right>width || dirty.bottom>height ||
        monitor.left<0 || monitor.top<0 || monitor.right>(int32_t)dest_w ||
        monitor.bottom>(int32_t)dest_h ||
        (uint64_t)dest_w*dest_h*3>dest_capacity ||
        (uint64_t)width*height*3>src_capacity) return 0;
    for (int64_t row=dirty.top;row<dirty.bottom;++row)
        memcpy(destination+(((size_t)monitor.top+(size_t)row)*dest_w+
                (size_t)monitor.left+(size_t)dirty.left)*3,
            source+((size_t)row*(size_t)width+(size_t)dirty.left)*3,
            (size_t)rw*3);
    return 1;
}
#endif
