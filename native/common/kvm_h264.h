#ifndef LAZDESK_H264_H
#define LAZDESK_H264_H
/* Bounded Annex-B / AVC conversion. No allocation; also used by tests. */
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#define KVM_H264_CAP (2u * 1024u * 1024u)
#define KVM_NAL_SPS 1u
#define KVM_NAL_PPS 2u
#define KVM_NAL_IDR 4u
/* Allocation envelope only, not SPS validation. Visible dimensions are
 * checked again after decode. H.264 allocation may include macroblock padding. */
static int kvm_h264_allocation_ok(int w,int h,int expected_w,int expected_h) {
  if(expected_w<2 || expected_h<2 || expected_w>32768 || expected_h>32768 ||
     (int64_t)expected_w*expected_h>67108864 || w<expected_w || h<expected_h)
    return 0;
  return w<=32768 && h<=32768 && (int64_t)w*h<=67108864 &&
         w<=((expected_w+15)&~15) && h<=((expected_h+31)&~31);
}
static int kvm_startcode(const uint8_t *p, size_t n, size_t i) {
  if (i <= n && n-i >= 3 && p[i]==0 && p[i+1]==0) {
    if (p[i+2]==1) return 3;
    if (n-i >= 4 && p[i+2]==0 && p[i+3]==1) return 4;
  }
  return 0;
}
/* Reject non-IDR VCL: every wire access unit is independently decodable. */
static int kvm_h264_scan(const uint8_t *p, size_t n, unsigned *flags) {
  size_t i=0, start, end; int sc; unsigned f=0; unsigned count=0;
  if (!p || !flags || n<5 || n>KVM_H264_CAP) return 0;
  while (i<n && p[i]==0 && !kvm_startcode(p,n,i)) ++i;
  if (!kvm_startcode(p,n,i)) return 0;
  while (i<n) {
    sc=kvm_startcode(p,n,i); if (!sc) return 0;
    start=i+(size_t)sc; if (start>=n || (p[start]&0x80)) return 0;
    end=start+1; while (end<n && !kvm_startcode(p,n,end)) ++end;
    if (++count>1024) return 0;
    switch (p[start]&31) {
      case 5: f|=KVM_NAL_IDR; break;
      case 7: f|=KVM_NAL_SPS; break;
      case 8: f|=KVM_NAL_PPS; break;
      case 1: case 2: case 3: case 4: return 0;
      case 6: case 9: case 10: case 11: case 12: break;
      default: return 0;
    }
    i=end;
  }
  *flags=f; return 1;
}
static int kvm_put_nal(uint8_t *out, size_t cap, size_t *at,
                       const uint8_t *p, size_t n) {
  static const uint8_t sc[4]={0,0,0,1};
  if (!out || !at || !p || !n || *at>cap || cap-*at<4 || n>cap-*at-4) return 0;
  memcpy(out+*at,sc,4); *at+=4; memcpy(out+*at,p,n); *at+=n; return 1;
}
/* ISO/IEC 14496-15 AVCDecoderConfigurationRecord -> SPS/PPS Annex-B. */
static int kvm_avcc_config(const uint8_t *p, size_t n, uint8_t *out,
                           size_t cap, size_t *written, unsigned *length_size) {
  size_t at=6, used=0, len; unsigned group,j,count;
  if (!p || n<7 || p[0]!=1 || !written || !length_size) return 0;
  *length_size=(p[4]&3)+1; count=p[5]&31;
  if (!count) return 0;
  for(group=0;group<2;++group) {
    if(group) { if(at>=n) return 0; count=p[at++]; if(!count) return 0; }
    for(j=0;j<count;++j) {
      if(at>n || n-at<2) return 0;
      len=((size_t)p[at]<<8)|p[at+1]; at+=2;
      if(!len || len>n-at || (p[at]&31)!=(group?8:7)) return 0;
      if(!kvm_put_nal(out,cap,&used,p+at,len)) return 0; at+=len;
    }
  }
  *written=used; return 1;
}
static int kvm_avcc_packet(const uint8_t *p, size_t n, unsigned length_size,
                          uint8_t *out, size_t cap, size_t *written) {
  size_t at=0,used=0,len; unsigned j;
  if(!p || !written || length_size<1 || length_size>4 || n>KVM_H264_CAP) return 0;
  while(at<n) {
    if(n-at<length_size) return 0; len=0;
    for(j=0;j<length_size;++j) len=(len<<8)|p[at++];
    if(!len || len>n-at || !kvm_put_nal(out,cap,&used,p+at,len)) return 0;
    at+=len;
  }
  *written=used; return used!=0;
}
#endif
