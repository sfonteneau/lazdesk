// LazDesk DXGI capture bridge, Windows 8+, desktop user session only.
// Original implementation; D3D11 desktop duplication, dirty-region GPU copies,
// deterministic COM/Map/ReleaseFrame lifetimes, and separate native cursor metadata.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <vector>
#include <new>
#include <cstdio>
#include <cstring>
#include <algorithm>
#include <memory>
#include "../common/kvm_pixels.h"
#include "../common/kvm_desktop_merge.h"
#include "../common/kvm_rgb_scale.h"
using Microsoft::WRL::ComPtr;
#ifdef KVM_STATIC_BUILD
#define API extern "C"
#else
#define API extern "C" __declspec(dllexport)
#endif
struct Capture {
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<IDXGIOutputDuplication> duplication;
    ComPtr<ID3D11Texture2D> staging;
    DXGI_OUTPUT_DESC output{};
    DXGI_OUTDUPL_DESC description{};
    std::vector<uint8_t> pixels, rgb_pixels;
    std::vector<RECT> dirty, damage;
    std::vector<DXGI_OUTDUPL_MOVE_RECT> moved;
    bool valid=false, rgb_valid=false, separate_cursor=true;
    bool rgb_changed=false, rgb_partial=false, fast_scale=false;
    bool force_separate_cursor=false;
    bool virtual_desktop=false;
    KvmDesktopRect desktop{};
    std::vector<std::unique_ptr<Capture>> outputs;
    std::vector<uint8_t> assembled;
    ULONGLONG next_layout_check=0;
    int assembled_w=0,assembled_h=0;
    int rgb_w=0,rgb_h=0;
    unsigned rgb_rotation=0;
};
static void message(char *out,int cap,const char *text,HRESULT hr=S_OK) {
    if (out && cap>0) std::snprintf(out,(size_t)cap,"%s (0x%08lx)",text,(unsigned long)hr);
}
// Never attach to Winlogon or switch to the secure desktop. Fail closed.
API int kvm_dxgi_desktop_available() {
    HDESK input=OpenInputDesktop(0,FALSE,DESKTOP_READOBJECTS);
    if (!input) return 0;
    WCHAR name[256]={},own[256]={}; DWORD n=0;
    BOOL ok=GetUserObjectInformationW(input,UOI_NAME,name,sizeof(name),&n);
    CloseDesktop(input);
    if (!ok || !GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()),UOI_NAME,own,sizeof(own),&n)) return 0;
    return _wcsicmp(name,own)==0 && _wcsicmp(name,L"Winlogon")!=0;
}
API int kvm_dxgi_abi() { return 3; }
API void kvm_dxgi_close(void *handle) { delete static_cast<Capture*>(handle); }
static int open_output(uintptr_t monitor,void **out,char *error,int cap) {
    if (!out) return -1;
    *out=nullptr;
    if (!kvm_dxgi_desktop_available()) { message(error,cap,"Interactive desktop unavailable"); return -2; }
    Capture *c=new(std::nothrow) Capture;
    if (!c) return -1;
    // GDI defaults to HALFTONE and offers a fast nearest-neighbour switch.
    // Match that user-facing choice for downscaled DXGI captures.
    char fast[4]={};
    c->fast_scale=(GetEnvironmentVariableA("LAZDESK_DXGI_FAST_SCALE",fast,sizeof(fast))==1 && fast[0]=='1');
    c->force_separate_cursor=(GetEnvironmentVariableA(
        "LAZDESK_DXGI_FORCE_SEPARATE_CURSOR",fast,sizeof(fast))==1 && fast[0]=='1');
    HRESULT hr=S_OK; bool found=false;
    ComPtr<IDXGIFactory1> factory;
    hr=CreateDXGIFactory1(IID_PPV_ARGS(&factory));
    if (FAILED(hr)) { delete c; message(error,cap,"CreateDXGIFactory1",hr); return -1; }
    HMONITOR selected=reinterpret_cast<HMONITOR>(monitor);
    if (!selected) { message(error,cap,"A physical HMONITOR is required"); delete c; return -1; }
    for (UINT ai=0; !found; ++ai) {
        ComPtr<IDXGIAdapter1> adapter;
        if (factory->EnumAdapters1(ai,&adapter)==DXGI_ERROR_NOT_FOUND) break;
        if (!adapter) break;
        for (UINT oi=0;;++oi) {
            ComPtr<IDXGIOutput> output;
            if (adapter->EnumOutputs(oi,&output)==DXGI_ERROR_NOT_FOUND) break;
            if (!output) break;
            DXGI_OUTPUT_DESC desc{};
            if (FAILED(output->GetDesc(&desc)) || !desc.AttachedToDesktop || desc.Monitor!=selected) continue;
            ComPtr<IDXGIOutput1> output1;
            hr=output.As(&output1);
            if (FAILED(hr)) break;
            hr=D3D11CreateDevice(adapter.Get(),D3D_DRIVER_TYPE_UNKNOWN,nullptr,
                D3D11_CREATE_DEVICE_BGRA_SUPPORT,nullptr,0,D3D11_SDK_VERSION,
                &c->device,nullptr,&c->context);
            if (FAILED(hr)) break;
            hr=output1->DuplicateOutput(c->device.Get(),&c->duplication);
            if (FAILED(hr)) break;
            c->output=desc; c->duplication->GetDesc(&c->description); found=true; break;
        }
    }
    if (!found) { message(error,cap,"Desktop duplication unavailable for selected monitor",hr); delete c; return -1; }
    const auto &d=c->description;
    if (!kvm_dimensions(d.ModeDesc.Width,d.ModeDesc.Height) || d.ModeDesc.Format!=DXGI_FORMAT_B8G8R8A8_UNORM) {
        message(error,cap,"Unsupported DXGI desktop dimensions/format"); delete c; return -1;
    }
    D3D11_TEXTURE2D_DESC td{};
    td.Width=d.ModeDesc.Width; td.Height=d.ModeDesc.Height; td.MipLevels=td.ArraySize=1;
    td.Format=DXGI_FORMAT_B8G8R8A8_UNORM; td.SampleDesc.Count=1;
    td.Usage=D3D11_USAGE_STAGING; td.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    hr=c->device->CreateTexture2D(&td,nullptr,&c->staging);
    if (FAILED(hr)) { message(error,cap,"Create staging texture",hr); delete c; return -1; }
    *out=c; return 0;
}
struct FrameLease {
    IDXGIOutputDuplication *d; bool held=false;
    explicit FrameLease(IDXGIOutputDuplication *p):d(p) {}
    ~FrameLease() { if (held) d->ReleaseFrame(); }
};
struct MapLease {
    ID3D11DeviceContext *ctx; ID3D11Texture2D *tex; bool held=false;
    MapLease(ID3D11DeviceContext *c,ID3D11Texture2D *t):ctx(c),tex(t) {}
    ~MapLease() { if (held) ctx->Unmap(tex,0); }
};
static bool rect_valid(const RECT &r,UINT w,UINT h) {
    return r.left>=0 && r.top>=0 && r.right>r.left && r.bottom>r.top &&
        (UINT)r.right<=w && (UINT)r.bottom<=h;
}
static bool copy_damage(Capture *c,ID3D11Texture2D *source,const DXGI_OUTDUPL_FRAME_INFO &info) {
    c->damage.clear();
    if (!c->valid || !info.TotalMetadataBufferSize || info.TotalMetadataBufferSize>8*1024*1024) return false;
    UINT bytes=0;
    // Retain capacity across frames instead of reallocating metadata vectors.
    c->dirty.resize(info.TotalMetadataBufferSize/sizeof(RECT)+1);
    c->moved.resize(info.TotalMetadataBufferSize/sizeof(DXGI_OUTDUPL_MOVE_RECT)+1);
    if (FAILED(c->duplication->GetFrameDirtyRects((UINT)(c->dirty.size()*sizeof(RECT)),c->dirty.data(),&bytes)) ||
        bytes>c->dirty.size()*sizeof(RECT) || bytes%sizeof(RECT)) return false;
    c->dirty.resize(bytes/sizeof(RECT));
    if (FAILED(c->duplication->GetFrameMoveRects((UINT)(c->moved.size()*sizeof(DXGI_OUTDUPL_MOVE_RECT)),c->moved.data(),&bytes)) ||
        bytes>c->moved.size()*sizeof(DXGI_OUTDUPL_MOVE_RECT) || bytes%sizeof(DXGI_OUTDUPL_MOVE_RECT)) return false;
    c->moved.resize(bytes/sizeof(DXGI_OUTDUPL_MOVE_RECT));
    UINT w=c->description.ModeDesc.Width,h=c->description.ModeDesc.Height;
    for (const auto &r:c->dirty) if (!rect_valid(r,w,h)) return false;
    for (const auto &m:c->moved) if (!rect_valid(m.DestinationRect,w,h)) return false;
    c->damage.reserve(c->dirty.size()+c->moved.size());
    for (const auto &m:c->moved) c->damage.push_back(m.DestinationRect);
    for (const auto &r:c->dirty) c->damage.push_back(r);
    for (const auto &r:c->damage) {
        D3D11_BOX box={(UINT)r.left,(UINT)r.top,0,(UINT)r.right,(UINT)r.bottom,1};
        // Copy CURRENT destination pixels: no ordering hazard for overlapping moves.
        c->context->CopySubresourceRegion(c->staging.Get(),0,(UINT)r.left,(UINT)r.top,0,source,0,&box);
    }
    return !c->damage.empty();
}
// -2 = desktop/access lost (caller must close/reopen), -1 = other failure.
static int read_output(void *handle,uint8_t *rgb,size_t capacity,int w,int h,char *error,int cap,bool copy_result) {
    Capture *c=static_cast<Capture*>(handle);
    if (!c || !kvm_dimensions((uint32_t)w,(uint32_t)h) ||
        (copy_result && (!rgb || (uint64_t)w*h*3>capacity))) return -1;
    if (!kvm_dxgi_desktop_available()) return -2;
    try {
        c->rgb_changed=false; c->rgb_partial=false;
        bool desktop_changed=false;
        DXGI_OUTDUPL_FRAME_INFO info{}; ComPtr<IDXGIResource> resource;
        FrameLease lease(c->duplication.Get());
        HRESULT hr=c->duplication->AcquireNextFrame(0,&info,&resource);
        if (hr==DXGI_ERROR_ACCESS_LOST || hr==DXGI_ERROR_DEVICE_REMOVED || hr==E_ACCESSDENIED) return -2;
        if (hr!=DXGI_ERROR_WAIT_TIMEOUT && FAILED(hr)) { message(error,cap,"AcquireNextFrame",hr); return -1; }
        if (SUCCEEDED(hr)) {
            lease.held=true;
            if (info.LastMouseUpdateTime.QuadPart) c->separate_cursor=info.PointerPosition.Visible!=FALSE;
            if (!c->valid || info.LastPresentTime.QuadPart) {
                ComPtr<ID3D11Texture2D> texture;
                if (FAILED(resource.As(&texture))) return -1;
                // The acquired texture is the authority for physical buffer
                // dimensions, including rotated outputs or a mode change.
                D3D11_TEXTURE2D_DESC td{}; texture->GetDesc(&td);
                if (!kvm_dimensions(td.Width,td.Height) || td.Format!=DXGI_FORMAT_B8G8R8A8_UNORM) return -1;
                if (td.Width!=c->description.ModeDesc.Width || td.Height!=c->description.ModeDesc.Height) {
                    td.Usage=D3D11_USAGE_STAGING; td.BindFlags=0;
                    td.CPUAccessFlags=D3D11_CPU_ACCESS_READ; td.MiscFlags=0;
                    ComPtr<ID3D11Texture2D> staging;
                    hr=c->device->CreateTexture2D(&td,nullptr,&staging);
                    if (FAILED(hr)) return -1;
                    c->staging=staging; c->description.ModeDesc.Width=td.Width;
                    c->description.ModeDesc.Height=td.Height; c->valid=false; c->rgb_valid=false;
                }
                if (!copy_damage(c,texture.Get(),info)) {
                    c->context->CopyResource(c->staging.Get(),texture.Get());
                    c->damage.clear();
                    c->damage.push_back(RECT{0,0,(LONG)td.Width,(LONG)td.Height});
                }
                D3D11_MAPPED_SUBRESOURCE map{};
                MapLease mapping(c->context.Get(),c->staging.Get());
                hr=c->context->Map(c->staging.Get(),0,D3D11_MAP_READ,0,&map);
                if (FAILED(hr)) { c->valid=false; c->rgb_valid=false; message(error,cap,"Map staging texture",hr); return -1; }
                mapping.held=true;
                UINT sw=c->description.ModeDesc.Width,sh=c->description.ModeDesc.Height;
                if (!map.pData || map.RowPitch<sw*4) { c->valid=false; c->rgb_valid=false; return -1; }
                c->pixels.resize((size_t)sw*sh*4);
                // The CPU copy follows the same dirty/move destinations as the
                // GPU copy, preserving untouched pixels in the retained plane.
                for (const auto &r:c->damage)
                    for (LONG y=r.top;y<r.bottom;++y)
                        std::memcpy(c->pixels.data()+((size_t)y*sw+r.left)*4,
                            static_cast<uint8_t*>(map.pData)+(size_t)y*map.RowPitch+(size_t)r.left*4,
                            (size_t)(r.right-r.left)*4);
                c->valid=true; desktop_changed=true;
            }
        }
        if (!c->valid) return 0;
        unsigned rot=0;
        switch(c->description.Rotation) {
            case DXGI_MODE_ROTATION_ROTATE90: rot=1;break;
            case DXGI_MODE_ROTATION_ROTATE180:rot=2;break;
            case DXGI_MODE_ROTATION_ROTATE270:rot=3;break;
            default:break;
        }
        UINT sw=c->description.ModeDesc.Width,sh=c->description.ModeDesc.Height;
        bool full_conversion=!c->rgb_valid || c->rgb_w!=w || c->rgb_h!=h || c->rgb_rotation!=rot;
        c->rgb_pixels.resize((size_t)w*h*3);
        if (desktop_changed && !full_conversion && !rot && (UINT)w==sw && (UINT)h==sh) {
            for (const auto &r:c->damage)
                if (!kvm_pixels_rgb_rect(c->pixels.data(),c->pixels.size(),sw*4,sw,sh,
                    (UINT)r.left,(UINT)r.top,(UINT)(r.right-r.left),(UINT)(r.bottom-r.top),
                    c->rgb_pixels.data(),c->rgb_pixels.size())) { c->rgb_valid=false; return -1; }
            c->rgb_partial=true;
        } else if (desktop_changed || full_conversion) {
            // Native resolution: exact BGRA->RGB conversion. At reduced sizes,
            // smooth bilinear filtering by default, or opt into faster nearest.
            const bool scaled=(UINT)w!=((rot&1)?sh:sw) || (UINT)h!=((rot&1)?sw:sh);
            const bool ok=(scaled && !c->fast_scale) ?
                kvm_rgb_bilinear_bgra(c->pixels.data(),c->pixels.size(),sw*4,sw,sh,rot,
                    c->rgb_pixels.data(),c->rgb_pixels.size(),(uint32_t)w,(uint32_t)h)!=0 :
                kvm_pixels_rgb(c->pixels.data(),c->pixels.size(),0,(int32_t)sw*4,
                    sw,sh,0,0,sw,sh,rot,0,c->rgb_pixels.data(),c->rgb_pixels.size(),(uint32_t)w,(uint32_t)h)!=0;
            if (!ok) { c->rgb_valid=false; return -1; }
        }
        c->rgb_changed=desktop_changed || full_conversion;
        c->rgb_valid=true; c->rgb_w=w; c->rgb_h=h; c->rgb_rotation=rot;
        // This ABI accepts any caller-owned output buffer: keep one final copy.
        // The cached RGB has NO cursor, so a timeout/cursor-only frame never
        // needs reconversion and cannot leave a trail at the old cursor position.
        if (copy_result) std::memcpy(rgb,c->rgb_pixels.data(),c->rgb_pixels.size());
        return 1;
    } catch (const std::bad_alloc &) { c->valid=false; c->rgb_valid=false; message(error,cap,"DXGI buffer allocation failed"); return -1; }
      catch (...) { c->valid=false; c->rgb_valid=false; message(error,cap,"Unexpected DXGI exception"); return -1; }
}


