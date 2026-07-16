#include "include/CEventCodec.h"

CFDataRef MAHEventCreateData(CGEventRef event) {
    return CGEventCreateData(kCFAllocatorDefault, event);
}

CGEventRef MAHEventCreateFromData(CFDataRef data) {
    return CGEventCreateFromData(kCFAllocatorDefault, data);
}
