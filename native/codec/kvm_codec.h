#ifndef LAZDESK_CODEC_H
#define LAZDESK_CODEC_H
#include <stddef.h>
#include <stdint.h>
#ifdef KVM_STATIC_BUILD
# define KVM_API
#elif defined(_WIN32)
# define KVM_API __declspec(dllexport)
#else
# define KVM_API __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
extern "C" {
#endif
KVM_API uint32_t lazdesk_codec_abi(void);
KVM_API void *lazdesk_encoder_open(const char *name, const char *device,
  int w,int h,int fps,int kbps,char *error,size_t error_cap);
KVM_API int lazdesk_encode(void *handle,const uint8_t *rgb,size_t rgb_len,
  uint8_t *out,size_t cap,size_t *written,char *error,size_t error_cap);
/* Optional additive fast paths; original ABI and RGB functions unchanged. */
KVM_API int lazdesk_encode_bgr24(void *handle,const uint8_t *bgr,size_t bgr_len,
  uint8_t *out,size_t cap,size_t *written,char *error,size_t error_cap);
KVM_API int lazdesk_decode_bgrx32(void *handle,const uint8_t *packet,size_t packet_len,
  int w,int h,uint8_t *bgrx,size_t bgrx_cap,char *error,size_t error_cap);
KVM_API void lazdesk_encoder_close(void *handle);
KVM_API void *lazdesk_decoder_open(char *error,size_t error_cap);
KVM_API int lazdesk_decode(void *handle,const uint8_t *packet,size_t packet_len,
  int w,int h,uint8_t *rgb,size_t rgb_cap,char *error,size_t error_cap);
KVM_API void lazdesk_decoder_close(void *handle);
#ifdef __cplusplus
}
#endif
#endif