// Enumeration uses physical HMONITORs, including monitors on other GPU adapters.
// The virtual desktop is NOT an IDXGIOutput: open one duplication per output.
static BOOL CALLBACK collect_monitor(HMONITOR monitor,HDC,LPRECT,LPARAM user) {
    auto *monitors=reinterpret_cast<std::vector<HMONITOR>*>(user);
    if (monitors->size()>=32) return FALSE;
    monitors->push_back(monitor);
    return TRUE;
}
API int kvm_dxgi_open(uintptr_t monitor,void **out,char *error,int cap) {
    if (!out) return -1;
    *out=nullptr;
    if (monitor!=0) return open_output(monitor,out,error,cap);
    if (!kvm_dxgi_desktop_available()) {
        message(error,cap,"Interactive desktop unavailable"); return -2;
    }
    try {
    auto parent=std::unique_ptr<Capture>(new(std::nothrow) Capture);
    if (!parent) return -1;
    const int x=GetSystemMetrics(SM_XVIRTUALSCREEN);
    const int y=GetSystemMetrics(SM_YVIRTUALSCREEN);
    const int w=GetSystemMetrics(SM_CXVIRTUALSCREEN);
    const int h=GetSystemMetrics(SM_CYVIRTUALSCREEN);
    const int64_t right=(int64_t)x+w, bottom=(int64_t)y+h;
    if (w<=0 || h<=0 || !kvm_dimensions((uint32_t)w,(uint32_t)h) ||
        right>2147483647LL || bottom>2147483647LL) {
        message(error,cap,"Virtual desktop too large for capture"); return -1;
    }
    parent->virtual_desktop=true;
    parent->desktop={x,y,(int32_t)right,(int32_t)bottom};
    char forced[4]={};
    parent->force_separate_cursor=(GetEnvironmentVariableA(
        "LAZDESK_DXGI_FORCE_SEPARATE_CURSOR",forced,sizeof(forced))==1 && forced[0]=='1');
    std::vector<HMONITOR> monitors;
    if (!EnumDisplayMonitors(nullptr,nullptr,collect_monitor,
            reinterpret_cast<LPARAM>(&monitors)) ||
        monitors.empty() || monitors.size()>32) {
        message(error,cap,"Could not enumerate desktop monitors"); return -1;
    }
    for (HMONITOR monitor_id:monitors) {
        void *output=nullptr;
        if (open_output(reinterpret_cast<uintptr_t>(monitor_id),&output,error,cap)!=0)
            return -1; // strict: no silently missing monitor (auto can fall back to GDI)
        auto child=std::unique_ptr<Capture>(static_cast<Capture*>(output));
        const RECT &r=child->output.DesktopCoordinates;
        KvmDesktopRect projected{};
        if (!kvm_project_monitor(parent->desktop,{r.left,r.top,r.right,r.bottom},
                (uint32_t)w,(uint32_t)h,&projected)) {
            message(error,cap,"Invalid output geometry for desktop"); return -1;
        }
        parent->outputs.push_back(std::move(child));
    }
    *out=parent.release();
    return 0;
    } catch (const std::bad_alloc &) {
        message(error,cap,"Could not allocate DXGI monitor resources"); return -1;
    } catch (...) {
        message(error,cap,"Unexpected error while opening DXGI monitors"); return -1;
    }
}

