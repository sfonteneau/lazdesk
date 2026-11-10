#include <assert.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stddef.h>
uint32_t lazdesk_session_abi(void);
void *lazdesk_session_open(void);
int lazdesk_session_poll(void *,char *,size_t);
void lazdesk_session_close(void *);
int main(void) {
  void *mock=dlopen("libsystemd.so.0",RTLD_NOW|RTLD_LOCAL),*s;
  void (*mode)(int); char id[128];
  assert(mock); *(void **)(&mode)=dlsym(mock,"test_set_mode"); assert(mode);
  assert(lazdesk_session_abi()==0x00090001);
  s=lazdesk_session_open(); assert(s);
  mode(0);assert(lazdesk_session_poll(s,id,sizeof(id))==1);assert(strstr(id,":session-a"));
  mode(1);assert(lazdesk_session_poll(s,id,sizeof(id))==2);
  mode(2);assert(lazdesk_session_poll(s,id,sizeof(id))==3);
  mode(3);assert(lazdesk_session_poll(s,id,sizeof(id))==4);
  mode(4);assert(lazdesk_session_poll(s,id,sizeof(id))==0);
  mode(5);assert(lazdesk_session_poll(s,id,sizeof(id))==0);
  mode(6);assert(lazdesk_session_poll(s,id,sizeof(id))==3);
  mode(7);assert(lazdesk_session_poll(s,id,sizeof(id))==4);
  mode(8);assert(lazdesk_session_poll(s,id,sizeof(id))==0);
  mode(0);assert(lazdesk_session_poll(s,id,sizeof(id))==1);
  assert(lazdesk_session_poll(s,id,1)==0);
  lazdesk_session_close(s);
  for(int i=0;i<1000;i++) { s=lazdesk_session_open();assert(s); assert(lazdesk_session_poll(s,id,sizeof(id))==1);lazdesk_session_close(s); }
  dlclose(mock);
  puts("PASS: real session bridge / mocked logind: active, locked, inactive, uid/session changes, errors, recovery, 1000 lifetime cycles");
  return 0;
}
