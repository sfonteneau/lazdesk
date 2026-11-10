#include "../native/common/kvm_h264.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
static uint32_t seed=0x79a1u;
static uint32_t rnd(void) { seed^=seed<<13; seed^=seed>>17; seed^=seed<<5; return seed; }
int main(void) {
  assert(kvm_h264_allocation_ok(1920,1088,1920,1080));
  assert(kvm_h264_allocation_ok(640,368,640,360));
  assert(!kvm_h264_allocation_ok(1920,1120,1920,1080));
  assert(!kvm_h264_allocation_ok(1920,1080,1920,1088));
  assert(!kvm_h264_allocation_ok(32768,32768,32768,32768));
  assert(kvm_h264_allocation_ok(15360,2160,15360,2160));
  /* Syntax fixtures only: these NAL payloads are not decodable pictures. */
  const uint8_t annex[]={0,0,0,1,0x67,0x42,0,0,1,0x68,0xab,0,0,0,1,0x65,0xaa};
  const uint8_t avcc[]={1,66,0,30,255,225,0,2,0x67,0x42,1,0,2,0x68,0xab};
  const uint8_t packet[]={0,0,0,2,0x65,0xaa};
  unsigned flags=0,ls=0; size_t used=0; uint8_t out[4097],buf[4096];
  assert(kvm_h264_scan(annex,sizeof(annex),&flags) && flags==7);
  assert(kvm_avcc_config(avcc,sizeof(avcc),out,4096,&used,&ls)); assert(used==12 && ls==4);
  assert(kvm_h264_scan(out,used,&flags) && flags==3);
  assert(kvm_avcc_packet(packet,sizeof(packet),4,out,4096,&used)); assert(used==6);
  assert(kvm_h264_scan(out,used,&flags) && flags==4);
  memcpy(buf,annex,sizeof(annex)); buf[15]=0x41; assert(!kvm_h264_scan(buf,sizeof(annex),&flags));
  for(size_t n=0;n<sizeof(avcc);n++) assert(!kvm_avcc_config(avcc,n,out,4096,&used,&ls));
  for(size_t cap=0;cap<12;cap++) {
    memset(out,0xa5,sizeof(out)); assert(!kvm_avcc_config(avcc,sizeof(avcc),out,cap,&used,&ls));
    assert(out[cap]==0xa5);
  }
  for(unsigned iteration=0;iteration<100000;iteration++) {
    size_t n=rnd()%sizeof(buf),cap=rnd()%4097u;
    for(size_t j=0;j<n;j++) buf[j]=(uint8_t)rnd();
    if(n>5 && (iteration%3)==0) { buf[0]=buf[1]=0; buf[2]=1; }
    memset(out,0xa5,sizeof(out));
    kvm_h264_scan(buf,n,&flags);
    kvm_avcc_config(buf,n,out,cap,&used,&ls); assert(out[cap]==0xa5);
    kvm_avcc_packet(buf,n,1+rnd()%4,out,cap,&used); assert(out[cap]==0xa5);
  }
  puts("PASS: Annex-B/AVCC fixtures, allocation envelope, truncations, 100000 bounded malformed inputs (not a codec decoder test)");
  return 0;
}
