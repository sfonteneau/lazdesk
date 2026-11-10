/* Real FFmpeg fast/legacy paths. libx264 is enabled for this test build only. */
#include "../native/codec/kvm_codec.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define W 64
#define H 32
#define N (W*H)
int main(void) {
  unsigned char rgb[N*3],bgr[N*3],decoded[N*3+1],bgrx[N*4+1];
  unsigned char *packet=malloc(3*1024*1024);
  char error[512]={0}; size_t written=0; void *encoder,*decoder;
  assert(packet);
  encoder=lazdesk_encoder_open("libx264","",W,H,30,8000,error,sizeof(error));
  if(!encoder) { fprintf(stderr,"NOT RUN: test libx264 encoder unavailable: %s\n",error); free(packet); return 2; }
  decoder=lazdesk_decoder_open(error,sizeof(error)); assert(decoder);
  for (int i=0;i<N;i++) {
    rgb[i*3]=(unsigned char)(20+(i%W)/16*55);
    rgb[i*3+1]=(unsigned char)(30+(i/W)/8*55);
    rgb[i*3+2]=80;
    bgr[i*3]=rgb[i*3+2]; bgr[i*3+1]=rgb[i*3+1]; bgr[i*3+2]=rgb[i*3];
  }
  for(int pass=0;pass<8;pass++) {
    int rc=(pass&1)?
      lazdesk_encode_bgr24(encoder,bgr,sizeof(bgr),packet,3*1024*1024,&written,error,sizeof(error)):
      lazdesk_encode(encoder,rgb,sizeof(rgb),packet,3*1024*1024,&written,error,sizeof(error));
    if(rc) fprintf(stderr,"Encoder: %s\n",error);
    assert(rc==0 && written>0);
    memset(decoded,0xa5,sizeof(decoded)); memset(bgrx,0xa5,sizeof(bgrx));
    rc=lazdesk_decode(decoder,packet,written,W,H,decoded,N*3,error,sizeof(error));
    if(rc) fprintf(stderr,"Decoder RGB: %s\n",error);
    assert(rc==0);
    rc=lazdesk_decode_bgrx32(decoder,packet,written,W,H,bgrx,N*4,error,sizeof(error));
    if(rc) fprintf(stderr,"Decoder BGRX: %s\n",error);
    assert(rc==0);
    for(int i=0;i<N;i++) {
      assert(abs((int)bgrx[i*4]-(int)decoded[i*3+2])<=4);
      assert(abs((int)bgrx[i*4+1]-(int)decoded[i*3+1])<=4);
      assert(abs((int)bgrx[i*4+2]-(int)decoded[i*3])<=4);
      assert(bgrx[i*4+3]==255);
    }
    assert(decoded[N*3]==0xa5 && bgrx[N*4]==0xa5);
    // Check channel order using centres of solid colour blocks (not lossy edges).
    for(int y=4;y<H;y+=8) for(int x=8;x<W;x+=16) {
      int i=y*W+x;
      for(int c=0;c<3;c++) assert(abs((int)decoded[i*3+c]-(int)rgb[i*3+c])<12);
    }
    memset(bgrx,0xa5,sizeof(bgrx));
    assert(lazdesk_decode_bgrx32(decoder,packet,written,W,H,bgrx,N*4-1,error,sizeof(error))<0);
    for(size_t i=0;i<sizeof(bgrx);i++) assert(bgrx[i]==0xa5);
  }
  lazdesk_decoder_close(decoder); lazdesk_encoder_close(encoder); free(packet);
  puts("PASS: real FFmpeg RGB/BGR encoder switching, RGB/BGRX decode, channels and capacities");
  return 0;
}
