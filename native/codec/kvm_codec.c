/* Original LazDesk bridge to the public FFmpeg API (libavcodec/avutil/swscale).
 * One handle belongs to one caller thread. No libavformat, URL or file input.
 * Each returned H.264 AU includes SPS/PPS + IDR: safe for independent viewers,
 * dropped batches and geometry/profile changes, without decoder history.
 * This intentionally trades inter-frame bitrate efficiency for bounded state.
 */
#include "kvm_codec.h"
#include "../common/kvm_h264.h"
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <libavcodec/avcodec.h>
#include <libavutil/opt.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libavutil/dict.h>
#include <libswscale/swscale.h>

#define MAX_SIDE 32768
#define MAX_PIXELS 67108864LL
#define ABI 0x00090001u
static int error_code(char *e,size_t cap,const char *where,int code) {
  char msg[AV_ERROR_MAX_STRING_SIZE]; av_strerror(code,msg,sizeof(msg));
  if(e && cap) snprintf(e,cap,"%s: %s",where,msg); return -1;
}
static int error_text(char *e,size_t cap,const char *text) {
  if(e && cap) snprintf(e,cap,"%s",text); return -1;
}
static int dimensions(int w,int h) {
  return w>0 && h>0 && w<=MAX_SIDE && h<=MAX_SIDE && (int64_t)w*h<=MAX_PIXELS;
}
static void option(AVCodecContext *c,const char *key,const char *val) {
  if(c->priv_data && av_opt_find(c->priv_data,key,NULL,0,0))
    av_opt_set(c->priv_data,key,val,0);
}
typedef struct {
  AVCodecContext *ctx; AVFrame *sw,*hw; AVPacket *pkt; AVBufferRef *device;
  struct SwsContext *scale; int w,h,hardware_frames; int64_t pts;
  uint8_t *scratch; uint8_t config[65536]; size_t config_len; unsigned nal_length;
} Encoder;
typedef struct {
  AVCodecContext *ctx; AVFrame *frame; AVPacket *pkt;
  struct SwsContext *scale; int expected_w,expected_h,allocations;
} Decoder;
KVM_API uint32_t lazdesk_codec_abi(void) { return ABI; }
KVM_API void lazdesk_encoder_close(void *opaque) {
  Encoder *e=opaque; if(!e) return;
  av_frame_free(&e->sw); av_frame_free(&e->hw); av_packet_free(&e->pkt);
  avcodec_free_context(&e->ctx); av_buffer_unref(&e->device);
  sws_freeContext(e->scale); av_free(e->scratch); free(e);
}
KVM_API void *lazdesk_encoder_open(const char *name,const char *device,
    int w,int h,int fps,int kbps,char *err,size_t ec) {
  const AVCodec *codec; Encoder *e=NULL; AVHWFramesContext *frames;
  enum AVHWDeviceType hwtype=AV_HWDEVICE_TYPE_NONE;
  enum AVPixelFormat swformat=AV_PIX_FMT_NV12; int rc;
  if(!name || !dimensions(w,h) || (w&1) || (h&1) || fps<1 || fps>60 || kbps<128 || kbps>100000) {
    error_text(err,ec,"Invalid encoder parameters"); return NULL;
  }
  if(!strcmp(name,"h264_vaapi")) hwtype=AV_HWDEVICE_TYPE_VAAPI;
  else if(!strcmp(name,"h264_qsv")) hwtype=AV_HWDEVICE_TYPE_QSV;
  else if(strcmp(name,"h264_nvenc") && strcmp(name,"h264_amf") && strcmp(name,"h264_videotoolbox")) {
#ifdef KVM_CODEC_TEST_SOFTWARE
    if(strcmp(name,"libx264")) { error_text(err,ec,"Encoder not allowed"); return NULL; }
    swformat=AV_PIX_FMT_YUV420P;
#else
    error_text(err,ec,"Encoder not allowed (no silent software H.264 fallback)"); return NULL;
#endif
  }
  codec=avcodec_find_encoder_by_name(name);
  if(!codec) { error_text(err,ec,"Encoder unavailable in this FFmpeg build"); return NULL; }
  e=calloc(1,sizeof(*e)); if(!e) return NULL;
  e->ctx=avcodec_alloc_context3(codec); e->sw=av_frame_alloc(); e->pkt=av_packet_alloc();
  e->scratch=av_malloc(KVM_H264_CAP); e->w=w; e->h=h; e->nal_length=4;
  if(!e->ctx || !e->sw || !e->pkt || !e->scratch) goto oom;
  e->ctx->width=w; e->ctx->height=h; e->ctx->time_base.num=1; e->ctx->time_base.den=fps;
  e->ctx->framerate.num=fps; e->ctx->framerate.den=1; e->ctx->bit_rate=(int64_t)kbps*1000;
  e->ctx->gop_size=1; e->ctx->max_b_frames=0; e->ctx->refs=1; e->ctx->thread_count=1;
  e->ctx->flags|=AV_CODEC_FLAG_LOW_DELAY|AV_CODEC_FLAG_GLOBAL_HEADER;
  e->ctx->pix_fmt=swformat;
  if(hwtype!=AV_HWDEVICE_TYPE_NONE) {
    const char *dev=(device && *device)?device:NULL;
    AVDictionary *opts=NULL;
    if(hwtype==AV_HWDEVICE_TYPE_QSV) {
      /* QSV's device argument selects hw/auto, not a DRM path. */
      if(dev) av_dict_set(&opts,"child_device",dev,0);
      dev="hw"; /* prohibit a software MFX implementation */
    }
    rc=av_hwdevice_ctx_create(&e->device,hwtype,dev,opts,0);
    av_dict_free(&opts); if(rc<0) goto avfail;
    e->ctx->hw_device_ctx=av_buffer_ref(e->device); if(!e->ctx->hw_device_ctx) goto oom;
    e->ctx->pix_fmt=hwtype==AV_HWDEVICE_TYPE_QSV?AV_PIX_FMT_QSV:AV_PIX_FMT_VAAPI;
    e->ctx->hw_frames_ctx=av_hwframe_ctx_alloc(e->device); if(!e->ctx->hw_frames_ctx) goto oom;
    frames=(AVHWFramesContext *)e->ctx->hw_frames_ctx->data;
    frames->format=e->ctx->pix_fmt; frames->sw_format=swformat;
    frames->width=w; frames->height=h; frames->initial_pool_size=8;
    rc=av_hwframe_ctx_init(e->ctx->hw_frames_ctx); if(rc<0) goto avfail;
    e->hardware_frames=1;
  }
  option(e->ctx,"async_depth","1"); option(e->ctx,"rc-lookahead","0");
  option(e->ctx,"forced_idr","1"); option(e->ctx,"forced-idr","1"); option(e->ctx,"zerolatency","1");
  option(e->ctx,"delay","0"); option(e->ctx,"aud","1");
  if(!strcmp(name,"h264_nvenc")) {
    option(e->ctx,"preset","p1"); option(e->ctx,"tune","ull");
    if(device && *device) {
      if(!av_opt_find(e->ctx->priv_data,"gpu",NULL,0,0) ||
         (rc=av_opt_set(e->ctx->priv_data,"gpu",device,0))<0) { rc=AVERROR(EINVAL); goto avfail; }
    }
  } else if(hwtype==AV_HWDEVICE_TYPE_NONE && device && *device) {
    error_text(err,ec,"Explicit GPU selection is unsupported for this encoder");
    lazdesk_encoder_close(e); return NULL;
  }
  if(!strcmp(name,"h264_amf")) option(e->ctx,"usage","ultralowlatency");
  if(!strcmp(name,"h264_videotoolbox")) {
    option(e->ctx,"allow_sw","0"); option(e->ctx,"require_sw","0"); option(e->ctx,"realtime","1");
  }
#ifdef KVM_CODEC_TEST_SOFTWARE
  if(!strcmp(name,"libx264")) {
    option(e->ctx,"preset","ultrafast"); option(e->ctx,"tune","zerolatency");
    option(e->ctx,"x264-params","keyint=1:min-keyint=1:scenecut=0:repeat-headers=1:annexb=1");
  }
#endif
  rc=avcodec_open2(e->ctx,codec,NULL); if(rc<0) goto avfail;
  e->sw->format=swformat; e->sw->width=w; e->sw->height=h;
  rc=av_frame_get_buffer(e->sw,32); if(rc<0) goto avfail;
  e->scale=sws_getContext(w,h,AV_PIX_FMT_RGB24,w,h,swformat,SWS_FAST_BILINEAR,NULL,NULL,NULL);
  if(!e->scale) goto oom;
  if(err && ec) err[0]=0; return e;
oom: rc=AVERROR(ENOMEM);
avfail: error_code(err,ec,"Opening encoder",rc); lazdesk_encoder_close(e); return NULL;
}
static int config(Encoder *e,char *err,size_t ec) {
  const uint8_t *p=e->ctx->extradata; int n=e->ctx->extradata_size; unsigned flags;
  e->config_len=0;
  if(!p || n<=0) return 0; /* packet may carry all parameter sets */
  if((size_t)n>sizeof(e->config)) return error_text(err,ec,"Extradata too large");
  if(kvm_startcode(p,(size_t)n,0)) {
    if(!kvm_h264_scan(p,(size_t)n,&flags)) return error_text(err,ec,"Malformed encoder extradata");
    memcpy(e->config,p,(size_t)n); e->config_len=(size_t)n;
  } else if(!kvm_avcc_config(p,(size_t)n,e->config,sizeof(e->config),&e->config_len,&e->nal_length))
    return error_text(err,ec,"Invalid AVC configuration");
  return 0;
}
static int encode_pixels(void *opaque,const uint8_t *rgb,size_t rgb_len,
    uint8_t *out,size_t cap,size_t *written,char *err,size_t ec,
    enum AVPixelFormat source_format) {
  Encoder *e=opaque; int rc; size_t n; unsigned flags; AVFrame *input;
  const uint8_t *source[4]={rgb,NULL,NULL,NULL}; int stride[4];
  if(written) *written=0;
  if(!e || !rgb || !out || !written || cap>KVM_H264_CAP ||
     rgb_len!=(size_t)e->w*(size_t)e->h*3) return error_text(err,ec,"Invalid RGB buffer");
  rc=av_frame_make_writable(e->sw); if(rc<0) return error_code(err,ec,"RGB buffer",rc);
  e->scale=sws_getCachedContext(e->scale,e->w,e->h,source_format,
    e->w,e->h,(enum AVPixelFormat)e->sw->format,SWS_FAST_BILINEAR,NULL,NULL,NULL);
  if(!e->scale) return error_code(err,ec,"Encoder scaler",AVERROR(ENOMEM));
  stride[0]=e->w*3; stride[1]=stride[2]=stride[3]=0;
  if(sws_scale(e->scale,source,stride,0,e->h,e->sw->data,e->sw->linesize)!=e->h)
    return error_text(err,ec,"RGB conversion incomplete");
  e->sw->pts=e->pts++; e->sw->pict_type=AV_PICTURE_TYPE_I; input=e->sw;
  if(e->hardware_frames) {
    av_frame_free(&e->hw); e->hw=av_frame_alloc(); if(!e->hw) return error_code(err,ec,"HW frame",AVERROR(ENOMEM));
    rc=av_hwframe_get_buffer(e->ctx->hw_frames_ctx,e->hw,0);
    if(rc<0) return error_code(err,ec,"HW buffer",rc);
    rc=av_hwframe_transfer_data(e->hw,e->sw,0); if(rc<0) return error_code(err,ec,"GPU upload",rc);
    e->hw->pts=e->sw->pts; e->hw->pict_type=AV_PICTURE_TYPE_I; input=e->hw;
  }
  rc=avcodec_send_frame(e->ctx,input); if(rc<0) return error_code(err,ec,"Encode send",rc);
  av_packet_unref(e->pkt); rc=avcodec_receive_packet(e->ctx,e->pkt);
  if(rc==AVERROR(EAGAIN)) return error_text(err,ec,"Encoder buffers frames despite low-latency settings; unsupported by this intra transport");
  if(rc<0) return error_code(err,ec,"Encode receive",rc);
  if(e->pkt->size<=0 || (size_t)e->pkt->size>KVM_H264_CAP) return error_text(err,ec,"Encoded packet exceeds cap");
  if(config(e,err,ec)<0) return -1;
  if(kvm_startcode(e->pkt->data,(size_t)e->pkt->size,0)) {
    n=(size_t)e->pkt->size; memcpy(e->scratch,e->pkt->data,n);
  } else if(!kvm_avcc_packet(e->pkt->data,(size_t)e->pkt->size,e->nal_length,
             e->scratch,KVM_H264_CAP,&n)) return error_text(err,ec,"Invalid encoded AVC packet");
  if(!kvm_h264_scan(e->scratch,n,&flags) || !(flags & KVM_NAL_IDR))
    return error_text(err,ec,"Encoder did not emit an independent IDR");
  if((flags & (KVM_NAL_SPS|KVM_NAL_PPS)) != (KVM_NAL_SPS|KVM_NAL_PPS)) {
    if(e->config_len>cap || n>cap-e->config_len) return error_text(err,ec,"H.264 output exceeds cap");
    memcpy(out,e->config,e->config_len); memcpy(out+e->config_len,e->scratch,n); n+=e->config_len;
  } else { if(n>cap) return error_text(err,ec,"H.264 output exceeds cap"); memcpy(out,e->scratch,n); }
  if(!kvm_h264_scan(out,n,&flags) || flags!=7) return error_text(err,ec,"Missing SPS/PPS/IDR");
  *written=n; if(err && ec) err[0]=0; return 0;
}
/* Additive ABI: legacy RGB entry points remain usable by older clients. */
KVM_API int lazdesk_encode(void *opaque,const uint8_t *rgb,size_t rgb_len,
    uint8_t *out,size_t cap,size_t *written,char *err,size_t ec) {
  return encode_pixels(opaque,rgb,rgb_len,out,cap,written,err,ec,AV_PIX_FMT_RGB24);
}
KVM_API int lazdesk_encode_bgr24(void *opaque,const uint8_t *bgr,size_t bgr_len,
    uint8_t *out,size_t cap,size_t *written,char *err,size_t ec) {
  return encode_pixels(opaque,bgr,bgr_len,out,cap,written,err,ec,AV_PIX_FMT_BGR24);
}
static int guarded_buffer(AVCodecContext *ctx,AVFrame *frame,int flags) {
  Decoder *d=ctx->opaque;
  /* Allocation dimensions can include H.264 macroblock padding (1080 ->
   * 1088, for example). Check a small bounded envelope here, and require
   * the exact visible dimensions after avcodec_receive_frame(). */
  if(!d || !kvm_h264_allocation_ok(frame->width,frame->height,d->expected_w,d->expected_h) ||
     (frame->format!=AV_PIX_FMT_YUV420P && frame->format!=AV_PIX_FMT_YUVJ420P) ||
     ctx->refs>2 || ++d->allocations>4)
    return AVERROR_INVALIDDATA;
  return avcodec_default_get_buffer2(ctx,frame,flags);
}
KVM_API void lazdesk_decoder_close(void *opaque) {
  Decoder *d=opaque; if(!d) return; avcodec_free_context(&d->ctx);
  av_frame_free(&d->frame); av_packet_free(&d->pkt); sws_freeContext(d->scale); free(d);
}
KVM_API void *lazdesk_decoder_open(char *err,size_t ec) {
  const AVCodec *codec=avcodec_find_decoder(AV_CODEC_ID_H264); Decoder *d; int rc;
  if(!codec) { error_text(err,ec,"H.264 decoder unavailable"); return NULL; }
  d=calloc(1,sizeof(*d)); if(!d) return NULL;
  d->ctx=avcodec_alloc_context3(codec); d->frame=av_frame_alloc(); d->pkt=av_packet_alloc();
  if(!d->ctx || !d->frame || !d->pkt) { rc=AVERROR(ENOMEM); goto fail; }
  d->ctx->thread_count=1; d->ctx->thread_type=0; d->ctx->max_pixels=MAX_PIXELS;
  d->ctx->flags|=AV_CODEC_FLAG_LOW_DELAY; d->ctx->err_recognition=AV_EF_EXPLODE|AV_EF_CAREFUL;
  d->ctx->opaque=d; d->ctx->get_buffer2=guarded_buffer;
  rc=avcodec_open2(d->ctx,codec,NULL); if(rc<0) goto fail;
  if(err && ec) err[0]=0; return d;
fail: error_code(err,ec,"Opening decoder",rc); lazdesk_decoder_close(d); return NULL;
}
static int decode_pixels(void *opaque,const uint8_t *p,size_t n,int w,int h,
    uint8_t *rgb,size_t cap,char *err,size_t ec,
    enum AVPixelFormat dest_format,int pixel_bytes) {
  Decoder *d=opaque; unsigned flags; int rc; uint8_t *out[4]={rgb,NULL,NULL,NULL}; int stride[4];
  if(!d || !rgb || !dimensions(w,h) || (w&1) || (h&1) || cap<(size_t)w*(size_t)h*(size_t)pixel_bytes ||
     !kvm_h264_scan(p,n,&flags) || flags!=7) return error_text(err,ec,"Invalid independent H.264 access unit");
  /* No history is needed or retained across network messages. */
  avcodec_flush_buffers(d->ctx); d->expected_w=w; d->expected_h=h; d->allocations=0;
  av_packet_unref(d->pkt); rc=av_new_packet(d->pkt,(int)n);
  if(rc<0) return error_code(err,ec,"Decoder allocation",rc);
  memcpy(d->pkt->data,p,n); /* av_new_packet supplies required zero padding */
  av_frame_unref(d->frame); rc=avcodec_send_packet(d->ctx,d->pkt);
  if(rc<0) return error_code(err,ec,"Decode send",rc);
  rc=avcodec_receive_frame(d->ctx,d->frame);
  if(rc<0) return error_code(err,ec,"Decode receive",rc);
  if(d->frame->width!=w || d->frame->height!=h || d->frame->decode_error_flags)
    return error_text(err,ec,"Decoded dimensions or picture are invalid");
  d->scale=sws_getCachedContext(d->scale,w,h,(enum AVPixelFormat)d->frame->format,
    w,h,dest_format,SWS_FAST_BILINEAR,NULL,NULL,NULL);
  if(!d->scale) return error_code(err,ec,"Decoder scaler",AVERROR(ENOMEM));
  stride[0]=w*pixel_bytes; stride[1]=stride[2]=stride[3]=0;
  if(sws_scale(d->scale,(const uint8_t *const *)d->frame->data,d->frame->linesize,0,h,out,stride)!=h)
    return error_text(err,ec,"Decoded RGB conversion incomplete");
  if(err && ec) err[0]=0; return 0;
}

KVM_API int lazdesk_decode(void *opaque,const uint8_t *p,size_t n,int w,int h,
    uint8_t *rgb,size_t cap,char *err,size_t ec) {
  return decode_pixels(opaque,p,n,w,h,rgb,cap,err,ec,AV_PIX_FMT_RGB24,3);
}
KVM_API int lazdesk_decode_bgrx32(void *opaque,const uint8_t *p,size_t n,int w,int h,
    uint8_t *bgrx,size_t cap,char *err,size_t ec) {
  /* BGRA supplies opaque alpha (255) for the existing top-down BGRX surface. */
  return decode_pixels(opaque,p,n,w,h,bgrx,cap,err,ec,AV_PIX_FMT_BGRA,4);
}
