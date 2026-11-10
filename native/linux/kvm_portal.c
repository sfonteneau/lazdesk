/* LazDesk Wayland bridge: explicit desktop-portal consent + PipeWire.
 * No root, uinput, shell command, persisted restore token or hidden capture.
 * One session and one screen. Call close only after all caller threads stop.
 * Build against gio-2.0/gio-unix-2.0 and libpipewire-0.3 + SPA headers. */
#define _POSIX_C_SOURCE 200809L
#include <gio/gio.h>
#include <gio/gunixfdlist.h>
#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>
#include <spa/buffer/meta.h>
#include <spa/param/buffers.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include "../common/kvm_pixels.h"
#define API __attribute__((visibility("default")))
#define BUS "org.freedesktop.portal.Desktop"
#define PATH "/org/freedesktop/portal/desktop"
#define SC "org.freedesktop.portal.ScreenCast"
#define RD "org.freedesktop.portal.RemoteDesktop"
#define REQUEST "org.freedesktop.portal.Request"
#define SESSION "org.freedesktop.portal.Session"

typedef struct {
    GDBusConnection *bus;
    GMainContext *context;
    GMainLoop *mainloop;
    GThread *bus_thread;
    char *session;
    guint closed_subscription;
    gint closed;
    gboolean control;
    guint devices;
    uint32_t node;
    guint64 serial; // optional stable PipeWire object.serial from portal v6
    int logical_w, logical_h, fps;
    struct pw_thread_loop *loop;
    struct pw_context *pwcontext;
    struct pw_core *core;
    struct pw_stream *stream;
    struct spa_hook listener;
    struct spa_video_info_raw format;
    GMutex pixels_lock;
    uint8_t *rgb;
    size_t rgb_capacity;
    uint32_t width, height, source_w, source_h, crop_x, crop_y;
    gboolean have_frame, pw_started;
    char failure[256];
} Portal;

