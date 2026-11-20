#ifndef TOUCHTILES_TOUCH_BRIDGE_H
#define TOUCHTILES_TOUCH_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

typedef struct {
    int32_t path;
    float x;
    float y;
} DTContact;

/* count is -1 when a device disconnects. Contacts live until the callback returns.
   Return true to claim a frame on systems that support contact arbitration. */
typedef bool (*DTFrameHandler)(void *context, uintptr_t device,
                               const DTContact *contacts, int32_t count);

/* The application owns one stream. Call lifecycle functions on the main thread.
   A result of -1 means the framework is unavailable. A result of -2 means
   macOS lists a trackpad but refuses to open the contact stream. */
int DTStartContacts(DTFrameHandler handler, void *context);
int DTRefreshDevices(void);
void DTStopContacts(void);

#endif
