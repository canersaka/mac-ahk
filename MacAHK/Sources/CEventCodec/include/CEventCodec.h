#ifndef CEVENTCODEC_H
#define CEVENTCODEC_H

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>

// Thin wrappers around CGEventCreateData/CGEventCreateFromData so Swift
// gets stable names and correct ownership annotations. These let us
// serialize any CGEvent (including trackpad gesture events) to bytes and
// reconstruct it later for byte-identical replay.

CF_RETURNS_RETAINED
CFDataRef _Nullable MAHEventCreateData(CGEventRef _Nonnull event);

CF_RETURNS_RETAINED
CGEventRef _Nullable MAHEventCreateFromData(CFDataRef _Nonnull data);

#endif