typedef struct { gboolean done; guint code; GVariant *results; } Response;
static void error_text(char *dst, int cap, const char *text) {
    if (dst && cap > 0) snprintf(dst, (size_t)cap, "%s", text ? text : "Portal error");
}
static void remember_error(Portal *p, const char *text) {
    g_mutex_lock(&p->pixels_lock);
    error_text(p->failure, sizeof(p->failure), text);
    p->have_frame=FALSE;
    g_mutex_unlock(&p->pixels_lock);
}
static GVariant *empty_options(void) {
    return g_variant_new_array(G_VARIANT_TYPE("{sv}"), NULL, 0);
}
static void response_cb(GDBusConnection *c, const gchar *sender, const gchar *path,
    const gchar *iface, const gchar *signal, GVariant *parameters, gpointer user) {
    Response *r=user;
    (void)c; (void)sender; (void)path; (void)iface; (void)signal;
    if (r->done) return;
    g_variant_get(parameters, "(u@a{sv})", &r->code, &r->results);
    r->done=TRUE;
}
/* Subscribe BEFORE calling the method: a quick user response must not be lost. */
static GVariant *request(Portal *p, const char *iface, const char *method,
    const char *token, GVariant *params, char *error, int cap) {
    Response r={FALSE, 2, NULL}; GError *e=NULL; GVariant *reply;
    const char *actual=NULL; char *sender, *expected; guint sub;
    gint64 deadline; size_t i;
    sender=g_strdup(g_dbus_connection_get_unique_name(p->bus)+1);
    for (i=0; sender[i]; ++i) if (sender[i]=='.') sender[i]='_';
    expected=g_strdup_printf(PATH "/request/%s/%s", sender, token); g_free(sender);
    sub=g_dbus_connection_signal_subscribe(p->bus, BUS, REQUEST, "Response",
        expected, NULL, G_DBUS_SIGNAL_FLAGS_NONE, response_cb, &r, NULL);
    reply=g_dbus_connection_call_sync(p->bus, BUS, PATH, iface, method, params,
        G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, 15000, NULL, &e);
    if (!reply) { error_text(error,cap,e ? e->message : "Portal call failed"); goto done; }
    g_variant_get(reply, "(&o)", &actual);
    if (strcmp(expected,actual)) {
        /* Modern portal handle_token contract is required. No legacy guessing. */
        error_text(error,cap,"Portal ignored handle_token; unsupported backend");
        g_dbus_connection_call(p->bus,BUS,actual,REQUEST,"Close",NULL,NULL,
            G_DBUS_CALL_FLAGS_NONE,3000,NULL,NULL,NULL); goto done;
    }
    deadline=g_get_monotonic_time()+120*G_USEC_PER_SEC;
    while (!r.done && !g_atomic_int_get(&p->closed) && g_get_monotonic_time()<deadline) {
        while (g_main_context_iteration(p->context,FALSE)) {}
        if (!r.done) g_usleep(10000);
    }
    if (!r.done) {
        g_dbus_connection_call(p->bus,BUS,expected,REQUEST,"Close",NULL,NULL,
            G_DBUS_CALL_FLAGS_NONE,3000,NULL,NULL,NULL);
        error_text(error,cap,"Portal consent timed out or session closed");
    } else if (r.code) error_text(error,cap, r.code==1 ? "Local user cancelled sharing" : "Portal rejected sharing");
done:
    g_dbus_connection_signal_unsubscribe(p->bus,sub);
    if (reply) g_variant_unref(reply);
    if (e) g_error_free(e);
    g_free(expected);
    if (!r.done || r.code) { if (r.results) g_variant_unref(r.results); return NULL; }
    return r.results;
}
static void closed_cb(GDBusConnection *c,const gchar *sender,const gchar *path,
    const gchar *iface,const gchar *signal,GVariant *params,gpointer user) {
    Portal *p=user;
    (void)c;(void)sender;(void)path;(void)iface;(void)signal;(void)params;
    g_atomic_int_set(&p->closed,1);
    remember_error(p,"Local portal session closed; restart requires new consent");
}
static gpointer bus_main(gpointer arg) {
    Portal *p=arg;
    g_main_context_push_thread_default(p->context);
    while (!g_atomic_int_get(&p->closed)) g_main_context_iteration(p->context,TRUE);
    g_main_context_pop_thread_default(p->context);
    return NULL;
}
static void stream_state(void *arg,enum pw_stream_state old,enum pw_stream_state state,const char *error) {
    Portal *p=arg; (void)old;
    if (state==PW_STREAM_STATE_ERROR) remember_error(p,error ? error : "PipeWire stream error");
    if (state==PW_STREAM_STATE_UNCONNECTED) remember_error(p,"PipeWire stream disconnected");
    if (state==PW_STREAM_STATE_PAUSED) {
        g_mutex_lock(&p->pixels_lock); p->have_frame=FALSE; p->failure[0]=0;
        g_mutex_unlock(&p->pixels_lock);
    }
}
static void stream_format(void *arg,uint32_t id,const struct spa_pod *param) {
    Portal *p=arg; uint8_t buffer[512]; const struct spa_pod *params[2];
    struct spa_pod_builder b=SPA_POD_BUILDER_INIT(buffer,sizeof(buffer));
    if (!param || id!=SPA_PARAM_Format) return;
    memset(&p->format,0,sizeof(p->format));
    if (spa_format_video_raw_parse(param,&p->format)<0 ||
        !kvm_dimensions(p->format.size.width,p->format.size.height) ||
        !(p->format.format==SPA_VIDEO_FORMAT_BGRA || p->format.format==SPA_VIDEO_FORMAT_BGRx ||
          p->format.format==SPA_VIDEO_FORMAT_RGBA || p->format.format==SPA_VIDEO_FORMAT_RGBx)) {
        remember_error(p,"Unsupported PipeWire format/geometry");
        memset(&p->format,0,sizeof(p->format)); return;
    }
    g_mutex_lock(&p->pixels_lock); p->have_frame=FALSE; g_mutex_unlock(&p->pixels_lock);
    params[0]=spa_pod_builder_add_object(&b,SPA_TYPE_OBJECT_ParamBuffers,SPA_PARAM_Buffers,
        SPA_PARAM_BUFFERS_dataType,SPA_POD_CHOICE_FLAGS_Int((1<<SPA_DATA_MemPtr)|(1<<SPA_DATA_MemFd)));
    params[1]=spa_pod_builder_add_object(&b,SPA_TYPE_OBJECT_ParamMeta,SPA_PARAM_Meta,
        SPA_PARAM_META_type,SPA_POD_Id(SPA_META_VideoCrop),
        SPA_PARAM_META_size,SPA_POD_Int(sizeof(struct spa_meta_region)));
    pw_stream_update_params(p->stream,params,2);
}
static void stream_process(void *arg) {
    Portal *p=arg; struct pw_buffer *last=NULL,*next; struct spa_buffer *buf;
    struct spa_data *plane; struct spa_meta_region *crop;
    struct spa_meta_header *header;
    uint32_t sw=p->format.size.width,sh=p->format.size.height,cx=0,cy=0,cw=sw,ch=sh;
    int rgb_order; size_t required; int32_t stride;
    while ((next=pw_stream_dequeue_buffer(p->stream))) {
        if (last) pw_stream_queue_buffer(p->stream,last);
        last=next;
    }
    if (!last) return;
    if (g_atomic_int_get(&p->closed) || !kvm_dimensions(sw,sh)) goto done;
    buf=last->buffer;
    header=spa_buffer_find_meta_data(buf,SPA_META_Header,sizeof(*header));
    if (header && (header->flags & SPA_META_HEADER_FLAG_CORRUPTED)) goto done;
    if (buf->n_datas!=1) goto done;
    plane=&buf->datas[0];
    if (!plane->data || !plane->chunk || plane->chunk->size==0 ||
        plane->chunk->offset>plane->maxsize || plane->chunk->size>plane->maxsize-plane->chunk->offset) goto done;
    crop=spa_buffer_find_meta_data(buf,SPA_META_VideoCrop,sizeof(*crop));
    if (crop && crop->region.size.width && crop->region.size.height) {
        if (crop->region.position.x<0 || crop->region.position.y<0) goto done;
        cx=(uint32_t)crop->region.position.x; cy=(uint32_t)crop->region.position.y;
        cw=crop->region.size.width; ch=crop->region.size.height;
    }
    if (!kvm_dimensions(cw,ch) || cx>sw || cy>sh || cw>sw-cx || ch>sh-cy) goto done;
    stride=plane->chunk->stride;
    if (stride<=0 || (uint64_t)(sh-1)*(uint32_t)stride+(uint64_t)sw*4>plane->chunk->size) goto done;
    rgb_order=(p->format.format==SPA_VIDEO_FORMAT_RGBA || p->format.format==SPA_VIDEO_FORMAT_RGBx);
    required=(size_t)cw*ch*3;
    g_mutex_lock(&p->pixels_lock);
    if (required>p->rgb_capacity) {
        uint8_t *new_rgb=g_try_realloc(p->rgb,required);
        if (!new_rgb) { g_mutex_unlock(&p->pixels_lock); goto done; }
        p->rgb=new_rgb; p->rgb_capacity=required;
    }
    if (kvm_pixels_rgb(plane->data,plane->maxsize,plane->chunk->offset,stride,
        sw,sh,cx,cy,cw,ch,0,rgb_order,p->rgb,p->rgb_capacity,cw,ch)) {
        p->source_w=sw; p->source_h=sh; p->crop_x=cx; p->crop_y=cy;
        p->width=cw; p->height=ch; p->have_frame=TRUE; p->failure[0]=0;
    }
    g_mutex_unlock(&p->pixels_lock);
done:
    pw_stream_queue_buffer(p->stream,last);
}
static const struct pw_stream_events stream_events={
    PW_VERSION_STREAM_EVENTS,.state_changed=stream_state,
    .param_changed=stream_format,.process=stream_process
};
API void kvm_portal_close(void *handle) {
    Portal *p=handle;
    if (!p) return;
    g_atomic_int_set(&p->closed,1);
    if (p->loop && p->pw_started) pw_thread_loop_stop(p->loop);
    if (p->stream) pw_stream_destroy(p->stream);
    if (p->core) pw_core_disconnect(p->core);
    if (p->pwcontext) pw_context_destroy(p->pwcontext);
    if (p->loop) pw_thread_loop_destroy(p->loop);
    if (p->bus && p->session) {
        GVariant *r=g_dbus_connection_call_sync(p->bus,BUS,p->session,SESSION,"Close",NULL,NULL,
            G_DBUS_CALL_FLAGS_NONE,3000,NULL,NULL);
        if (r) g_variant_unref(r);
    }
    if (p->closed_subscription) g_dbus_connection_signal_unsubscribe(p->bus,p->closed_subscription);
    if (p->context) g_main_context_wakeup(p->context);
    if (p->bus_thread) g_thread_join(p->bus_thread);
    if (p->mainloop) g_main_loop_unref(p->mainloop);
    if (p->bus) g_object_unref(p->bus);
    if (p->context) g_main_context_unref(p->context);
    g_mutex_clear(&p->pixels_lock); g_free(p->rgb); g_free(p->session); g_free(p);
}
API int kvm_portal_open(int control,int fps,void **out,char *error,int cap) {
    Portal *p; GVariantBuilder opts; GVariant *r=NULL,*streams=NULL,*props=NULL,*reply=NULL;
    GError *e=NULL; GUnixFDList *fds=NULL; int fd=-1,fd_index; const char *session=NULL;
    char token[80],target[32]; struct pw_properties *stream_props; unsigned seq=0; const char *iface=control ? RD : SC;
    uint8_t podbuf[1024]; struct spa_pod_builder b=SPA_POD_BUILDER_INIT(podbuf,sizeof(podbuf));
    const struct spa_pod *params[1]; gboolean pushed=FALSE;
    if (!out || fps<1 || fps>30) return -1;
    *out=NULL; if (error && cap>0) error[0]=0;
    p=g_new0(Portal,1); p->control=control!=0; p->fps=fps; g_mutex_init(&p->pixels_lock);
    p->context=g_main_context_new(); g_main_context_push_thread_default(p->context); pushed=TRUE;
    p->bus=g_bus_get_sync(G_BUS_TYPE_SESSION,NULL,&e);
    if (!p->bus) goto fail;
#define TOKEN() snprintf(token,sizeof(token),"lazdesk_%u_%u_%u",(unsigned)getpid(),g_random_int(),++seq)
#define OPTS() g_variant_builder_init(&opts,G_VARIANT_TYPE_VARDICT); TOKEN(); \
    g_variant_builder_add(&opts,"{sv}","handle_token",g_variant_new_string(token))
    OPTS();
    g_variant_builder_add(&opts,"{sv}","session_handle_token",g_variant_new_string(token));
    r=request(p,iface,"CreateSession",token,g_variant_new("(a{sv})",&opts),error,cap);
    if (!r || !g_variant_lookup(r,"session_handle","&s",&session)) goto fail;
    p->session=g_strdup(session); g_variant_unref(r); r=NULL;
    p->closed_subscription=g_dbus_connection_signal_subscribe(p->bus,BUS,SESSION,"Closed",
        p->session,NULL,G_DBUS_SIGNAL_FLAGS_NONE,closed_cb,p,NULL);
    if (control) {
        OPTS(); g_variant_builder_add(&opts,"{sv}","types",g_variant_new_uint32(3));
        r=request(p,RD,"SelectDevices",token,g_variant_new("(oa{sv})",p->session,&opts),error,cap);
        if (!r) goto fail;
        g_variant_unref(r); r=NULL;
    }
    /* Require embedded cursor; an unsupported mode fails visibly in the portal. */
    OPTS(); g_variant_builder_add(&opts,"{sv}","types",g_variant_new_uint32(1));
    g_variant_builder_add(&opts,"{sv}","multiple",g_variant_new_boolean(FALSE));
    g_variant_builder_add(&opts,"{sv}","cursor_mode",g_variant_new_uint32(2));
    r=request(p,SC,"SelectSources",token,g_variant_new("(oa{sv})",p->session,&opts),error,cap);
    if (!r) goto fail;
    g_variant_unref(r); r=NULL;
    OPTS();
    r=request(p,iface,"Start",token,g_variant_new("(osa{sv})",p->session,"",&opts),error,cap);
    if (!r) goto fail;
    if (control && (!g_variant_lookup(r,"devices","u",&p->devices) || (p->devices&3)!=3)) {
        error_text(error,cap,"Local user did not grant both keyboard and pointer control"); goto fail;
    }
    streams=g_variant_lookup_value(r,"streams",G_VARIANT_TYPE("a(ua{sv})"));
    if (!streams || g_variant_n_children(streams)!=1) {
        error_text(error,cap,"Portal must return exactly one selected monitor"); goto fail;
    }
    g_variant_get_child(streams,0,"(u@a{sv})",&p->node,&props);
    g_variant_lookup(props,"size","(ii)",&p->logical_w,&p->logical_h);
    g_variant_lookup(props,"pipewire-serial","t",&p->serial);
    if (control && (p->logical_w<=0 || p->logical_h<=0)) {
        error_text(error,cap,"Portal did not provide logical input dimensions"); goto fail;
    }
    g_variant_unref(props); props=NULL; g_variant_unref(streams); streams=NULL;
    g_variant_unref(r); r=NULL;
    reply=g_dbus_connection_call_with_unix_fd_list_sync(p->bus,BUS,PATH,SC,"OpenPipeWireRemote",
        g_variant_new("(o@a{sv})",p->session,empty_options()),G_VARIANT_TYPE("(h)"),
        G_DBUS_CALL_FLAGS_NONE,15000,NULL,&fds,NULL,&e);
    if (!reply || !fds) goto fail;
    g_variant_get(reply,"(h)",&fd_index); fd=g_unix_fd_list_get(fds,fd_index,&e);
    g_variant_unref(reply); reply=NULL; g_object_unref(fds); fds=NULL;
    if (fd<0) goto fail;
    pw_init(NULL,NULL); p->loop=pw_thread_loop_new("lazdesk-pipewire",NULL);
    if (!p->loop) goto fail;
    p->pwcontext=pw_context_new(pw_thread_loop_get_loop(p->loop),NULL,0);
    if (!p->pwcontext) goto fail;
    p->core=pw_context_connect_fd(p->pwcontext,fd,NULL,0); fd=-1;
    if (!p->core) goto fail;
    stream_props=pw_properties_new(PW_KEY_MEDIA_TYPE,"Video",PW_KEY_MEDIA_CATEGORY,
        "Capture",PW_KEY_MEDIA_ROLE,"Screen",NULL);
    if (!stream_props) goto fail;
    if (p->serial) {
        // Portal v6: node IDs can be reused after hotplug; prefer stable serial.
        snprintf(target,sizeof(target),"%" G_GUINT64_FORMAT,p->serial);
        if (pw_properties_set(stream_props,PW_KEY_TARGET_OBJECT,target)<0) {
            pw_properties_free(stream_props); goto fail;
        }
    }
    p->stream=pw_stream_new(p->core,"LazDesk shared desktop",stream_props);
    if (!p->stream) goto fail;
    pw_stream_add_listener(p->stream,&p->listener,&stream_events,p);
    params[0]=spa_pod_builder_add_object(&b,SPA_TYPE_OBJECT_Format,SPA_PARAM_EnumFormat,
        SPA_FORMAT_mediaType,SPA_POD_Id(SPA_MEDIA_TYPE_video),
        SPA_FORMAT_mediaSubtype,SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
        SPA_FORMAT_VIDEO_format,SPA_POD_CHOICE_ENUM_Id(4,SPA_VIDEO_FORMAT_BGRx,
            SPA_VIDEO_FORMAT_BGRA,SPA_VIDEO_FORMAT_RGBx,SPA_VIDEO_FORMAT_RGBA),
        SPA_FORMAT_VIDEO_size,SPA_POD_CHOICE_RANGE_Rectangle(
            &SPA_RECTANGLE(1920,1080),&SPA_RECTANGLE(1,1),&SPA_RECTANGLE(32768,32768)),
        SPA_FORMAT_VIDEO_framerate,SPA_POD_CHOICE_RANGE_Fraction(
            &SPA_FRACTION(fps,1),&SPA_FRACTION(0,1),&SPA_FRACTION(fps,1)));
    if (pw_stream_connect(p->stream,PW_DIRECTION_INPUT,p->serial ? PW_ID_ANY : p->node,
        PW_STREAM_FLAG_AUTOCONNECT|PW_STREAM_FLAG_MAP_BUFFERS,params,1)<0) goto fail;
    if (pw_thread_loop_start(p->loop)<0) goto fail;
    p->pw_started=TRUE;
    p->mainloop=g_main_loop_new(p->context,FALSE);
    g_main_context_pop_thread_default(p->context); pushed=FALSE;
    p->bus_thread=g_thread_new("lazdesk-portal",bus_main,p);
    *out=p; return 0;
fail:
    if (e) { error_text(error,cap,e->message); g_error_free(e); }
    else if (error && cap>0 && !error[0]) error_text(error,cap,"Portal/PipeWire initialization failed");
    if (props) g_variant_unref(props);
    if (streams) g_variant_unref(streams);
    if (r) g_variant_unref(r);
    if (reply) g_variant_unref(reply);
    if (fds) g_object_unref(fds);
    if (fd>=0) close(fd);
    if (pushed) g_main_context_pop_thread_default(p->context);
    kvm_portal_close(p); return -1;
#undef TOKEN
#undef OPTS
}
/* Read latest image scaled to requested bounds; keeps source mailbox bounded.
 * 1=image, 0=not ready, -1=revoked or failed. Size always returned on success. */
