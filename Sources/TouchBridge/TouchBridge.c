#include "TouchBridge.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stddef.h>

/* Only these fields of Apple's 96-byte MTContact are needed. The framework
   calls this function concurrently and recycles the contact storage on return. */
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t path, state, finger, hand;
    float x, y;
    unsigned char unused[56];
} MTContact;
_Static_assert(sizeof(MTContact) == 96, "Unexpected multitouch contact stride");
_Static_assert(offsetof(MTContact, x) == 32, "Unexpected position offset");

typedef int32_t (*MTCallback)(CFTypeRef, const MTContact *, int32_t, double, int32_t);
static struct {
    CFArrayRef (*list)(void);
    void (*attach)(CFTypeRef, MTCallback);
    void (*detach)(CFTypeRef, MTCallback);
    int32_t (*start)(CFTypeRef, int32_t);
    int32_t (*stop)(CFTypeRef);
    int32_t (*family)(CFTypeRef, int32_t *);
    int32_t (*device_id)(CFTypeRef, uint64_t *);
    bool (*running)(CFTypeRef);
} api;

static bool load_framework(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *path = "/System/Library/PrivateFrameworks/"
                           "MultitouchSupport.framework/MultitouchSupport";
        void *library = dlopen(path, RTLD_LAZY | RTLD_LOCAL);
        if (!library) return;
        api.list = dlsym(library, "MTDeviceCreateList");
        api.attach = dlsym(library, "MTRegisterContactFrameCallback");
        api.detach = dlsym(library, "MTUnregisterContactFrameCallback");
        api.start = dlsym(library, "MTDeviceStart");
        api.stop = dlsym(library, "MTDeviceStop");
        api.family = dlsym(library, "MTDeviceGetFamilyID");
        api.device_id = dlsym(library, "MTDeviceGetDeviceID");
        api.running = dlsym(library, "MTDeviceIsRunning");
    });
    return api.list && api.attach && api.detach && api.start && api.stop
        && api.family && api.device_id && api.running;
}

static pthread_mutex_t callback_lock = PTHREAD_MUTEX_INITIALIZER;
static DTFrameHandler frame_handler;
static void *handler_context;
static CFMutableDictionaryRef devices; /* ID -> MTDevice, owned by main thread. */

static int32_t receive_frame(CFTypeRef device, const MTContact *touches,
                             int32_t count, double timestamp, int32_t frame)
{
    (void)timestamp;
    (void)frame;
    if (count < 0 || count > 32 || (count && !touches)) return 0;
    DTContact contacts[32];
    int32_t active = 0;
    for (int32_t i = 0; i < count; i++) {
        const MTContact *touch = &touches[i];
        if (touch->state != 3 && touch->state != 4) continue;
        if (!isfinite(touch->x) || !isfinite(touch->y)
            || touch->x < 0 || touch->x > 1 || touch->y < 0 || touch->y > 1) return 0;
        contacts[active++] = (DTContact){touch->path, touch->x, touch->y};
    }
    pthread_mutex_lock(&callback_lock);
    bool claimed = frame_handler && frame_handler(handler_context, (uintptr_t)device,
                                                  contacts, active);
    pthread_mutex_unlock(&callback_lock);
    return claimed ? 1 : 0;
}

static bool is_trackpad(CFTypeRef device)
{
    int32_t family;
    if (api.family(device, &family) != 0) return false;
    /* 0x6x is a MacBook trackpad, 0x8x a Magic Trackpad. Apple also lists Magic
       Mouse and Touch Bar here. Neither should send contacts to the recognizer. */
    return (family >> 4) == 6 || (family >> 4) == 8;
}

static void detach_device(const void *key, const void *value, void *context)
{
    api.detach(value, receive_frame);
    api.stop(value);
    pthread_mutex_lock(&callback_lock);
    if (frame_handler) frame_handler(handler_context, (uintptr_t)value, NULL, -1);
    pthread_mutex_unlock(&callback_lock);
    if (context) CFDictionaryRemoveValue((CFMutableDictionaryRef)context, key);
}

int DTRefreshDevices(void)
{
    if (!devices) return -1;
    CFArrayRef found = api.list();
    CFMutableDictionaryRef removed = CFDictionaryCreateMutableCopy(NULL, 0, devices);
    CFIndex count = found ? CFArrayGetCount(found) : 0;
    bool open_failed = false;
    for (CFIndex i = 0; i < count; i++) {
        CFTypeRef device = CFArrayGetValueAtIndex(found, i);
        uint64_t id;
        if (!is_trackpad(device) || api.device_id(device, &id) != 0) continue;
        CFNumberRef key = CFNumberCreate(NULL, kCFNumberSInt64Type, &id);
        CFTypeRef old = CFDictionaryGetValue(devices, key);
        if (old && api.running(old)) {
            CFDictionaryRemoveValue(removed, key);
        } else {
            if (old) {
                detach_device(key, old, NULL);
                CFDictionaryRemoveValue(devices, key);
                CFDictionaryRemoveValue(removed, key);
            }
            api.attach(device, receive_frame);
            api.start(device, 0);
            if (api.running(device)) CFDictionarySetValue(devices, key, device);
            else {
                open_failed = true;
                api.detach(device, receive_frame);
            }
        }
        CFRelease(key);
    }
    if (found) CFRelease(found);
    CFDictionaryApplyFunction(removed, detach_device, devices);
    CFRelease(removed);
    int opened = (int)CFDictionaryGetCount(devices);
    return opened == 0 && open_failed ? -2 : opened;
}

int DTStartContacts(DTFrameHandler handler, void *context)
{
    if (devices || !load_framework()) return -1;
    devices = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                         &kCFTypeDictionaryValueCallBacks);
    pthread_mutex_lock(&callback_lock);
    frame_handler = handler;
    handler_context = context;
    pthread_mutex_unlock(&callback_lock);
    return DTRefreshDevices();
}

void DTStopContacts(void)
{
    pthread_mutex_lock(&callback_lock);
    frame_handler = NULL;
    handler_context = NULL;
    pthread_mutex_unlock(&callback_lock);
    if (devices) {
        CFDictionaryApplyFunction(devices, detach_device, NULL);
        CFRelease(devices);
        devices = NULL;
    }
}
