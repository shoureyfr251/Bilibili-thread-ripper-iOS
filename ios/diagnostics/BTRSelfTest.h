#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// One-tap on-device scenario matrix for the loopback transport. Runs the real
// Objective-C adapter/downloader against (a) an in-process fault-injection origin
// and (b) optionally the last real video source {raw, headers} for a direct A/B.
// Private adapter instances only; never touches the player's adapter or mappings.
// Results contain numbers/labels only: no URL, header, token or body is stored.
void BTRSelfTestRun(NSDictionary * _Nullable realSource, void (^completion)(NSDictionary *result));

NS_ASSUME_NONNULL_END
