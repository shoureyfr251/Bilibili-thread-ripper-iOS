#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Call in the process whose player is being studied. The standalone host only
// self-tests instrumentation; iOS sandboxing prevents cross-App observation.
FOUNDATION_EXPORT void BTRProbeStart(void);
FOUNDATION_EXPORT void BTRProbeMarkSeek(void);
FOUNDATION_EXPORT NSDictionary *BTRProbeSnapshot(void);
FOUNDATION_EXPORT void BTRProbeStop(void);
FOUNDATION_EXPORT void BTRProbeShowMenu(void);
NS_ASSUME_NONNULL_END
