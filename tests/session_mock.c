/* Test-only libsystemd facade. Never copied to application directories. */
#define _POSIX_C_SOURCE 200809L
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
typedef struct sd_bus sd_bus;
typedef struct sd_bus_message sd_bus_message;
typedef struct { const char *name; const char *message; int need_free; } sd_bus_error;
static int mode;
void test_set_mode(int n) { mode=n; }
int sd_pid_get_session(int pid,char **s) { (void)pid; if(mode==4)return -1; *s=strdup(mode==7?"session-b":"session-a"); return *s?0:-1; }
int sd_session_get_uid(const char *s,unsigned *u) { (void)s; *u=(unsigned)getuid()+(mode==3); return 0; }
int sd_session_get_class(const char *s,char **c) { (void)s; *c=strdup(mode==6?"greeter":"user"); return *c?0:-1; }
int sd_bus_open_system(sd_bus **bus) { if(mode==8)return -1; *bus=malloc(1); return *bus?0:-1; }
sd_bus *sd_bus_unref(sd_bus *b) { free(b); return NULL; }
int sd_bus_set_method_call_timeout(sd_bus *b,uint64_t n) { (void)b; return n==150000?0:-1; }
int sd_bus_call_method(sd_bus *b,const char *dest,const char *path,const char *iface,const char *method,
    sd_bus_error *err,sd_bus_message **reply,const char *types,...) {
  (void)b;(void)dest;(void)path;(void)iface;(void)method;(void)err;(void)types;
  *reply=malloc(1);return *reply?0:-1;
}
int sd_bus_message_read(sd_bus_message *msg,const char *types,...) {
  va_list ap; (void)msg;(void)types;va_start(ap,types);*va_arg(ap,const char **)="/org/freedesktop/login1/session/test";va_end(ap);return 1;
}
sd_bus_message *sd_bus_message_unref(sd_bus_message *m) { free(m);return NULL; }
int sd_bus_get_property_trivial(sd_bus *b,const char *dest,const char *path,const char *iface,
    const char *property,sd_bus_error *err,char type,void *value) {
  (void)b;(void)dest;(void)path;(void)iface;(void)err;
  if(mode==5 || type!='b')return -1;
  *(int *)value=strcmp(property,"Active")==0?(mode!=2):(mode==1);return 0;
}
