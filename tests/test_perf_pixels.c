/* Actual shared partial converter used by the DXGI native-resolution path. */
#include "../native/common/kvm_pixels.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static uint32_t seed=0x781a325u;
static uint32_t rnd(void) { seed^=seed<<13; seed^=seed>>17; seed^=seed<<5; return seed; }
int main(void) {
  for (unsigned trial=0;trial<10000;trial++) {
    uint32_t w=1+rnd()%97,h=1+rnd()%61,stride=w*4+rnd()%17;
    size_t size=(size_t)stride*h,cap=(size_t)w*h*3;
    uint8_t *src=malloc(size),*full=malloc(cap),*partial=malloc(cap+2);
    assert(src && full && partial);
    for (size_t i=0;i<size;i++) src[i]=(uint8_t)rnd();
    memset(partial,0xa5,cap+2);
    assert(kvm_pixels_rgb_rect(src,size,stride,w,h,0,0,w,h,partial+1,cap));
    for (unsigned step=0;step<8;step++) {
      uint32_t x=rnd()%w,y=rnd()%h,rw=1+rnd()%(w-x),rh=1+rnd()%(h-y);
      for (uint32_t yy=y;yy<y+rh;yy++)
        for (uint32_t xx=x;xx<x+rw;xx++)
          for (unsigned c=0;c<4;c++) src[(size_t)yy*stride+xx*4+c]=(uint8_t)rnd();
      assert(kvm_pixels_rgb_rect(src,size,stride,w,h,x,y,rw,rh,partial+1,cap));
      assert(kvm_pixels_rgb(src,size,0,(int32_t)stride,w,h,0,0,w,h,0,0,full,cap,w,h));
      assert(!memcmp(full,partial+1,cap));
      assert(partial[0]==0xa5 && partial[cap+1]==0xa5);
    }
    memcpy(full,partial+1,cap);
    assert(!kvm_pixels_rgb_rect(src,size,stride,w,h,w,0,1,1,partial+1,cap));
    assert(!kvm_pixels_rgb_rect(src,size,stride,w,h,0,h,1,1,partial+1,cap));
    assert(!kvm_pixels_rgb_rect(src,size,stride,w,h,0,0,w,h,partial+1,cap-1));
    assert(!kvm_pixels_rgb_rect(src,(size_t)(h-1)*stride+w*4-1,stride,w,h,0,0,w,h,partial+1,cap));
    assert(!kvm_pixels_rgb_rect(src,size,w*4-1,w,h,0,0,w,h,partial+1,cap));
    assert(!kvm_pixels_rgb_rect(src,size,stride,w,h,0,0,UINT32_MAX,h,partial+1,cap));
    assert(!memcmp(full,partial+1,cap)); // rejection before the first write
    free(partial); free(full); free(src);
  }
  puts("PASS: 10000 actual partial-conversion cases, 80000 updates, bounds and guard bytes");
  return 0;
}