API int kvm_portal_read(void *handle,uint8_t *dst,size_t capacity,int maxw,int maxh,
    int *width,int *height,char *error,int cap) {
    Portal *p=handle; uint32_t w,h,x,y; double scale;
    if (!p || !dst || !width || !height || maxw<1 || maxh<1) return -1;
    if (g_atomic_int_get(&p->closed)) { error_text(error,cap,"Portal session revoked"); return -1; }
    g_mutex_lock(&p->pixels_lock);
    if (!p->have_frame) {
        int result=p->failure[0] ? -1 : 0;
        if (result<0) error_text(error,cap,p->failure);
        g_mutex_unlock(&p->pixels_lock); return result;
    }
    scale=1.0;
    if ((double)maxw/p->width<scale) scale=(double)maxw/p->width;
    if ((double)maxh/p->height<scale) scale=(double)maxh/p->height;
    w=(uint32_t)(p->width*scale); h=(uint32_t)(p->height*scale);
    if (!w) w=1;
    if (!h) h=1;
    if (!kvm_dimensions(w,h)) {
        error_text(error,cap,"PipeWire frame exceeds LazDesk pixel safety limit");
        g_mutex_unlock(&p->pixels_lock); return -1;
    }
    *width=(int)w; *height=(int)h;
    if ((uint64_t)w*h*3>capacity) {
        /* Request only the real output buffer, not maxw*maxh. */
        g_mutex_unlock(&p->pixels_lock); return -2;
    }
    for (y=0;y<h;y++) for (x=0;x<w;x++) {
        size_t src=((size_t)((uint64_t)y*p->height/h)*p->width+(size_t)((uint64_t)x*p->width/w))*3;
        memcpy(dst+((size_t)y*w+x)*3,p->rgb+src,3);
    }
    *width=(int)w; *height=(int)h;
    g_mutex_unlock(&p->pixels_lock); return 1;
}
API int kvm_portal_alive(void *handle) {
    Portal *p=handle; return p && !g_atomic_int_get(&p->closed);
}
API void kvm_portal_active(void *handle,int active) {
    Portal *p=handle;
    if (!p || !p->loop || !p->stream || !p->pw_started) return;
    pw_thread_loop_lock(p->loop);
    pw_stream_set_active(p->stream,active!=0);
    pw_thread_loop_unlock(p->loop);
}
static int notify(Portal *p,const char *method,GVariant *args) {
    GVariant *r;
    if (!p || !p->control || g_atomic_int_get(&p->closed)) {
        if (args) { g_variant_ref_sink(args); g_variant_unref(args); } return 0;
    }
    /* Bounded synchronous call: no infinite asynchronous input queue. */
    r=g_dbus_connection_call_sync(p->bus,BUS,PATH,RD,method,args,NULL,
        G_DBUS_CALL_FLAGS_NONE,1000,NULL,NULL);
    if (!r) return 0;
    g_variant_unref(r); return 1;
}
API int kvm_portal_pointer(void *handle,int action,int button,uint16_t nx,uint16_t ny) {
    Portal *p=handle; int ok; double x,y;
    if (!p || !p->control || action<0 || action>2 || button<0 || button>3) return 0;
    g_mutex_lock(&p->pixels_lock);
    if (!p->have_frame || !p->source_w || !p->source_h) {
        g_mutex_unlock(&p->pixels_lock);
        // Button releases remain allowed while the image is paused.
        if (action==2 && button>0) {
            int code=button==1 ? 272 : button==2 ? 273 : 274;
            return notify(p,"NotifyPointerButton",g_variant_new("(o@a{sv}iu)",p->session,
                empty_options(),code,(guint)0));
        }
        return 0;
    }
    x=(p->crop_x+(double)nx*(p->width-1)/65535.0)*p->logical_w/p->source_w;
    y=(p->crop_y+(double)ny*(p->height-1)/65535.0)*p->logical_h/p->source_h;
    if (x>p->logical_w-1) x=p->logical_w-1;
    if (y>p->logical_h-1) y=p->logical_h-1;
    g_mutex_unlock(&p->pixels_lock);
    ok=notify(p,"NotifyPointerMotionAbsolute",g_variant_new("(o@a{sv}udd)",p->session,empty_options(),
        p->node,x,y));
    if (action) {
        int code=button==1 ? 272 : button==2 ? 273 : button==3 ? 274 : -1;
        if (code<0) return 0;
        return notify(p,"NotifyPointerButton",g_variant_new("(o@a{sv}iu)",p->session,
            empty_options(),code,(guint)(action==1))) && ok;
    }
    return ok;
}
API int kvm_portal_key(void *handle,uint32_t keysym,int down) {
    Portal *p=handle;
    if (!p || !keysym || keysym>INT32_MAX) return 0;
    if (down) {
        gboolean have_frame;
        g_mutex_lock(&p->pixels_lock); have_frame=p->have_frame; g_mutex_unlock(&p->pixels_lock);
        if (!have_frame) return 0;
    }
    return notify(p,"NotifyKeyboardKeysym",g_variant_new("(o@a{sv}iu)",p->session,
        empty_options(),(gint)keysym,(guint)(down!=0)));
}
API int kvm_portal_wheel(void *handle,int steps) {
    Portal *p=handle; gboolean have_frame;
    if (!p || steps < -12 || steps > 12 || !steps) return 0;
    g_mutex_lock(&p->pixels_lock); have_frame=p->have_frame; g_mutex_unlock(&p->pixels_lock);
    if (!have_frame) return 0;
    return notify(p,"NotifyPointerAxisDiscrete",g_variant_new("(o@a{sv}ui)",p->session,
        empty_options(),(guint)0,(gint)-steps));
}

API int kvm_portal_abi(void) { return 1; }
