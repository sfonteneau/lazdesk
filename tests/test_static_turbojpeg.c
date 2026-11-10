/* Link and execute the actual classic TurboJPEG API from the selected .a.
 * No Dynlibs/dlopen and no TurboJPEG headers needed for this ABI smoke test.
 * This verifies the native archive, not the Pascal declarations or GUI. */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
extern void *tjInitCompress(void);
extern void *tjInitDecompress(void);
extern int tjDestroy(void *);
extern unsigned long tjBufSize(int,int,int);
extern int tjCompress2(void *,const unsigned char *,int,int,int,int,
                      unsigned char **,unsigned long *,int,int,int);
extern int tjDecompressHeader3(void *,const unsigned char *,unsigned long,int *,int *,int *,int *);
extern int tjDecompress2(void *,const unsigned char *,unsigned long,unsigned char *,int,int,int,int,int);
int main(void) {
    enum {W=16,H=16};
    unsigned char rgb[W*H*3],bgr[W*H*3];
    unsigned long capacity=tjBufSize(W,H,0),size=capacity;
    unsigned char *jpeg=malloc(capacity),*same=jpeg;
    void *enc=tjInitCompress(),*dec=tjInitDecompress();
    assert(enc && dec && jpeg && capacity);
    for(size_t n=0;n<sizeof(rgb);n+=3) { rgb[n]=210;rgb[n+1]=110;rgb[n+2]=30; }
    assert(tjCompress2(enc,rgb,W,W*3,H,0,&jpeg,&size,0,90,1024)==0);
    assert(jpeg==same && size>4 && size<=capacity);
    int w=0,h=0,subsample=-1,colorspace=-1;
    assert(tjDecompressHeader3(dec,jpeg,size,&w,&h,&subsample,&colorspace)==0);
    assert(w==W && h==H && subsample==0); /* actual 4:4:4 retained */
    assert(tjDecompress2(dec,jpeg,size,bgr,W,W*3,H,1,0)==0);
    assert(abs((int)bgr[0]-30)<=5 && abs((int)bgr[1]-110)<=5 && abs((int)bgr[2]-210)<=5);
    assert(tjDestroy(enc)==0 && tjDestroy(dec)==0);
    free(jpeg);
    puts("PASS: real static TurboJPEG roundtrip, 4:4:4 and BGR channel order");
    return 0;
}
