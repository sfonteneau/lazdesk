/* Native, OS-independent regression for DXGI's GDI-like quality scaling. */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "../native/common/kvm_pixels.h"
#include "../native/common/kvm_rgb_scale.h"

static void solid_and_bounded(void) {
    uint8_t pixels[6*5*4],out[6*5*3+2];
    unsigned rot,x,y;
    for(y=0;y<5;y++) for(x=0;x<6;x++) {
        uint8_t *p=pixels+(y*6+x)*4;
        p[0]=13;p[1]=87;p[2]=221;p[3]=255;
    }
    for(rot=0;rot<4;rot++) {
        memset(out,0xbd,sizeof(out));
        assert(kvm_rgb_bilinear_bgra(pixels,sizeof(pixels),6*4,6,5,rot,
            out+1,sizeof(out)-2,3,2));
        for(x=0;x<3*2;x++) {
            assert(out[1+x*3]==221);
            assert(out[1+x*3+1]==87);
            assert(out[1+x*3+2]==13);
        }
        assert(out[0]==0xbd && out[sizeof(out)-1]==0xbd);
    }
    assert(!kvm_rgb_bilinear_bgra(pixels,sizeof(pixels)-100,6*4,6,5,0,out,sizeof(out),3,2));
    assert(!kvm_rgb_bilinear_bgra(pixels,sizeof(pixels),6*4-1,6,5,0,out,sizeof(out),3,2));
    assert(!kvm_rgb_bilinear_bgra(pixels,sizeof(pixels),6*4,6,5,4,out,sizeof(out),3,2));
    assert(!kvm_rgb_bilinear_bgra(pixels,sizeof(pixels),6*4,6,5,0,out,2,3,2));
    assert(!kvm_rgb_bilinear_bgra(pixels,sizeof(pixels),6*4,6,5,0,out,sizeof(out),0,2));
}

static void smooth_half_resolution(void) {
    uint8_t checker[4*4*4]={},bilinear[2*2*3],nearest[2*2*3];
    unsigned x,y;
    for(y=0;y<4;y++) for(x=0;x<4;x++) {
        uint8_t *p=checker+(y*4+x)*4;
        p[0]=p[1]=p[2]=((x+y)&1u)?255:0;
    }
    assert(kvm_rgb_bilinear_bgra(checker,sizeof(checker),4*4,4,4,0,
        bilinear,sizeof(bilinear),2,2));
    assert(kvm_pixels_rgb(checker,sizeof(checker),0,4*4,4,4,0,0,4,4,0,0,
        nearest,sizeof(nearest),2,2));
    for(x=0;x<2*2*3;x++) {
        assert(bilinear[x]>=127 && bilinear[x]<=128);
        assert(nearest[x]==0);
    }
}

static void rotations_and_one_pixel(void) {
    uint8_t input[3*2*4]={},filtered[3*2*3],exact[3*2*3];
    unsigned rot,x,y,rw,rh;
    for(y=0;y<2;y++) for(x=0;x<3;x++) {
        uint8_t *p=input+(y*3+x)*4;
        p[0]=(uint8_t)(x*70+y);
        p[1]=(uint8_t)(y*100+x);
        p[2]=(uint8_t)(x*10+y*60);
    }
    for(rot=0;rot<4;rot++) {
        rw=(rot&1)?2:3;rh=(rot&1)?3:2;
        assert(kvm_rgb_bilinear_bgra(input,sizeof(input),3*4,3,2,rot,
            filtered,sizeof(filtered),rw,rh));
        assert(kvm_pixels_rgb(input,sizeof(input),0,3*4,3,2,0,0,3,2,rot,0,
            exact,sizeof(exact),rw,rh));
        assert(!memcmp(filtered,exact,(size_t)rw*rh*3));
        assert(kvm_rgb_bilinear_bgra(input,sizeof(input),3*4,3,2,rot,
            filtered,sizeof(filtered),1,1));
        assert(filtered[0]<=255 && filtered[1]<=255 && filtered[2]<=255);
    }
}

int main(void) {
    solid_and_bounded();
    smooth_half_resolution();
    rotations_and_one_pixel();
    puts("PASS: DXGI bilinear scale, rotations, RGB order, guarded capacity and nearest fallback");
    return 0;
}
