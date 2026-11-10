// LazDesk: small C ABI bridge to ScreenCaptureKit. macOS >= 12.3, ARC.
// This is original integration code, not a translation of MeshAgent.
#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

@interface KVMStream : NSObject <SCStreamOutput, SCStreamDelegate> {
@public
    NSLock *lock;
    CVPixelBufferRef latest;
    BOOL stopped;
    BOOL suspended;
    NSString *failure;
}
@property(nonatomic, strong) SCStream *stream;
@property(nonatomic, strong) dispatch_queue_t samples;
@end
@implementation KVMStream
- (instancetype)init {
    if ((self = [super init])) {
        lock = [NSLock new];
        _samples = dispatch_queue_create("lazdesk.capture", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    [lock lock]; failure = error.localizedDescription; stopped = YES;
    [lock unlock];
}
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample
       ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sample)) return;
    CFArrayRef raw = CMSampleBufferGetSampleAttachmentsArray(sample, false);
    if (!raw || CFArrayGetCount(raw) < 1) return;
    NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(raw, 0);
    NSNumber *status = info[SCStreamFrameInfoStatus];
    if (!status) return;
    if (status.integerValue != SCFrameStatusComplete) {
        if (status.integerValue == SCFrameStatusBlank || status.integerValue == SCFrameStatusSuspended ||
            status.integerValue == SCFrameStatusStopped) {
            [lock lock]; suspended=YES;
            if (latest) { CVPixelBufferRelease(latest); latest=NULL; }
            [lock unlock];
        }
        return;
    }
    CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sample);
    if (!pixels || CVPixelBufferGetPixelFormatType(pixels) != kCVPixelFormatType_32BGRA) return;
    [lock lock];
    if (!stopped) {
        CVPixelBufferRetain(pixels);
        if (latest) CVPixelBufferRelease(latest);
        suspended=NO;
        latest = pixels; // bounded mailbox: one frame, never an unbounded queue
    }
    [lock unlock];
}
- (void)dealloc { if (latest) CVPixelBufferRelease(latest); }
@end

