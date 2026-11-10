/* Linux current-session guard. Uses the documented libsystemd ABI through
 * dlopen: no libsystemd development headers or shell commands needed.
 * A single capture thread owns this handle. Unknown is fail-closed in strict
 * mode. LockedHint is advisory: it depends on the desktop reporting its lock.
 */
#define _POSIX_C_SOURCE 200809L
#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

typedef struct sd_bus sd_bus;
typedef struct sd_bus_message sd_bus_message;
typedef struct { const char *name; const char *message; int need_free; } sd_bus_error;
typedef struct {
  void *lib; sd_bus *bus; char *session; char *path;
  int (*pid_session)(int, char **);
  int (*session_uid)(const char *, unsigned *);
  int (*session_class)(const char *, char **);
  int (*open_system)(sd_bus **);
  sd_bus *(*bus_unref)(sd_bus *);
  int (*timeout)(sd_bus *, uint64_t);
  int (*call)(sd_bus *,const char *,const char *,const char *,const char *,sd_bus_error *,sd_bus_message **,const char *,...);
  int (*read)(sd_bus_message *,const char *,...);
  sd_bus_message *(*message_unref)(sd_bus_message *);
  int (*property)(sd_bus *,const char *,const char *,const char *,const char *,sd_bus_error *,char,void *);
} KvmSession;
#define API __attribute__((visibility("default")))
API uint32_t lazdesk_session_abi(void) { return 0x00090001; }
API void lazdesk_session_close(void *opaque) {
  KvmSession *s=opaque; if(!s) return;
  if(s->bus && s->bus_unref) s->bus_unref(s->bus);
  free(s->session); free(s->path); if(s->lib) dlclose(s->lib); free(s);
}
API void *lazdesk_session_open_ex(char *error, size_t capacity) {
  if(error && capacity) error[0]=0;
  KvmSession *s=calloc(1,sizeof(*s));
  if(!s) { if(error && capacity) snprintf(error,capacity,"allocation impossible"); return NULL; }
  s->lib=dlopen("libsystemd.so.0",RTLD_NOW|RTLD_LOCAL);
  if(!s->lib) {
    const char *e=dlerror();
    if(error && capacity) snprintf(error,capacity,"libsystemd.so.0: %s", e?e:"chargement impossible");
    goto fail;
  }
#define GET(field,name) do { \
  *(void **)(&s->field)=dlsym(s->lib,name); \
  if(!s->field) { if(error && capacity) snprintf(error,capacity,"libsystemd.so.0: symbole %s absent",name); goto fail; } \
} while(0)
  GET(pid_session,"sd_pid_get_session"); GET(session_uid,"sd_session_get_uid");
  GET(session_class,"sd_session_get_class"); GET(open_system,"sd_bus_open_system");
  GET(bus_unref,"sd_bus_unref"); GET(timeout,"sd_bus_set_method_call_timeout");
  GET(call,"sd_bus_call_method"); GET(read,"sd_bus_message_read");
  GET(message_unref,"sd_bus_message_unref"); GET(property,"sd_bus_get_property_trivial");
#undef GET
  return s;
fail: lazdesk_session_close(s); return NULL;
}
API void *lazdesk_session_open(void) {
  return lazdesk_session_open_ex(NULL,0);
}
/* states: 0 unknown, 1 active, 2 locked, 3 inactive, 4 different user/session.
 * The identity string is only local session metadata, never a credential.
 */
API int lazdesk_session_poll(void *opaque, char *identity, size_t capacity) {
  KvmSession *s=opaque; sd_bus_message *reply=NULL; char *id=NULL,*klass=NULL;
  const char *path=NULL; unsigned uid=0; int active=0,locked=0,result=0;
  if(!identity || capacity<2) return 0; identity[0]=0;
  if(!s || s->pid_session(0,&id)<0 || !id) goto done;
  if(s->session_uid(id,&uid)<0 || uid!=(unsigned)getuid()) { result=4; goto done; }
  if(s->session_class(id,&klass)<0 || !klass) goto done;
  if(strcmp(klass,"user") && strcmp(klass,"user-early") && strcmp(klass,"user-light")) {
    result=3; goto done;
  }
  if(snprintf(identity,capacity,"%u:%s",uid,id)>=(int)capacity) { identity[0]=0; goto done; }
  if(s->session && strcmp(s->session,id)) { result=4; goto done; }
  if(!s->session) { s->session=strdup(id); if(!s->session) goto done; }
  if(!s->bus) {
    if(s->open_system(&s->bus)<0) { s->bus=NULL; goto done; }
    if(s->timeout(s->bus,150000)<0) goto busfail;
  }
  if(!s->path) {
    if(s->call(s->bus,"org.freedesktop.login1","/org/freedesktop/login1",
       "org.freedesktop.login1.Manager","GetSession",NULL,&reply,"s",id)<0) goto busfail;
    if(s->read(reply,"o",&path)<0 || !path) goto busfail;
    s->path=strdup(path); if(!s->path) goto busfail;
    reply=s->message_unref(reply);
  }
  if(s->property(s->bus,"org.freedesktop.login1",s->path,"org.freedesktop.login1.Session",
        "Active",NULL,'b',&active)<0) goto busfail;
  if(s->property(s->bus,"org.freedesktop.login1",s->path,"org.freedesktop.login1.Session",
        "LockedHint",NULL,'b',&locked)<0) goto busfail;
  result=locked?2:(active?1:3); goto done;
busfail:
  if(s->bus) s->bus=s->bus_unref(s->bus);
  free(s->path); s->path=NULL;
done:
  if(reply && s) s->message_unref(reply);
  free(id); free(klass); return result;
}
