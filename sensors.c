#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include "sensors.h"
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t);

static IOHIDEventSystemClientRef client;

int read_sensors(char *names, int stride, double *vals, int max) {
  if (!client) {
    int page = 0xff00, usage = 5;  // vendor page + temperature sensor usage
    CFNumberRef p = CFNumberCreate(0, kCFNumberIntType, &page), u = CFNumberCreate(0, kCFNumberIntType, &usage);
    const void *k[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")}, *v[] = {p, u};
    CFDictionaryRef m = CFDictionaryCreate(0, k, v, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    IOHIDEventSystemClientSetMatching(client, m);
    CFRelease(m); CFRelease(p); CFRelease(u);
  }
  CFArrayRef s = IOHIDEventSystemClientCopyServices(client);
  int n = 0;
  for (CFIndex i = 0; s && i < CFArrayGetCount(s) && n < max; i++) {
    IOHIDServiceClientRef sc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(s, i);
    CFStringRef name = IOHIDServiceClientCopyProperty(sc, CFSTR("Product"));
    IOHIDEventRef e = IOHIDServiceClientCopyEvent(sc, 15, 0, 0);  // 15 = temperature event
    if (name && e) {
      CFStringGetCString(name, names + n * stride, stride, kCFStringEncodingUTF8);
      vals[n++] = IOHIDEventGetFloatValue(e, 15 << 16);
    }
    if (name) CFRelease(name);
    if (e) CFRelease(e);
  }
  if (s) CFRelease(s);
  return n;
}