// Detect monitor removal/rearrangement even when the outer virtual desktop
// retains exactly the same dimensions (e.g. left/right screens swapped).
static bool virtual_layout_valid(const Capture *c) {
    const int x=GetSystemMetrics(SM_XVIRTUALSCREEN);
    const int y=GetSystemMetrics(SM_YVIRTUALSCREEN);
    const int w=GetSystemMetrics(SM_CXVIRTUALSCREEN);
    const int h=GetSystemMetrics(SM_CYVIRTUALSCREEN);
    if (x!=c->desktop.left || y!=c->desktop.top ||
        (int64_t)x+w!=c->desktop.right || (int64_t)y+h!=c->desktop.bottom)
        return false;
    std::vector<HMONITOR> monitors;
    if (!EnumDisplayMonitors(nullptr,nullptr,collect_monitor,
        reinterpret_cast<LPARAM>(&monitors)) ||
        monitors.size()!=c->outputs.size()) return false;
    for (const auto &output:c->outputs) {
        const HMONITOR id=output->output.Monitor;
        if (std::find(monitors.begin(),monitors.end(),id)==monitors.end()) return false;
        MONITORINFO info{}; info.cbSize=sizeof(info);
        if (!GetMonitorInfoW(id,&info)) return false;
        const RECT &a=info.rcMonitor,&b=output->output.DesktopCoordinates;
        if (a.left!=b.left || a.top!=b.top ||
            a.right!=b.right || a.bottom!=b.bottom) return false;
    }
    return true;
}