static void copy_error(char *dst, int capacity, NSString *message) {
    if (dst && capacity > 0) {
        const char *text = message.UTF8String;
        snprintf(dst, (size_t)capacity, "%s", text ? text : "ScreenCaptureKit error");
    }
}
static void stop_stream(KVMStream *holder) {
    [holder->lock lock]; holder->stopped = YES; [holder->lock unlock];
    SCStream *stream = holder.stream;
    if (!stream) return;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    // Retain the holder until asynchronous stop completes, including on timeout.
    [stream stopCaptureWithCompletionHandler:^(NSError *error) {
        (void)holder; dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC));
    NSError *removeError = nil;
    [stream removeStreamOutput:holder type:SCStreamOutputTypeScreen error:&removeError];
    holder.stream = nil;
}
__attribute__((visibility("default")))
int kvm_sck_open(uint32_t display, int width, int height, int fps,
                 void **handle, char *error, int error_capacity) {
    @autoreleasepool {
        if (handle) *handle = NULL;
        if (!handle || width < 1 || height < 1 || width > 32768 || height > 32768 ||
            (uint64_t)width*height > 67108864 || fps < 1 || fps > 30) return -1;
        if (@available(macOS 12.3, *)) {
            __block SCShareableContent *content = nil;
            __block NSError *queryError = nil;
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                onScreenWindowsOnly:YES completionHandler:^(SCShareableContent *value, NSError *err) {
                    content = value; queryError = err; dispatch_semaphore_signal(done);
                }];
            if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 15*NSEC_PER_SEC))) {
                copy_error(error, error_capacity, @"ScreenCaptureKit enumeration timeout"); return -1;
            }
            if (!content || queryError) {
                copy_error(error, error_capacity, queryError.localizedDescription); return -1;
            }
            SCDisplay *selected = nil;
            for (SCDisplay *item in content.displays)
                if (item.displayID == display) { selected = item; break; }
            if (!selected) {
                copy_error(error, error_capacity, @"Selected display is no longer available"); return -1;
            }
            SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:selected excludingWindows:@[]];
            SCStreamConfiguration *config = [SCStreamConfiguration new];
            config.width = width; config.height = height;
            config.pixelFormat = kCVPixelFormatType_32BGRA;
            config.minimumFrameInterval = CMTimeMake(1, fps);
            config.queueDepth = 3; config.showsCursor = YES;
            KVMStream *holder = [KVMStream new];
            holder.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:holder];
            NSError *addError = nil;
            if (![holder.stream addStreamOutput:holder type:SCStreamOutputTypeScreen
                     sampleHandlerQueue:holder.samples error:&addError]) {
                copy_error(error, error_capacity, addError.localizedDescription); return -1;
            }
            __block NSError *startError = nil;
            done = dispatch_semaphore_create(0);
            [holder.stream startCaptureWithCompletionHandler:^(NSError *err) {
                startError = err; dispatch_semaphore_signal(done);
            }];
            if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 15*NSEC_PER_SEC)) || startError) {
                copy_error(error, error_capacity, startError ? startError.localizedDescription : @"Capture start timeout");
                stop_stream(holder); return -1;
            }
            *handle = (__bridge_retained void *)holder;
            return 0;
        }
        copy_error(error, error_capacity, @"ScreenCaptureKit requires macOS 12.3 or newer");
        return -1;
    }
}
// Returns 1=frame, 0=no frame yet, -1=stopped/error. RGB24 output, top-left.
__attribute__((visibility("default")))
int kvm_sck_read(void *handle, uint8_t *rgb, size_t capacity, int width, int height,
                 char *error, int error_capacity) {
    @autoreleasepool {
        if (!handle || !rgb || width < 1 || height < 1 ||
            (uint64_t)width*height*3 > capacity) return -1;
        KVMStream *holder = (__bridge KVMStream *)handle;
        [holder->lock lock];
        if (holder->stopped) {
            copy_error(error, error_capacity, holder->failure);
            [holder->lock unlock]; return -1;
        }
        if (holder->suspended) { [holder->lock unlock]; return -2; }
        CVPixelBufferRef pixels = holder->latest;
        if (pixels) CVPixelBufferRetain(pixels);
        [holder->lock unlock];
        if (!pixels) return 0;
        if (CVPixelBufferGetWidth(pixels) != (size_t)width ||
            CVPixelBufferGetHeight(pixels) != (size_t)height) {
            copy_error(error, error_capacity, @"Capture geometry changed: restart required");
            CVPixelBufferRelease(pixels); return -1;
        }
        if (CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
            CVPixelBufferRelease(pixels); return -1;
        }
        const uint8_t *base = CVPixelBufferGetBaseAddress(pixels);
        size_t stride = CVPixelBufferGetBytesPerRow(pixels);
        if (base && stride >= (size_t)width*4) {
            for (int y=0; y<height; ++y) {
                const uint8_t *src=base+(size_t)y*stride;
                uint8_t *dst=rgb+(size_t)y*width*3;
                for (int x=0; x<width; ++x) {
                    dst[0]=src[2]; dst[1]=src[1]; dst[2]=src[0]; dst+=3; src+=4;
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(pixels);
        return base && stride >= (size_t)width*4 ? 1 : -1;
    }
}
__attribute__((visibility("default")))
void kvm_sck_close(void *handle) {
    if (!handle) return;
    @autoreleasepool {
        KVMStream *holder = (__bridge_transfer KVMStream *)handle;
        stop_stream(holder);
    }
}

__attribute__((visibility("default")))
int kvm_sck_available(void *handle) {
    if (!handle) return 1; // Not opened yet; do not prevent initial capture.
    KVMStream *holder=(__bridge KVMStream *)handle;
    [holder->lock lock]; int active=holder->stopped ? 2 : !holder->suspended; // 2: let read report/recover a stopped stream
    [holder->lock unlock]; return active;
}

// Public WindowServer session keys. A suspended/blank SCStream remains an
// independent gate; no private lock-screen API or secure desktop access.
#include <unistd.h>
__attribute__((visibility("default")))
int kvm_sck_session(char *identity, int capacity) {
    if (!identity || capacity<2) return 0;
    identity[0]=0;
    CFDictionaryRef session=CGSessionCopyCurrentDictionary();
    if (!session) return 0;
    int state=0; int uid=-1;
    CFNumberRef user=CFDictionaryGetValue(session,kCGSessionUserIDKey);
    if (user && CFGetTypeID(user)==CFNumberGetTypeID() &&
        CFNumberGetValue(user,kCFNumberIntType,&uid)) {
        snprintf(identity,(size_t)capacity,"mac:%d",uid);
        CFBooleanRef console=CFDictionaryGetValue(session,kCGSessionOnConsoleKey);
        CFBooleanRef login=CFDictionaryGetValue(session,kCGSessionLoginDoneKey);
        if ((uid_t)uid!=getuid()) state=4;
        else if (console && login && CFGetTypeID(console)==CFBooleanGetTypeID() &&
                 CFGetTypeID(login)==CFBooleanGetTypeID())
            state=(CFBooleanGetValue(console) && CFBooleanGetValue(login))?1:3;
    }
    CFRelease(session); return state;
}