// 1: a complete image available; 0: waiting for an initial output frame;
// -2: session lost, hotplug or GPU reset (the Pascal worker reopens all outputs).
API int kvm_dxgi_read(void *handle,uint8_t *rgb,size_t capacity,
    int w,int h,char *error,int cap) {
    Capture *c=static_cast<Capture*>(handle);
    if (!c || !rgb || !kvm_dimensions((uint32_t)w,(uint32_t)h) ||
        (uint64_t)w*h*3>capacity) return -1;
    if (!c->virtual_desktop) return read_output(c,rgb,capacity,w,h,error,cap,true);
    if (!kvm_dxgi_desktop_available()) return -2;
    try {
    const ULONGLONG now=GetTickCount64();
    if (now>=c->next_layout_check) {
        if (!virtual_layout_valid(c)) {
            message(error,cap,"Desktop monitor layout changed"); return -2;
        }
        c->next_layout_check=now+1000;
    }
        const size_t needed=(size_t)w*h*3;
        const bool resized=c->assembled_w!=w || c->assembled_h!=h ||
            c->assembled.size()!=needed;
        if (resized) {
            // Reinitialise only when geometry changes. In particular, retain
            // black pixels in gaps between physical monitor rectangles.
            c->assembled.assign(needed,0);
            c->assembled_w=w; c->assembled_h=h;
        }
        for (const auto &out:c->outputs) {
            const RECT &r=out->output.DesktopCoordinates;
            KvmDesktopRect dest{};
            if (!kvm_project_monitor(c->desktop,
                    {r.left,r.top,r.right,r.bottom},w,h,&dest)) {
                message(error,cap,"Invalid monitor layout after display change"); return -2;
            }
            const int local_w=dest.right-dest.left;
            const int local_h=dest.bottom-dest.top;
            int status=read_output(out.get(),nullptr,0,local_w,local_h,error,cap,false);
            if (status<=0) return status;
            // Unlike the first implementation, do not rebuild the entire
            // desktop when only a single output changes or the mouse moves.
            if (resized || out->rgb_changed) {
                const uint64_t monitor_area=(uint64_t)local_w*local_h;
                uint64_t dirty_area=0;
                if (!resized && out->rgb_partial && out->damage.size()<=128)
                    for (const auto &r:out->damage)
                        dirty_area+=(uint64_t)(r.right-r.left)*(r.bottom-r.top);
                const bool small_damage=dirty_area>0 && dirty_area<monitor_area/2;
                if (small_damage) {
                    // Keep both monitor caches and the assembled desktop. Only
                    // replace changed scanlines, never re-copy a 1080p screen
                    // for a small text caret or window animation.
                    for (const auto &r:out->damage)
                        if (!kvm_merge_rgb24_damage(c->assembled.data(),c->assembled.size(),w,h,
                                dest,out->rgb_pixels.data(),out->rgb_pixels.size(),
                                {r.left,r.top,r.right,r.bottom})) {
                            message(error,cap,"Could not merge DXGI damage"); return -1;
                        }
                } else if (!kvm_merge_rgb24(c->assembled.data(),c->assembled.size(),w,h,dest,
                        out->rgb_pixels.data(),out->rgb_pixels.size())) {
                    message(error,cap,"Could not merge DXGI output"); return -1;
                }
            }
        }
        std::memcpy(rgb,c->assembled.data(),needed);
        return 1;
    } catch (const std::bad_alloc &) {
        message(error,cap,"DXGI virtual desktop buffer allocation failed"); return -1;
    } catch (...) {
        message(error,cap,"Unexpected DXGI virtual desktop exception"); return -1;
    }
}

// The Pascal Windows cursor publisher (same implementation as GDI) sends the
// cursor separately unless the driver already included it in the frame.
// Per-output PointerPosition.Visible is true for a SEPARATE DXGI pointer.
API int kvm_dxgi_cursor_embedded(void *handle) {
    Capture *c=static_cast<Capture*>(handle);
    if (!c || c->force_separate_cursor) return 0;
    CURSORINFO ci{}; ci.cbSize=sizeof(ci);
    if (!GetCursorInfo(&ci) || !(ci.flags & CURSOR_SHOWING)) return 0;
    auto inside=[](const Capture *o,const POINT &p) {
        const RECT &r=o->output.DesktopCoordinates;
        return p.x>=r.left && p.x<r.right && p.y>=r.top && p.y<r.bottom;
    };
    if (!c->virtual_desktop)
        return inside(c,ci.ptScreenPos) && !c->separate_cursor;
    for (const auto &output:c->outputs)
        if (inside(output.get(),ci.ptScreenPos))
            return !output->separate_cursor;
    return 0;
}
