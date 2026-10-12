#import "BTRProcessProbe.h"
#import "../BTRLoopbackRangeAdapter.h"
#import "../BTRJSEngine.h"
#import "BTRSelfTest.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
// Set by ios/build.ps1 (-DBTR_PROBE_REVISION=N); the only place a version number lives.
#ifndef BTR_PROBE_REVISION
#define BTR_PROBE_REVISION 0
#endif
#include <arpa/inet.h>
#include <netinet/in.h>
#include <CommonCrypto/CommonDigest.h>
#include <execinfo.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdlib.h>

// Diagnostics plus a disabled-by-default, same-item video Range experiment.
// No account/body logging, protection bypass, C hooks, or arbitrary class scan.
static NSObject *gLock;
static NSMutableArray *gEvents;
static NSMutableSet *gInstalled;
static NSMutableArray *gCoverage;
static NSMutableDictionary *gHookTargets;
static NSMutableDictionary *gEntryCounts;
static NSMutableDictionary *gFilterCounts;
static NSMutableDictionary *gSchemeCounts;
static BOOL gCountersLimited;
static BOOL gEnabled;
static NSString *gRun;
static NSTimeInterval gStart;
static NSUInteger gDropped;
static const void *BTRTicketKey = &BTRTicketKey;
static const void *BTRIJKDelegateKey = &BTRIJKDelegateKey;
static const void *BTRTransportKey = &BTRTransportKey;
static const void *BTRRegisteredKey = &BTRRegisteredKey; // Item was ever current: never re-adopt.
static __thread NSUInteger gFactoryDepth;
static BOOL gConcurrentEnabled;
static BTRLoopbackRangeAdapter *gRangeAdapter;
static id gConcurrentItem; // Strong only for the currently registered play item.
static NSDictionary *gSelfTestSource; // Last accepted video {raw, headers, alternates}: memory only, never exported.
// Per registered item: the same file (path) seen on different CDN hosts. Memory only.
static NSMutableDictionary<NSString *,NSMutableArray<NSString *> *> *gHostsByPath;
static NSDictionary *gSelfTestResult;
static BOOL gSelfTestRunning;
static BTREngine *gEngine;           // Desktop downloader for the player adapter (lazily created).
static NSString *gEngineStatus = @"not_loaded";
static BOOL gLegacyTransport;        // Menu A/B switch: YES = old per-connection downloader.
static uint64_t gConcurrentGeneration;
static uint64_t gConcurrentEpoch;
static NSMutableDictionary *gConcurrentCounts;
static void BTRRewriteCurrentItem(id item, id data);
static void BTRConcurrentCount(NSString *name);
static void BTRInvalidateCurrentItem(id item, NSString *reason);
#ifndef BTR_PROBE_TARGET_BUNDLE_ID
#define BTR_PROBE_TARGET_BUNDLE_ID @"tv.danmaku.bilianime"
#endif

static BOOL BTRAllowedProcess(void) {
    NSBundle *bundle = NSBundle.mainBundle;
    BOOL version = [[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] isEqual:@"8.89.0"];
    BOOL marked = [[bundle objectForInfoDictionaryKey:@"BTRProbeEnabled"] boolValue]
        && [[bundle objectForInfoDictionaryKey:@"BTRProbeSourceBundleIdentifier"] isEqual:@"tv.danmaku.bilianime"]
        && [[bundle objectForInfoDictionaryKey:@"BTRProbeSourceVersion"] isEqual:@"8.89.0"];
    return [bundle.bundleIdentifier isEqual:@"local.btr.transport-test"]
       || (version && ([bundle.bundleIdentifier isEqual:BTR_PROBE_TARGET_BUNDLE_ID] || marked));
}

static void BTRInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gLock = [NSObject new]; gEvents = [NSMutableArray array];
        gInstalled = [NSMutableSet set]; gCoverage = [NSMutableArray array];
        gHookTargets = [NSMutableDictionary dictionary]; gEntryCounts = [NSMutableDictionary dictionary];
        gFilterCounts = [NSMutableDictionary dictionary]; gSchemeCounts = [NSMutableDictionary dictionary];
        gConcurrentCounts = [NSMutableDictionary dictionary]; });
}
static BOOL BTRActive(void) { BTRInit(); @synchronized(gLock) { return gEnabled; } }
static void BTRCount(NSMutableDictionary *counts, NSString *key) {
    @synchronized(gLock) {
        if(!gEnabled) return;
        NSNumber *old = counts[key];
        if(!old && counts.count >= 128) { gCountersLimited = YES; return; }
        if(old.unsignedLongLongValue >= 1000000) { gCountersLimited = YES; return; }
        counts[key] = @(old.unsignedLongLongValue + 1);
    }
}
static NSString *BTRClassName(id object) {
    NSString *name = object ? NSStringFromClass(object_getClass(object)) : @"nil";
    return name.length <= 160 ? name : @"class_name_too_long";
}
static void BTREntry(NSString *source, id receiver) {
    BTRCount(gEntryCounts,source);
    // Source names are fixed probe selectors; only runtime class names are added.
    BTRCount(gEntryCounts,[NSString stringWithFormat:@"%@/class/%@",source,BTRClassName(receiver)]);
}
static void BTRFilter(NSString *source, NSString *reason) {
    BTRCount(gFilterCounts,[source stringByAppendingFormat:@"/%@",reason]);
}
static NSString *BTRSchemeCategory(NSURL *url) {
    NSString *scheme = [url isKindOfClass:NSURL.class] ? url.scheme.lowercaseString : nil;
    if(!scheme.length) return @"none";
    return [@[@"http",@"https",@"file",@"ijkhttphook",@"ijkio",@"ijkdash"] containsObject:scheme] ? scheme : @"other";
}
static NSString *BTRMediaReason(NSURL *url) {
    if(![url isKindOfClass:NSURL.class]) return @"invalid_url";
    if(![@[@"https",@"http"] containsObject:url.scheme.lowercaseString]) return @"unsupported_scheme";
    if(url.user || url.password) return @"credentials_in_url";
    NSString *host = url.host.lowercaseString ?: @"";
    NSRegularExpression *allowed = [NSRegularExpression regularExpressionWithPattern:
        @"(^|\\.)(bilivideo\\.(com|cn|net)|akamaized\\.net|szbdyd\\.com|hdslb\\.com|xycdn\\.com|mountaintoys\\.cn|nexusedgeio\\.com|ahdohpiechei\\.com)$"
        options:0 error:nil];
    if(![allowed firstMatchInString:host options:0 range:NSMakeRange(0,host.length)]) return @"unapproved_host";
    NSString *path = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].percentEncodedPath;
    NSString *ext = path.pathExtension.lowercaseString;
    if(![@[@"m4s",@"mp4",@"flv"] containsObject:ext]) return @"unsupported_extension";
    return @"accepted";
}
static NSDictionary *BTRMedia(NSURL *url) {
    if(![BTRMediaReason(url) isEqual:@"accepted"]) return nil;
    NSString *host = url.host.lowercaseString;
    NSString *path = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].percentEncodedPath;
    NSString *ext = path.pathExtension.lowercaseString;
    // A per-run path hash groups the same resource across CDN hosts. Query and
    // fragment are neither retained nor hashed. This is correlation, not proof
    // that two hosts serve identical bytes.
    NSString *run; @synchronized(gLock) { run = gRun ?: @"inactive"; }
    NSData *input = [[run stringByAppendingString:path ?: @""] dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(input.bytes,(CC_LONG)input.length,digest);
    NSMutableString *hash = [NSMutableString string];
    for(NSUInteger i=0;i<sizeof(digest);i++) [hash appendFormat:@"%02x",digest[i]];
    return @{@"scheme":url.scheme.lowercaseString,@"host":host,@"resource":hash,@"extension":ext};
}
static NSDictionary *BTRObserveURL(id raw, NSString *source) {
    NSURL *url = [raw isKindOfClass:NSURL.class] ? raw
        : ([raw isKindOfClass:NSString.class] ? [NSURL URLWithString:raw] : nil);
    NSString *reason = BTRMediaReason(url);
    BTRFilter(source,reason);
    BTRCount(gSchemeCounts,[source stringByAppendingFormat:@"/%@",BTRSchemeCategory(url)]);
    NSMutableDictionary *fields = [@{@"urlReason":reason,@"schemeCategory":BTRSchemeCategory(url)} mutableCopy];
    NSDictionary *media = BTRMedia(url); if(media) fields[@"media"] = media;
    // No raw URL, unapproved host, query, fragment or arbitrary string is emitted.
    return fields;
}
static id BTRRangeHeader(NSString *value, BOOL response) {
    if(!value.length) return [NSNull null];
    if(value.length > 100) return @"invalid";
    NSString *pattern = response ? @"^bytes [0-9]+-[0-9]+/([0-9]+|\\*)$" : @"^bytes=[0-9]*-[0-9]*$";
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
    return [regex firstMatchInString:value options:0 range:NSMakeRange(0,value.length)] ? value : @"invalid";
}
static NSArray *BTRStack(void) {
    void *addresses[24]; int count = backtrace(addresses,24); NSMutableArray *frames = [NSMutableArray array];
    for(int i=2;i<count;i++) {
        Dl_info info; if(!dladdr(addresses[i],&info)) continue;
        NSString *image = info.dli_fname ? [[NSString stringWithUTF8String:info.dli_fname] lastPathComponent] : @"unknown";
        NSString *symbol = info.dli_sname ? [NSString stringWithUTF8String:info.dli_sname] : @"unknown";
        if(symbol.length > 180) symbol = [symbol substringToIndex:180];
        [frames addObject:@{@"image":image ?: @"unknown",@"symbol":symbol ?: @"unknown",
                            @"offset":@((uintptr_t)addresses[i]-(uintptr_t)info.dli_fbase)}];
    }
    return frames;
}
static void BTRRecord(NSString *event, NSDictionary *ticket, NSDictionary *fields) {
    BTRInit(); @synchronized(gLock) {
        if(!gEnabled || (ticket && ![ticket[@"run"] isEqual:gRun])
           || (fields[@"sampleRun"] && ![fields[@"sampleRun"] isEqual:gRun])) return;
        if(gEvents.count >= 2048) { gDropped++; return; }
        NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithDictionary:fields ?: @{}];
        entry[@"event"] = event; entry[@"ms"] = @((NSProcessInfo.processInfo.systemUptime-gStart)*1000);
        if(ticket) entry[@"request"] = ticket;
        [gEvents addObject:entry];
    }
}
static NSDictionary *BTRTicket(NSURLRequest *request, NSString *source) {
    if(!BTRActive()) return nil;
    if(![request isKindOfClass:NSURLRequest.class]) { BTRFilter(source,@"invalid_request"); return nil; }
    NSDictionary *media = BTRObserveURL(request.URL,source)[@"media"]; if(!media) return nil;
    NSString *run; @synchronized(gLock) { run = gRun; }
    NSDictionary *ticket = @{@"id":NSUUID.UUID.UUIDString,@"run":run,@"source":source,
        @"media":media,@"range":BTRRangeHeader([request valueForHTTPHeaderField:@"Range"],NO)};
    BTRRecord(@"create",ticket,@{@"stack":BTRStack()}); return ticket;
}
static NSDictionary *BTRResponse(NSURLResponse *response, NSUInteger bytes, NSError *error) {
    response = [response isKindOfClass:NSURLResponse.class] ? response : nil;
    error = [error isKindOfClass:NSError.class] ? error : nil;
    NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (id)response : nil;
    NSMutableDictionary *fields = [@{@"status":@(http.statusCode),@"bytes":@(bytes),
        @"contentRange":BTRRangeHeader([http valueForHTTPHeaderField:@"Content-Range"],YES),
        @"errorCode":error ? @(error.code) : [NSNull null]} mutableCopy];
    NSDictionary *media = BTRMedia(response.URL); if(media) fields[@"responseMedia"] = media;
    // Never serialize NSError.userInfo/localizedDescription, response headers,
    // URLs, callback metrics, Cookie, Authorization, or the media body.
    return fields;
}
static BOOL BTREncoding(Method method, const char *result, NSArray<NSString *> *arguments) {
    if(!method) return NO;
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if(sig.numberOfArguments != arguments.count + 2 || strcmp(sig.methodReturnType,result)
       || strcmp([sig getArgumentTypeAtIndex:0],"@") || strcmp([sig getArgumentTypeAtIndex:1],":")) return NO;
    for(NSUInteger i=0;i<arguments.count;i++)
        if(strcmp([sig getArgumentTypeAtIndex:i+2],arguments[i].UTF8String)) return NO;
    return YES;
}
// Clang's published Apple Blocks ABI. Method @? alone does not establish the
// callback parameter ABI. With no signature or a different shape, pass through
// the original private handler without wrapping it.
struct BTRBlockLiteral { void *isa; int flags; int reserved; void *invoke; const void *descriptor; };
static BOOL BTRFourObjectCallback(id handler) {
    if(!handler) return NO;
    const struct BTRBlockLiteral *block = (__bridge const struct BTRBlockLiteral *)handler;
    if(!(block->flags & (1 << 30)) || !block->descriptor) return NO;
    const unsigned char *cursor = block->descriptor;
    cursor += 2 * sizeof(unsigned long);
    if(block->flags & (1 << 25)) cursor += 2 * sizeof(void *);
    const char *encoding = *(const char * const *)cursor;
    if(!encoding) return NO;
    @try {
        NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:encoding];
        if(strcmp(sig.methodReturnType,"v") || sig.numberOfArguments != 5
            || strcmp([sig getArgumentTypeAtIndex:0],"@?")) return NO;
        for(NSUInteger i=1;i<5;i++) if([sig getArgumentTypeAtIndex:i][0] != '@') return NO;
        return YES;
    } @catch(NSException *exception) { return NO; }
}
static void BTRCoverage(NSString *name, NSString *state, Method method) {
    @synchronized(gLock) {
        NSDictionary *row = @{@"probe":name,@"state":state,
            @"encoding":method ? [NSString stringWithUTF8String:method_getTypeEncoding(method)] : @"missing"};
        NSUInteger index = [gCoverage indexOfObjectPassingTest:^BOOL(NSDictionary *item,NSUInteger i,BOOL *stop) {
            return [item[@"probe"] isEqual:name];
        }];
        if(index != NSNotFound) gCoverage[index] = row;
        else if(gCoverage.count < 128) [gCoverage addObject:row];
    }
}
// Add an override on the exact observed runtime class. An inherited IMP is
// captured, not edited on its superclass, preserving class-cluster dispatch.
static void BTRHook(Class cls, SEL sel, const char *result, NSArray *args, IMP (^make)(IMP)) {
    if(!cls) return;
    @synchronized(gLock) {
        NSString *key = [NSString stringWithFormat:@"%@/%@",NSStringFromClass(cls),NSStringFromSelector(sel)];
        if([gInstalled containsObject:key]) return;
        Method method = class_getInstanceMethod(cls,sel);
        if(!BTREncoding(method,result,args)) { BTRCoverage(key,method ? @"signature_mismatch" : @"missing",method); return; }
        IMP replacement = make(method_getImplementation(method));
        if(!class_addMethod(cls,sel,replacement,method_getTypeEncoding(method)))
            method_setImplementation(class_getInstanceMethod(cls,sel),replacement);
        gHookTargets[key] = @{@"class":cls,@"selector":NSStringFromSelector(sel),
            @"replacement":[NSValue valueWithPointer:(const void *)replacement]};
        [gInstalled addObject:key]; BTRCoverage(key,@"installed",method);
    }
}
static void BTRCheckHooks(void) {
    @synchronized(gLock) {
        for(NSString *key in gHookTargets) {
            NSDictionary *target = gHookTargets[key];
            Class cls = target[@"class"]; SEL sel = NSSelectorFromString(target[@"selector"]);
            Method method = class_getInstanceMethod(cls,sel);
            IMP expected = (IMP)[target[@"replacement"] pointerValue];
            BTRCoverage(key,method && method_getImplementation(method) == expected ? @"installed" : @"overwritten",method);
        }
    }
}

static void BTRHookTask(NSURLSessionTask *task) {
    for(NSString *name in @[@"resume",@"cancel"]) {
        SEL selector = NSSelectorFromString(name);
        BTRHook(object_getClass(task),selector,"v",@[],^IMP(IMP old) {
            return imp_implementationWithBlock(^(NSURLSessionTask *actual) {
                BTREntry([@"task/" stringByAppendingString:name],actual);
                NSDictionary *ticket = objc_getAssociatedObject(actual,BTRTicketKey);
                if(ticket) {
                    NSMutableDictionary *fields = [@{@"taskClass":NSStringFromClass(object_getClass(actual)),@"taskIdentifier":@(actual.taskIdentifier),
                        @"currentRange":BTRRangeHeader([actual.currentRequest valueForHTTPHeaderField:@"Range"],NO)} mutableCopy];
                    NSDictionary *media = BTRMedia(actual.currentRequest.URL); if(media) fields[@"currentMedia"] = media;
                    BTRRecord(name,ticket,fields);
                }
                else BTRFilter([@"task/" stringByAppendingString:name],@"without_ticket");
                ((void(*)(id,SEL))old)(actual,selector);
            });
        });
    }
}

static void BTRHookDelegate(id delegate) {
    if(!delegate) return;
    Class cls = object_getClass(delegate);
    // Hook only already-implemented delegate methods; adding optional methods
    // would alter URLSession behavior. Do not substitute the delegate object.
    SEL responseSEL = @selector(URLSession:dataTask:didReceiveResponse:completionHandler:);
    if([delegate respondsToSelector:responseSEL]) BTRHook(cls,responseSEL,"v",@[@"@",@"@",@"@",@"@?"],^IMP(IMP old) {
        return imp_implementationWithBlock(^(id actual,NSURLSession *session,NSURLSessionDataTask *task,NSURLResponse *response,void(^handler)(NSURLSessionResponseDisposition)) {
            BTREntry(@"delegate/didReceiveResponse",actual);
            NSDictionary *ticket = objc_getAssociatedObject(task,BTRTicketKey);
            if(ticket) BTRRecord(@"response",ticket,BTRResponse(response,0,nil));
            else BTRFilter(@"delegate/didReceiveResponse",@"without_ticket");
            ((void(*)(id,SEL,id,id,id,id))old)(actual,responseSEL,session,task,response,handler);
        });
    });
    SEL completeSEL = @selector(URLSession:task:didCompleteWithError:);
    if([delegate respondsToSelector:completeSEL]) BTRHook(cls,completeSEL,"v",@[@"@",@"@",@"@"],^IMP(IMP old) {
        return imp_implementationWithBlock(^(id actual,NSURLSession *session,NSURLSessionTask *task,NSError *error) {
            BTREntry(@"delegate/didComplete",actual);
            NSDictionary *ticket = objc_getAssociatedObject(task,BTRTicketKey);
            if(ticket) BTRRecord(@"complete",ticket,BTRResponse(task.response,(NSUInteger)MAX(0,task.countOfBytesReceived),error));
            else BTRFilter(@"delegate/didComplete",@"without_ticket");
            ((void(*)(id,SEL,id,id,id))old)(actual,completeSEL,session,task,error);
        });
    });
}

static void BTRHookSession(NSURLSession *session) {
    BTRHookDelegate(session.delegate);
    for(NSString *name in @[@"dataTaskWithRequest:",@"dataTaskWithURL:",@"downloadTaskWithRequest:",@"downloadTaskWithURL:",
                            @"dataTaskWithRequest:completionHandler:",@"dataTaskWithURL:completionHandler:",
                            @"downloadTaskWithRequest:completionHandler:",@"downloadTaskWithURL:completionHandler:"]) {
        SEL sel = NSSelectorFromString(name); BOOL hasHandler = [name containsString:@"completionHandler"];
        BTRHook(object_getClass(session),sel,"@",hasHandler ? @[@"@",@"@?"] : @[@"@"],^IMP(IMP old) {
            if(!hasHandler) return imp_implementationWithBlock(^id(id actual,id input) {
                BTREntry([@"session/" stringByAppendingString:name],actual);
                BOOL outer = gFactoryDepth++ == 0;
                NSURLRequest *req = [input isKindOfClass:NSURLRequest.class] ? input : ([input isKindOfClass:NSURL.class] ? [NSURLRequest requestWithURL:input] : nil);
                NSDictionary *ticket = outer ? BTRTicket(req,name) : nil;
                id task;
                @try { task = ((id(*)(id,SEL,id))old)(actual,sel,input); }
                @finally { gFactoryDepth--; }
                if(ticket && [task isKindOfClass:NSURLSessionTask.class]) {
                    objc_setAssociatedObject(task,BTRTicketKey,ticket,OBJC_ASSOCIATION_RETAIN_NONATOMIC); BTRHookTask(task);
                }
                return task;
            });
            return imp_implementationWithBlock(^id(id actual,id input,id completion) {
                BTREntry([@"session/" stringByAppendingString:name],actual);
                BOOL outer = gFactoryDepth++ == 0;
                NSURLRequest *req = [input isKindOfClass:NSURLRequest.class] ? input : ([input isKindOfClass:NSURL.class] ? [NSURLRequest requestWithURL:input] : nil);
                NSDictionary *ticket = outer ? BTRTicket(req,name) : nil;
                __block __weak NSURLSessionTask *weakTask;
                id wrapped = completion;
                if(ticket && completion) wrapped = ^(id payload,NSURLResponse *response,NSError *error) {
                    NSUInteger bytes = [payload isKindOfClass:NSData.class] ? [payload length] : (NSUInteger)MAX(0,weakTask.countOfBytesReceived);
                    BTRRecord(@"complete",ticket,BTRResponse(response,bytes,error));
                    ((void(^)(id,id,id))completion)(payload,response,error);
                };
                id task;
                @try { task = ((id(*)(id,SEL,id,id))old)(actual,sel,input,wrapped); weakTask = task; }
                @finally { gFactoryDepth--; }
                if(ticket && [task isKindOfClass:NSURLSessionTask.class]) {
                    objc_setAssociatedObject(task,BTRTicketKey,ticket,OBJC_ASSOCIATION_RETAIN_NONATOMIC); BTRHookTask(task);
                }
                return task;
            });
        });
    }
}

// Confirmed class/selector membership in the author's 8.89.0 ARM64 sample.
// These getters describe URL-open events, not a byte-delivery replacement API.
static NSDictionary *BTRIJKOpenFields(id data) {
    Class expected = NSClassFromString(@"IJKMediaUrlOpenData");
    if(!expected || ![data isKindOfClass:expected]) { BTRFilter(@"ijk/willOpenUrl:",@"unexpected_open_data"); return nil; }
    @try {
        Class cls = object_getClass(data); SEL urlSEL = NSSelectorFromString(@"url");
        Method urlMethod = class_getInstanceMethod(cls,urlSEL);
        if(!BTREncoding(urlMethod,"@",@[])) return nil;
        id raw = ((id(*)(id,SEL))method_getImplementation(urlMethod))(data,urlSEL);
        NSDictionary *media = BTRObserveURL(raw,@"ijk/willOpenUrl:")[@"media"]; if(!media) return nil;
        NSMutableDictionary *fields = [@{@"media":media,@"rangeAvailable":@NO} mutableCopy];
        NSDictionary *getters = @{@"event":@"q",@"filesize":@"q",@"httpCode":@"i",@"httpError":@"i",
            @"retryCounter":@"i",@"segmentIndex":@"i",@"isAudio":@"i",@"isHandled":@"B",@"isUrlChanged":@"B"};
        for(NSString *name in getters) {
            SEL sel = NSSelectorFromString(name); Method method = class_getInstanceMethod(cls,sel);
            NSString *type = getters[name]; if(!BTREncoding(method,type.UTF8String,@[])) continue;
            IMP imp = method_getImplementation(method);
            NSString *key = [name isEqual:@"event"] ? @"ijkEvent" : name;
            if([type isEqual:@"q"]) fields[key] = @(((long long(*)(id,SEL))imp)(data,sel));
            else if([type isEqual:@"i"]) fields[key] = @(((int(*)(id,SEL))imp)(data,sel));
            else fields[key] = @(((BOOL(*)(id,SEL))imp)(data,sel));
        }
        return fields;
    } @catch(NSException *exception) { return nil; }
}
static NSDictionary *BTRIJKAttributes(id attributes) {
    if(![attributes isKindOfClass:NSDictionary.class]) { BTRFilter(@"ijk/invoke:attributes:",@"invalid_attributes"); return nil; }
    id raw = attributes[@"url"];
    NSDictionary *media = BTRObserveURL(raw,@"ijk/invoke:attributes:")[@"media"]; if(!media) return nil;
    NSMutableDictionary *fields = [@{@"media":media,@"rangeAvailable":@NO} mutableCopy];
    // Keys specified by IJK's public IJKMediaPlayback.h. No arbitrary headers,
    // URL, IP, fd, message text, attributes dump, or callback mutation.
    for(NSString *name in @[@"http_code",@"error",@"offset",@"file_size"]) {
        id value = attributes[name];
        NSString *decimal = [value isKindOfClass:NSNumber.class] ? [value stringValue]
            : ([value isKindOfClass:NSString.class] ? value : nil);
        if(!decimal.length || decimal.length > 20) continue;
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^-?[0-9]+$" options:0 error:nil];
        if(![regex firstMatchInString:decimal options:0 range:NSMakeRange(0,decimal.length)]) continue;
        const char *text = decimal.UTF8String; char *end = NULL; errno = 0;
        long long number = strtoll(text,&end,10);
        if(errno != ERANGE && end && !*end) fields[name] = @(number);
    }
    return fields;
}
// The media open belongs to IJKMediaPlayerItem's C item, before FFPlay attaches
// it. Capture only this item's actual public configuration; never retain Params,
// category dictionaries, raw header text, Cookie, Authorization or header values
// in diagnostics. Initialization/configuration may precede opt-in/registration.
@interface BTRPublicTransport : NSObject
@property(nonatomic, copy) NSString *userAgent;
@property(nonatomic, copy) NSString *referer;
@property(nonatomic, copy) NSDictionary *headers;
@property(nonatomic) BOOL baselineObserved;
@property(nonatomic) BOOL complete;
@property(nonatomic) BOOL userAgentValid;
@property(nonatomic) BOOL refererValid;
@property(nonatomic) BOOL headersValid;
@property(nonatomic) uint64_t generation;
@end
@implementation BTRPublicTransport
- (instancetype)init {
    if((self = [super init])) { _userAgentValid = YES; _refererValid = YES; _headersValid = YES; }
    return self;
}
@end
static BOOL BTRExactTransportItem(id item) {
    Class expected = NSClassFromString(@"BBResolverIjkPlayerItem");
    return expected && item && object_getClass(item) == expected;
}
static BOOL BTRPublicHeaderValue(id value) {
    if(![value isKindOfClass:NSString.class] || [value length] > 4096) return NO;
    for(NSUInteger i = 0; i < [value length]; i++) {
        unichar c = [value characterAtIndex:i]; if(c < 32 || c == 127) return NO;
    }
    return YES;
}
static BTRPublicTransport *BTRTransportFor(id item) {
    return item ? objc_getAssociatedObject(item,BTRTransportKey) : nil;
}
static void BTRApplyPublicOption(BTRPublicTransport *state, id value, id key) {
    if([key isEqual:@"user_agent"]) {
        state.userAgentValid = !value || BTRPublicHeaderValue(value);
        state.userAgent = state.userAgentValid ? [value copy] : nil;
    } else if([key isEqual:@"referer"]) {
        state.refererValid = !value || BTRPublicHeaderValue(value);
        state.referer = state.refererValid ? [value copy] : nil;
    } else if([key isEqual:@"headers"]) {
        NSMutableDictionary *public = [NSMutableDictionary dictionary]; BOOL valid = !value;
        if([value isKindOfClass:NSString.class] && [value length] <= 65536) {
            valid = YES;
            for(NSString *line in [value componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
                NSRange colon = [line rangeOfString:@":"]; if(colon.location == NSNotFound) continue;
                NSString *name = [[line substringToIndex:colon.location] lowercaseString];
                NSString *canonical = [name isEqual:@"user-agent"] ? @"User-Agent"
                    : ([name isEqual:@"referer"] ? @"Referer" : ([name isEqual:@"origin"] ? @"Origin" : nil));
                if(!canonical) continue;
                NSString *field = [line substringFromIndex:colon.location+1];
                while([field hasPrefix:@" "] || [field hasPrefix:@"\t"]) field = [field substringFromIndex:1];
                if(!BTRPublicHeaderValue(field) || public[canonical]) { valid = NO; break; }
                public[canonical] = field;
            }
        }
        state.headersValid = valid; state.headers = valid ? [public copy] : nil;
    }
}
static void BTRCaptureItemParams(id item, id params, BTRPublicTransport *state) {
    if(!state) return;
    Class expected = NSClassFromString(@"IJKMediaConfigParams");
    SEL uaSEL = NSSelectorFromString(@"userAgent"), refSEL = NSSelectorFromString(@"httpReferer");
    Class paramsClass = params ? object_getClass(params) : expected;
    Method uaMethod = class_getInstanceMethod(paramsClass,uaSEL);
    Method refMethod = class_getInstanceMethod(paramsClass,refSEL);
    BOOL valid = expected && (!params || [params isKindOfClass:expected])
        && BTREncoding(uaMethod,"@",@[]) && BTREncoding(refMethod,"@",@[]);
    id ua = nil, referer = nil;
    if(valid) {
        // Both exact getters are statically confirmed field loads, also called
        // by configWithParams itself. No format/item dictionary is merged.
        if(params) {
            ua = ((id(*)(id,SEL))method_getImplementation(uaMethod))(params,uaSEL);
            referer = ((id(*)(id,SEL))method_getImplementation(refMethod))(params,refSEL);
        } else {
            // The inspected configWithParams:nil branch constructs Params with
            // these exact defaults. It still requires this item's reset baseline.
            ua = @"Bilibili Freedoooooom/MarkII"; referer = @"";
        }
        valid = (!ua || BTRPublicHeaderValue(ua)) && (!referer || BTRPublicHeaderValue(referer));
    }
    @synchronized(gLock) {
        if(BTRTransportFor(item) != state) return; // C item was reset meanwhile.
        state.complete = NO;
        if(!valid || !state.baselineObserved) return;
        // Actual C config always sets user_agent; nil removes it. Referer is
        // updated only when nonempty: empty/nil must retain the previous value.
        BTRApplyPublicOption(state,ua,@"user_agent");
        if([referer length]) BTRApplyPublicOption(state,referer,@"referer");
        state.complete = YES;
    }
    BTRConcurrentCount(@"item_params_captured");
}
static NSDictionary *BTRHeadersForItem(id item, uint64_t generation, NSString *__autoreleasing *uaSource) {
    if(uaSource) *uaSource = @"unknown";
    @synchronized(gLock) {
        BTRPublicTransport *state = BTRTransportFor(item);
        if(!gConcurrentEnabled || item != gConcurrentItem || generation != gConcurrentGeneration
           || !state.complete || state.generation != generation
           || !state.userAgentValid || !state.refererValid || !state.headersValid) return nil;
        NSMutableDictionary *headers = [state.headers mutableCopy] ?: [NSMutableDictionary dictionary];
        if(!headers[@"User-Agent"]) {
            // Only a captured nil userAgent takes this embedded HTTP default.
            // The actual Params constructor normally supplies the App's UA.
            headers[@"User-Agent"] = state.userAgent ?: @"Lavf/61.7.100";
            if(uaSource) *uaSource = state.userAgent ? @"explicit_user_agent" : @"embedded_http_default";
        } else if(uaSource) *uaSource = @"header";
        if(!headers[@"Referer"] && state.referer != nil) headers[@"Referer"] = state.referer;
        return [headers copy];
    }
}
static void BTRInstallItemTransport(void) {
    Class cls = NSClassFromString(@"IJKMediaPlayerItem");
    if(!cls) { BTRCoverage(@"IJKMediaPlayerItem/item_transport",@"missing",NULL); return; }
    SEL reset = NSSelectorFromString(@"resetWithScheme:");
    BTRHook(cls,reset,"v",@[@"q"],^IMP(IMP old) {
        return imp_implementationWithBlock(^(id actual,long long scheme) {
            BTRPublicTransport *state = nil;
            if(BTRExactTransportItem(actual)) {
                state = [BTRPublicTransport new];
                @synchronized(gLock) {
                    state.generation = actual == gConcurrentItem ? gConcurrentGeneration : 0;
                    objc_setAssociatedObject(actual,BTRTransportKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
            }
            ((void(*)(id,SEL,long long))old)(actual,reset,scheme);
            if(state) @synchronized(gLock) {
                // This exact ordinary reset allocates a fresh C item/format
                // dictionary. Prior public options cannot survive that reset.
                if(BTRTransportFor(actual) == state) state.baselineObserved = YES;
            }
        });
    });
    SEL option = NSSelectorFromString(@"setOption:name:value:");
    BTRHook(cls,option,"v",@[@"i",@"@",@"@"],^IMP(IMP old) {
        return imp_implementationWithBlock(^(id actual,int category,id key,id value) {
            ((void(*)(id,SEL,int,id,id))old)(actual,option,category,key,value);
            if(category != 1 || !BTRExactTransportItem(actual) || ![key isKindOfClass:NSString.class]
               || ![@[@"user_agent",@"referer",@"headers"] containsObject:key]) return;
            @synchronized(gLock) { BTRApplyPublicOption(BTRTransportFor(actual),value,key); }
        });
    });
    SEL config = NSSelectorFromString(@"configWithParams:");
    BTRHook(cls,config,"v",@[@"@"],^IMP(IMP old) {
        return imp_implementationWithBlock(^(id actual,id params) {
            BTRPublicTransport *state;
            @synchronized(gLock) { state = BTRExactTransportItem(actual) ? BTRTransportFor(actual) : nil; }
            ((void(*)(id,SEL,id))old)(actual,config,params);
            if(state) BTRCaptureItemParams(actual,params,state);
        });
    });
}
static NSDictionary *BTRIJKLink(id delegate) {
    @synchronized(gLock) {
        NSDictionary *link = objc_getAssociatedObject(delegate,BTRIJKDelegateKey);
        return @{@"id":link[@"delegateId"] ?: @"unknown",@"roles":[link[@"roles"] copy] ?: @[]};
    }
}
static void BTRHookIJKDelegate(id delegate, NSString *role) {
    if(!delegate) return;
    @synchronized(gLock) {
        NSMutableDictionary *link = objc_getAssociatedObject(delegate,BTRIJKDelegateKey);
        if(!link) {
            link = [@{@"delegateId":NSUUID.UUID.UUIDString,@"roles":[NSMutableArray array]} mutableCopy];
            objc_setAssociatedObject(delegate,BTRIJKDelegateKey,link,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if(![link[@"roles"] containsObject:role]) [link[@"roles"] addObject:role];
    }
    SEL openSEL = NSSelectorFromString(@"willOpenUrl:");
    BTRHook(object_getClass(delegate),openSEL,"v",@[@"@"],^IMP(IMP old) {
        return imp_implementationWithBlock(^(id actual,id data) {
            BTREntry(@"ijk/willOpenUrl:",actual);
            NSDictionary *before = BTRActive() ? BTRIJKOpenFields(data) : nil;
            NSString *callId = before ? NSUUID.UUID.UUIDString : nil;
            NSString *sampleRun; @synchronized(gLock) { sampleRun = gRun; }
            if(before) {
                NSMutableDictionary *fields = [before mutableCopy]; fields[@"callId"] = callId;
                fields[@"sampleRun"] = sampleRun; fields[@"delegate"] = BTRIJKLink(actual);
                fields[@"delegateClass"] = NSStringFromClass(object_getClass(actual));
                fields[@"stack"] = BTRStack(); BTRRecord(@"ijk_open_before",nil,fields);
            }
            ((void(*)(id,SEL,id))old)(actual,openSEL,data);
            // The original resolver owns selection/wrapping. Inspect its final
            // OpenData URL and mutate only the registered current video item.
            BTRRewriteCurrentItem(actual,data);
            NSDictionary *after = before ? BTRIJKOpenFields(data) : nil;
            if(before) {
                NSMutableDictionary *fields = after ? [after mutableCopy] : [@{@"mediaNoLongerApproved":@YES} mutableCopy]; fields[@"callId"] = callId;
                fields[@"sampleRun"] = sampleRun; fields[@"delegate"] = BTRIJKLink(actual);
                BTRRecord(@"ijk_open_after",nil,fields);
            }
        });
    });
    SEL invokeSEL = NSSelectorFromString(@"invoke:attributes:");
    BTRHook(object_getClass(delegate),invokeSEL,"i",@[@"q",@"@"],^IMP(IMP old) {
        return imp_implementationWithBlock(^int(id actual,long long event,id attributes) {
            BTREntry(@"ijk/invoke:attributes:",actual);
            NSDictionary *before = BTRActive() ? BTRIJKAttributes(attributes) : nil;
            NSString *callId = before ? NSUUID.UUID.UUIDString : nil;
            NSString *sampleRun; @synchronized(gLock) { sampleRun = gRun; }
            if(before) {
                NSMutableDictionary *fields = [before mutableCopy]; fields[@"callId"] = callId;
                fields[@"sampleRun"] = sampleRun; fields[@"delegate"] = BTRIJKLink(actual);
                fields[@"ijkEvent"] = @(event); fields[@"delegateClass"] = NSStringFromClass(object_getClass(actual));
                fields[@"stack"] = BTRStack(); BTRRecord(@"ijk_invoke_before",nil,fields);
            }
            int result = ((int(*)(id,SEL,long long,id))old)(actual,invokeSEL,event,attributes);
            NSDictionary *after = before ? BTRIJKAttributes(attributes) : nil;
            if(before) {
                NSMutableDictionary *fields = after ? [after mutableCopy] : [@{@"mediaNoLongerApproved":@YES} mutableCopy]; fields[@"callId"] = callId;
                fields[@"sampleRun"] = sampleRun; fields[@"delegate"] = BTRIJKLink(actual);
                fields[@"ijkEvent"] = @(event); fields[@"returnedValue"] = @(result);
                BTRRecord(@"ijk_invoke_after",nil,fields);
            }
            return result;
        });
    });
}

static void BTRConcurrentCount(NSString *name) {
    @synchronized(gLock) {
        NSUInteger old = [gConcurrentCounts[name] unsignedIntegerValue];
        if(old < 1000000) gConcurrentCounts[name] = @(old + 1);
    }
}
static BOOL BTRConcurrentIsEnabled(void) {
    @synchronized(gLock) { return gConcurrentEnabled; }
}
static void BTRInvalidateCurrentItem(id item, NSString *reason) {
    BTRLoopbackRangeAdapter *adapter; uint64_t generation;
    id __attribute__((objc_precise_lifetime)) releasedItem;
    @synchronized(gLock) {
        if(item && item != gConcurrentItem) return;
        adapter = gRangeAdapter; generation = gConcurrentGeneration;
        releasedItem = gConcurrentItem; gConcurrentItem = nil; gConcurrentGeneration = 0;
        gConcurrentEpoch++;
    }
    // Revocation and object release may execute other code: outside state lock.
    if(generation) [adapter invalidateGeneration:generation];
    releasedItem = nil;
    BTRConcurrentCount(reason);
    BTRRecord(@"concurrent_revoke",nil,@{@"reason":reason});
}
// Desktop engine unless the menu chose legacy or it failed to load (then legacy, reported).
static void BTRApplyTransportChoice(BTRLoopbackRangeAdapter *adapter) {
    if(!adapter) return;
    BOOL legacy; BTREngine *engine;
    @synchronized(gLock) { legacy = gLegacyTransport; engine = gEngine; }
    if(!legacy && !engine) {
        NSError *error = nil;
        engine = [[BTREngine alloc] initWithTestHosts:nil error:&error];
        @synchronized(gLock) { gEngine = engine; gEngineStatus = engine.usable ? @"loaded" : (error.localizedDescription ?: @"failed"); }
        if(!engine.usable) BTRConcurrentCount(@"engine_load_failed");
    }
    if(!legacy && engine.usable) { adapter.engine = engine; [adapter useDesktopDefaults]; }
    else { adapter.engine = nil; adapter.firstWindowBytes = 512 * 1024; adapter.windowBytes = 2 * 1024 * 1024; adapter.prefetchDepth = 1; }
}
static void BTRSetConcurrentEnabled(BOOL enabled) {
    BTRInit();
    BTRLoopbackRangeAdapter *adapter;
    @synchronized(gLock) { adapter = gRangeAdapter; }
    if(enabled && !adapter) {
        NSError *error = nil;
        adapter = [[BTRLoopbackRangeAdapter alloc] initWithError:&error];
        if(!adapter) {
            BTRConcurrentCount(@"adapter_init_failed");
            BTRRecord(@"concurrent_enable_failed",nil,@{@"errorCode":@(error.code)});
            return;
        }
        @synchronized(gLock) { gRangeAdapter = adapter; }
    }
    if(enabled) BTRApplyTransportChoice(adapter);
    @synchronized(gLock) { gConcurrentEnabled = NO; }
    BTRInvalidateCurrentItem(nil,enabled ? @"enable_new_item_required" : @"disabled");
    adapter.enabled = enabled;
    @synchronized(gLock) { gConcurrentEnabled = enabled; }
    BTRRecord(@"concurrent_toggle",nil,@{@"enabled":@(enabled),@"newPlayRequired":@YES});
}
static BOOL BTRRegisterItem(id item, NSString *reason) {
    if(!BTRConcurrentIsEnabled()) return NO;
    BTRInvalidateCurrentItem(nil,reason);
    uint64_t epoch;
    @synchronized(gLock) { epoch = ++gConcurrentEpoch; }
    Class expected = NSClassFromString(@"BBResolverIjkPlayerItem");
    if(!expected || object_getClass(item) != expected) {
        BTRConcurrentCount(@"unregistered_item_class"); return NO;
    }
    // This class inherits the statically verified IJKMediaPlayerItem callback.
    BTRHookIJKDelegate(item,@"registered_controller_item");
    SEL open = NSSelectorFromString(@"willOpenUrl:");
    NSString *key = [NSString stringWithFormat:@"%@/%@",NSStringFromClass(expected),NSStringFromSelector(open)];
    IMP installed;
    @synchronized(gLock) { installed = (IMP)[gHookTargets[key][@"replacement"] pointerValue]; }
    Method method = class_getInstanceMethod(expected,open);
    if(!installed || !BTREncoding(method,"v",@[@"@"]) || method_getImplementation(method) != installed) {
        BTRConcurrentCount(@"item_hook_not_current"); return NO;
    }
    BTRLoopbackRangeAdapter *adapter;
    @synchronized(gLock) { adapter = gRangeAdapter; }
    uint64_t generation = [adapter beginGeneration];
    BOOL registered = NO;
    @synchronized(gLock) {
        if(gConcurrentEnabled && gRangeAdapter == adapter && generation && epoch == gConcurrentEpoch) {
            gConcurrentItem = item; gConcurrentGeneration = generation; registered = YES;
            BTRTransportFor(item).generation = generation;
            objc_setAssociatedObject(item,BTRRegisteredKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    if(!registered) { [adapter invalidateGeneration:generation]; return NO; }
    BTRConcurrentCount(@"items_registered");
    BTRRecord(@"concurrent_item_registered",nil,@{@"itemClass":BTRClassName(item),@"generation":@(generation),@"reason":reason});
    return YES;
}
static void BTRRegisterCurrentItem(id item) { BTRRegisterItem(item,@"new_play"); }
static void BTRRewriteCurrentItem(id item, id data) {
    BTRLoopbackRangeAdapter *adapter; uint64_t generation; BOOL adopt = NO;
    @synchronized(gLock) {
        if(!gConcurrentEnabled || !gConcurrentGeneration) return;
        if(item != gConcurrentItem) {
            // During an active session the app may replace the played item without
            // a new controller play (quality switch). Adopt each exact item once.
            Class itemClass = NSClassFromString(@"BBResolverIjkPlayerItem");
            if(!itemClass || object_getClass(item) != itemClass || objc_getAssociatedObject(item,BTRRegisteredKey)) return;
            adopt = YES;
        }
        adapter = gRangeAdapter; generation = gConcurrentGeneration;
    }
    BTRConcurrentCount(adopt ? @"adoption_candidates" : @"open_callbacks");
    Class expected = NSClassFromString(@"IJKMediaUrlOpenData");
    if(!expected || object_getClass(data) != expected) { BTRConcurrentCount(@"open_data_rejected"); return; }
    Class cls = object_getClass(data);
    SEL urlSEL = NSSelectorFromString(@"url"), eventSEL = NSSelectorFromString(@"event");
    SEL audioSEL = NSSelectorFromString(@"isAudio"), errorSEL = NSSelectorFromString(@"error");
    SEL setSEL = NSSelectorFromString(@"setUrl:");
    Method urlMethod = class_getInstanceMethod(cls,urlSEL), eventMethod = class_getInstanceMethod(cls,eventSEL);
    Method audioMethod = class_getInstanceMethod(cls,audioSEL), errorMethod = class_getInstanceMethod(cls,errorSEL);
    Method setter = class_getInstanceMethod(cls,setSEL);
    if(!BTREncoding(urlMethod,"@",@[]) || !BTREncoding(eventMethod,"q",@[])
       || !BTREncoding(audioMethod,"i",@[]) || !BTREncoding(errorMethod,"i",@[])
       || !BTREncoding(setter,"v",@[@"@"])) { BTRConcurrentCount(@"open_signature_rejected"); return; }
    @try {
        long long event = ((long long(*)(id,SEL))method_getImplementation(eventMethod))(data,eventSEL);
        int audio = ((int(*)(id,SEL))method_getImplementation(audioMethod))(data,audioSEL);
        int error = ((int(*)(id,SEL))method_getImplementation(errorMethod))(data,errorSEL);
        if(event != 0x20003 || audio != 0 || error != 0) {
            BTRConcurrentCount(event != 0x20003 ? @"other_open_event" : (audio != 0 ? @"audio_unchanged" : @"open_error_unchanged"));
            return;
        }
        id raw = ((id(*)(id,SEL))method_getImplementation(urlMethod))(data,urlSEL);
        if(![raw isKindOfClass:NSString.class] || [raw length] > 16384) {
            BTRConcurrentCount(@"open_url_rejected"); return;
        }
        NSString *prefix = @"ijkio:cache:ffio:ijkhttphook:";
        BOOL wrapped = [raw hasPrefix:prefix];
        NSString *inner = wrapped ? [raw substringFromIndex:prefix.length] : raw;
        // Unknown nested wrappers, offline sources, audio, and nonmedia URLs
        // pass through. No private DRM flag, alternate URL, or ivar is guessed.
        if(![inner hasPrefix:@"https://"] && ![inner hasPrefix:@"http://"]) {
            BTRConcurrentCount(@"unknown_wrapper_or_scheme"); return;
        }
        NSURL *source = [NSURL URLWithString:inner];
        if(![BTRMediaReason(source) isEqual:@"accepted"] || source.fragment.length) {
            BTRConcurrentCount(@"media_url_rejected"); return;
        }
        // Adopt only on an accepted video open: audio/other events never replace the item.
        if(adopt) {
            if(!BTRRegisterItem(item,@"item_adopted")) return;
            BTRConcurrentCount(@"items_adopted");
            @synchronized(gLock) { adapter = gRangeAdapter; generation = gConcurrentGeneration; }
        }
        @synchronized(gLock) {
            if(!gConcurrentEnabled || item != gConcurrentItem || generation != gConcurrentGeneration) return;
        }
        NSError *mapError = nil;
        NSString *uaSource = nil;
        NSDictionary *headers = BTRHeadersForItem(item,generation,&uaSource);
        if(!headers) { BTRConcurrentCount(@"transport_metadata_unknown"); return; }
        NSMutableArray *alternates = [NSMutableArray array];
        @synchronized(gLock) {
            if(!gHostsByPath) gHostsByPath = [NSMutableDictionary dictionary];
            NSString *key = source.path ?: @"";
            NSMutableArray *known = gHostsByPath[key];
            if(!known) { if(gHostsByPath.count >= 16) [gHostsByPath removeAllObjects]; known = gHostsByPath[key] = [NSMutableArray array]; }
            // One URL per host, newest wins (re-signed); at most 4 hosts.
            NSUInteger same = NSNotFound;
            for(NSUInteger i = 0; i < known.count; i++) if([[NSURL URLWithString:known[i]].host isEqual:source.host]) same = i;
            if(same != NSNotFound) [known replaceObjectAtIndex:same withObject:[inner copy]];
            else if(known.count < 4) [known addObject:[inner copy]];
            for(NSString *other in known) if(![[NSURL URLWithString:other].host isEqual:source.host]) [alternates addObject:other];
            if(alternates.count) BTRConcurrentCount(@"alternate_hosts_used");
            gSelfTestSource = @{@"raw":[inner copy],@"headers":headers,@"alternates":[alternates copy]};
        }
        NSString *loopback = [adapter mapVideoURL:inner generation:generation headers:headers alternates:alternates error:&mapError];
        if(!loopback) {
            BTRConcurrentCount(@"mapping_passthrough");
            BTRRecord(@"concurrent_map_passthrough",nil,@{@"generation":@(generation),@"errorCode":@(mapError.code)});
            return;
        }
        NSURL *local = [NSURL URLWithString:loopback];
        if(![local.scheme isEqual:@"http"] || ![local.host isEqual:@"127.0.0.1"]
           || local.port.unsignedIntegerValue == 0 || local.user || local.password || local.fragment.length) {
            BTRConcurrentCount(@"invalid_loopback_endpoint"); return;
        }
        @synchronized(gLock) {
            if(!gConcurrentEnabled || item != gConcurrentItem || generation != gConcurrentGeneration) return;
        }
        NSString *replacement = wrapped ? [prefix stringByAppendingString:loopback] : loopback;
        // Never hold state locks while calling a private getter/setter or IMP.
        // A concurrent item change revokes the old token, failing it closed.
        ((void(*)(id,SEL,id))method_getImplementation(setter))(data,setSEL,replacement);
        id assigned = ((id(*)(id,SEL))method_getImplementation(urlMethod))(data,urlSEL);
        if(![assigned isKindOfClass:NSString.class] || ![assigned isEqualToString:replacement]) {
            BTRConcurrentCount(@"setter_not_applied"); return;
        }
        BTRConcurrentCount(@"url_rewrites");
        BTRRecord(@"concurrent_url_rewrite",nil,@{@"generation":@(generation),@"ijkEvent":@(event),
            @"isAudio":@(audio),@"wrapperPreserved":@(wrapped),@"sourceMedia":BTRMedia(source),
            @"uaSource":uaSource ?: @"unknown",@"hasReferer":@(headers[@"Referer"] != nil),@"hasOrigin":@(headers[@"Origin"] != nil),
            @"downloadReplacementVerified":@NO});
    } @catch(NSException *exception) {
        BTRConcurrentCount(@"open_exception_passthrough");
    }
}
static void BTRInstallIJK(void) {
    BTRInstallItemTransport();
    for(NSString *className in @[@"IJKFFMoviePlayerController",@"IJKFFMoviePlayerControllerFFPlay"]) {
        Class cls = NSClassFromString(className);
        if(!cls) { BTRCoverage(className,@"missing",NULL); continue; }
        NSArray *names = [className hasSuffix:@"FFPlay"]
            ? @[@"setHttpOpenDelegate:",@"setTcpOpenDelegate:",@"setNativeInvokeDelegate:",@"setSegmentOpenDelegate:",@"setFileOpenDelegate:"]
            : @[@"setHttpOpenDelegate:",@"setTcpOpenDelegate:",@"setNativeInvokeDelegate:"];
        for(NSString *name in names) {
            SEL sel = NSSelectorFromString(name);
            BTRHook(cls,sel,"v",@[@"@"],^IMP(IMP old) {
                return imp_implementationWithBlock(^(id actual,id delegate) {
                    BTREntry([@"ijk/" stringByAppendingString:name],actual);
                    BTRHookIJKDelegate(delegate,name);
                    if(delegate) BTRRecord(@"ijk_delegate_set",nil,@{@"playerClass":NSStringFromClass(object_getClass(actual)),
                        @"selector":name,@"delegateClass":NSStringFromClass(object_getClass(delegate)),@"delegate":BTRIJKLink(delegate)});
                    // Preserve the original delegate object, ownership and setter behavior.
                    ((void(*)(id,SEL,id))old)(actual,sel,delegate);
                });
            });
        }
    }
}

static NSString *BTRSampleRun(void) {
    @synchronized(gLock) { return gEnabled ? gRun : nil; }
}
static void BTRInstallPlayerPath(void) {
    // Exact encodings in the author's 8.89 sample; static discovery is not a hit.
    Class playback = NSClassFromString(@"BBPlayerPlayback");
    SEL playItem = NSSelectorFromString(@"playWithItem:shouldSetFocus:shutdownCurrentItem:");
    if(!playback) BTRCoverage(@"BBPlayerPlayback/playWithItem:shouldSetFocus:shutdownCurrentItem:",@"missing",NULL);
    else BTRHook(playback,playItem,"v",@[@"@",@"B",@"B"],^IMP(IMP old) {
        return imp_implementationWithBlock(^(id actual,id item,BOOL focus,BOOL shutdown) {
            NSString *run = BTRSampleRun(); NSString *call = run ? NSUUID.UUID.UUIDString : nil;
            BTREntry(@"player/playWithItem",actual);
            if(run) BTRRecord(@"player_play_before",nil,@{@"sampleRun":run,@"callId":call,
                @"entry":@"BBPlayerPlayback/playWithItem:shouldSetFocus:shutdownCurrentItem:",
                @"receiverClass":BTRClassName(actual),@"itemClass":BTRClassName(item),@"stack":BTRStack()});
            ((void(*)(id,SEL,id,BOOL,BOOL))old)(actual,playItem,item,focus,shutdown);
            if(run) BTRRecord(@"player_play_after",nil,@{@"sampleRun":run,@"callId":call,
                @"receiverClass":BTRClassName(actual)});
        });
    });
    Class center = NSClassFromString(@"BFCPlayerCenter");
    SEL request = NSSelectorFromString(@"requestPlayerWithName:");
    if(!center) BTRCoverage(@"BFCPlayerCenter/requestPlayerWithName:",@"missing",NULL);
    else BTRHook(center,request,"@",@[@"@"],^IMP(IMP old) {
        return imp_implementationWithBlock(^id(id actual,id name) {
            NSString *run = BTRSampleRun(); BTREntry(@"player/requestPlayer",actual);
            NSString *label = [name isKindOfClass:NSString.class] && [@[@"ugc-ijk-io",@"cast.player"] containsObject:name] ? name : @"other";
            id returned = ((id(*)(id,SEL,id))old)(actual,request,name);
            if(run) BTRRecord(@"player_factory_return",nil,@{@"sampleRun":run,@"factory":label,
                @"receiverClass":BTRClassName(actual),@"returnedClass":BTRClassName(returned),@"stack":BTRStack()});
            return returned;
        });
    });
    Class controller = NSClassFromString(@"BFCPlayerControllerV2");
    SEL play = NSSelectorFromString(@"playWith:autoQualityEnable:autoSwitchMaxQn:autoSwitchMinQn:userQn:shutdownCurrentItem:");
    if(!controller) BTRCoverage(@"BFCPlayerControllerV2/playWith:autoQualityEnable:autoSwitchMaxQn:autoSwitchMinQn:userQn:shutdownCurrentItem:",@"missing",NULL);
    else BTRHook(controller,play,"v",@[@"@",@"B",@"q",@"q",@"q",@"B"],^IMP(IMP old) {
        return imp_implementationWithBlock(^(id actual,id item,BOOL automatic,long long maximum,long long minimum,long long quality,BOOL shutdown) {
            // The real controller starts the item inside its original play;
            // retain/register the exact argument before that first callback.
            BTRRegisterCurrentItem(item);
            NSString *run = BTRSampleRun(); NSString *call = run ? NSUUID.UUID.UUIDString : nil;
            BTREntry(@"player/controllerPlay",actual);
            if(run) BTRRecord(@"player_controller_before",nil,@{@"sampleRun":run,@"callId":call,
                @"receiverClass":BTRClassName(actual),@"itemClass":BTRClassName(item),@"stack":BTRStack()});
            ((void(*)(id,SEL,id,BOOL,long long,long long,long long,BOOL))old)(actual,play,item,automatic,maximum,minimum,quality,shutdown);
            if(run) BTRRecord(@"player_controller_after",nil,@{@"sampleRun":run,@"callId":call,
                @"receiverClass":BTRClassName(actual)});
        });
    });
    // Observe only getters called by the app. No guessed ivar or proactive read.
    for(NSString *name in @[@"currentVideoUrl",@"currentAudioUrl"]) {
        SEL sel = NSSelectorFromString(name);
        BTRHook(controller,sel,"@",@[],^IMP(IMP old) {
            return imp_implementationWithBlock(^id(id actual) {
                NSString *run = BTRSampleRun();
                NSString *source = [@"player/" stringByAppendingString:name];
                BTREntry(source,actual);
                id returned = ((id(*)(id,SEL))old)(actual,sel);
                if(run) {
                    NSMutableDictionary *fields = [BTRObserveURL(returned,source) mutableCopy];
                    fields[@"sampleRun"] = run; fields[@"getter"] = name;
                    fields[@"origin"] = @"app_getter"; fields[@"receiverClass"] = BTRClassName(actual);
                    fields[@"returnedClass"] = BTRClassName(returned);
                    BTRRecord(@"player_url",nil,fields);
                }
                return returned;
            });
        });
    }
}

static void BTRInstall(void) {
    BTRInit();
    if(!BTRAllowedProcess()) return;
    BTRInstallIJK();
    BTRInstallPlayerPath();
    SEL makeSEL = @selector(sessionWithConfiguration:delegate:delegateQueue:);
    BTRHook(object_getClass(NSURLSession.class),makeSEL,"@",@[@"@",@"@",@"@"],^IMP(IMP old) {
        return imp_implementationWithBlock(^id(id cls,id config,id delegate,id queue) {
            id session = ((id(*)(id,SEL,id,id,id))old)(cls,makeSEL,config,delegate,queue);
            BTRHookSession(session); return session;
        });
    });
    SEL simpleSEL = @selector(sessionWithConfiguration:);
    BTRHook(object_getClass(NSURLSession.class),simpleSEL,"@",@[@"@"],^IMP(IMP old) {
        return imp_implementationWithBlock(^id(id cls,id config) {
            id session = ((id(*)(id,SEL,id))old)(cls,simpleSEL,config); BTRHookSession(session); return session;
        });
    });
    SEL sharedSEL = @selector(sharedSession);
    BTRHook(object_getClass(NSURLSession.class),sharedSEL,"@",@[],^IMP(IMP old) {
        return imp_implementationWithBlock(^id(id cls) {
            id session = ((id(*)(id,SEL))old)(cls,sharedSEL); BTRHookSession(session); return session;
        });
    });
    BTRHookSession(NSURLSession.sharedSession);
    // Do not hook init methods: generic blocks do not preserve consumed self
    // and retained-return ownership. The optional AVURLAsset hint is omitted.
    // Exact declaration from TouchFriend/BiliBiliMApp NJNetworkService.xm.
    // No guessed private download classes. Q is unsigned long long on arm64.
    Class bfc = NSClassFromString(@"BFCApiRequestOperation");
    SEL bfcSEL = NSSelectorFromString(@"bfcRequest:taskType:completionHandler:");
    if(!bfc) BTRCoverage(@"BFCApiRequestOperation/bfcRequest:taskType:completionHandler:",@"missing",NULL);
    else BTRHook(bfc,bfcSEL,"@",@[@"@",@"Q",@"@?"],^IMP(IMP old) {
        return imp_implementationWithBlock(^id(id actual,NSURLRequest *request,unsigned long long type,id handler) {
            BTREntry(@"bfc/bfcRequest",actual);
            NSDictionary *ticket = BTRTicket(request,@"BFCApiRequestOperation/bfcRequest:taskType:completionHandler:");
            BOOL callbackCovered = ticket && BTRFourObjectCallback(handler);
            if(ticket) BTRRecord(@"private_call",ticket,@{@"taskType":@(type),@"receiverClass":NSStringFromClass(object_getClass(actual)),
                @"callbackCoverage":callbackCovered ? @"four_object_signature" : (handler ? @"unverified_passthrough" : @"nil")});
            id wrapped = handler;
            if(callbackCovered) wrapped = ^(NSData *data,NSURLResponse *response,NSError *error,id metrics) {
                BOOL shape = (!data || [data isKindOfClass:NSData.class])
                    && (!response || [response isKindOfClass:NSURLResponse.class])
                    && (!error || [error isKindOfClass:NSError.class]);
                if(shape) BTRRecord(@"private_complete",ticket,BTRResponse(response,data.length,error));
                else BTRRecord(@"callback_shape_mismatch",ticket,nil);
                ((void(^)(id,id,id,id))handler)(data,response,error,metrics);
            };
            id returned = ((id(*)(id,SEL,id,unsigned long long,id))old)(actual,bfcSEL,request,type,wrapped);
            if(ticket) {
                NSMutableDictionary *capabilities = [NSMutableDictionary dictionary];
                for(NSString *name in @[@"resume",@"cancel"]) {
                    SEL selector = NSSelectorFromString(name); Method m = returned ? class_getInstanceMethod(object_getClass(returned),selector) : NULL;
                    capabilities[name] = @{ @"responds":@([returned respondsToSelector:selector]),
                        @"encoding":m ? [NSString stringWithUTF8String:method_getTypeEncoding(m)] : @"missing" };
                }
                NSMutableDictionary *fields = [@{@"returnedClass":returned ? NSStringFromClass(object_getClass(returned)) : @"nil",@"selectors":capabilities} mutableCopy];
                if([returned isKindOfClass:NSURLSessionTask.class]) {
                    NSDictionary *sessionTicket = objc_getAssociatedObject(returned,BTRTicketKey);
                    if(sessionTicket) fields[@"sessionRequestId"] = sessionTicket[@"id"];
                }
                BTRRecord(@"private_return",ticket,fields);
            }
            return returned;
        });
    });
}

static NSString *BTRAppState(void) {
    if(!NSThread.isMainThread) return @"unavailable_off_main";
    switch(UIApplication.sharedApplication.applicationState) {
        case UIApplicationStateActive: return @"active";
        case UIApplicationStateInactive: return @"inactive";
        case UIApplicationStateBackground: return @"background";
    }
    return @"unknown";
}
void BTRProbeStart(void) {
    BTRInit(); if(!BTRAllowedProcess()) return;
    @synchronized(gLock) {
        [gEvents removeAllObjects]; [gEntryCounts removeAllObjects]; [gFilterCounts removeAllObjects];
        [gSchemeCounts removeAllObjects]; gCountersLimited = NO; gDropped = 0; gRun = NSUUID.UUID.UUIDString;
        gStart = NSProcessInfo.processInfo.systemUptime; gEnabled = YES;
    }
    BTRInstall(); BTRCheckHooks(); BTRRecord(@"sample_start",nil,@{@"appState":BTRAppState()});
}
void BTRProbeMarkSeek(void) { BTRRecord(@"seek_marker",nil,@{@"appState":BTRAppState()}); }
void BTRProbeStop(void) { BTRRecord(@"sample_end",nil,nil); @synchronized(gLock) { gEnabled = NO; } }
NSDictionary *BTRProbeSnapshot(void) {
    BTRInit(); BTRCheckHooks();
    BTRLoopbackRangeAdapter *adapter; NSMutableDictionary *experiment;
    @synchronized(gLock) {
        adapter = gRangeAdapter;
        NSString *uaSource = nil;
        NSDictionary *headers = gConcurrentItem ? BTRHeadersForItem(gConcurrentItem,gConcurrentGeneration,&uaSource) : nil;
        BTRPublicTransport *state = BTRTransportFor(gConcurrentItem);
        experiment = [@{@"publicMetadata":@{@"baselineObserved":@(state.baselineObserved),@"paramsComplete":@(state.complete),
                @"bindingSource":headers ? @"item_config" : @"unknown",@"observed":@(headers != nil),@"generation":@(gConcurrentGeneration),
                @"uaSource":uaSource ?: @"unknown",@"hasUserAgent":@(headers[@"User-Agent"] != nil),
                @"hasReferer":@(headers[@"Referer"] != nil),@"hasOrigin":@(headers[@"Origin"] != nil)},
            @"enabled":@(gConcurrentEnabled),@"generation":@(gConcurrentGeneration),
            @"registeredItem":@(gConcurrentItem != nil),@"counts":[gConcurrentCounts copy],
            @"engineStatus":gEngineStatus ?: @"unknown",@"legacyTransport":@(gLegacyTransport),
            @"counterScope":@"process_lifetime",@"scope":@"Registered video item HTTP-open only; ordinary BFC network replacement is excluded."} mutableCopy];
    }
    experiment[@"transport"] = adapter ? [adapter snapshot] : @{@"state":@"not_initialized",@"downloadReplacementVerified":@NO};
    @synchronized(gLock) {
        NSBundle *bundle = NSBundle.mainBundle;
        return @{@"schema":@"btr.process-probe.v1",@"probeRevision":@(BTR_PROBE_REVISION),@"run":gRun ?: @"none",
            @"mode":[bundle.bundleIdentifier isEqual:@"local.btr.transport-test"] ? @"selftest" : (BTRAllowedProcess() ? @"target_unverified" : @"blocked_process"),
            @"process":@{@"bundleId":bundle.bundleIdentifier ?: @"unknown",
                @"version":[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown",
                @"probeMarker":@([[bundle objectForInfoDictionaryKey:@"BTRProbeEnabled"] boolValue]),
                @"sourceBundleId":[bundle objectForInfoDictionaryKey:@"BTRProbeSourceBundleIdentifier"] ?: @"none",
                @"sourceVersion":[bundle objectForInfoDictionaryKey:@"BTRProbeSourceVersion"] ?: @"none",
                @"system":UIDevice.currentDevice.systemVersion},
            @"events":[gEvents copy],@"coverage":[gCoverage copy],@"dropped":@(gDropped),
            @"concurrentExperiment":experiment,@"selfTest":gSelfTestResult ?: @{@"state":@"not_run"},
            @"diagnostics":@{@"entryCounts":[gEntryCounts copy],@"filterCounts":[gFilterCounts copy],
                @"schemeCounts":[gSchemeCounts copy],@"countersLimited":@(gCountersLimited)},
            @"scope":@"Entry counts are invocations. Video URL rewrites do not prove transport success; the transport reports validated bytes actually served. No speed improvement is established."};
    }
}
static NSArray<UIWindow *> *BTRWindows(void) {
    NSMutableArray *windows = [NSMutableArray array];
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive)
            [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
    // The 8.89 target may use the pre-scene AppDelegate lifecycle.
    if(!windows.count) [windows addObjectsFromArray:UIApplication.sharedApplication.windows];
    return windows;
}
static UIViewController *BTRPresenter(void) {
    UIWindow *window = nil;
    for(UIWindow *candidate in BTRWindows()) if(candidate.isKeyWindow) window = candidate;
    UIViewController *presenter = window.rootViewController;
    while(presenter.presentedViewController) presenter = presenter.presentedViewController;
    return presenter;
}
static void BTRShareReport(UIViewController *presenter) {
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:BTRProbeSnapshot() options:NSJSONWritingPrettyPrinted error:&error];
    NSURL *file = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"BTR-probe-%@.json",NSUUID.UUID.UUIDString]]];
    if(!json || ![json writeToURL:file options:NSDataWritingAtomic error:&error]) return;
    [file setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[file] applicationActivities:nil];
    share.popoverPresentationController.sourceView = presenter.view;
    share.popoverPresentationController.sourceRect = CGRectMake(20,20,1,1);
    [presenter presentViewController:share animated:YES completion:nil];
}
// Report hand-off to the PC (ios/dev/report-receiver.mjs): Bonjour _btrreport._tcp, then the
// remembered address, then one manual entry; the share sheet stays as the last resort.
static NSString *const BTRReportEndpointKey = @"BTRReportEndpoint";
@interface BTRReportSender : NSObject <NSNetServiceBrowserDelegate, NSNetServiceDelegate>
@property(nonatomic,strong) NSNetServiceBrowser *browser;
@property(nonatomic,strong) NSMutableArray<NSNetService *> *services;
@property(nonatomic,copy) void (^found)(NSString *endpoint);
@end
@implementation BTRReportSender
- (void)discover:(void (^)(NSString *endpoint))found {
    self.found = found; self.services = [NSMutableArray array];
    self.browser = [NSNetServiceBrowser new]; self.browser.delegate = self;
    [self.browser searchForServicesOfType:@"_btrreport._tcp." inDomain:@"local."];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(6 * NSEC_PER_SEC)),dispatch_get_main_queue(), ^{ [self finish:nil]; });
}
- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didFindService:(NSNetService *)service moreComing:(BOOL)more {
    [self.services addObject:service]; service.delegate = self; [service resolveWithTimeout:5];
}
- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didNotSearch:(NSDictionary *)errors { [self finish:nil]; }
- (void)netServiceDidResolveAddress:(NSNetService *)service {
    for(NSData *address in service.addresses) {
        if(address.length < sizeof(struct sockaddr_in)) continue;
        const struct sockaddr_in *ipv4 = address.bytes;
        if(ipv4->sin_family != AF_INET) continue;
        char text[INET_ADDRSTRLEN] = {0};
        if(!inet_ntop(AF_INET,&ipv4->sin_addr,text,sizeof(text))) continue;
        [self finish:[NSString stringWithFormat:@"%s:%ld",text,(long)service.port]]; return;
    }
}
- (void)finish:(NSString *)endpoint {
    void (^found)(NSString *) = self.found;
    if(!found) return;
    self.found = nil; [self.browser stop];
    for(NSNetService *service in self.services) [service stop];
    found(endpoint);
}
@end
static BTRReportSender *gReportSender;
static void BTRPostReport(NSString *endpoint, NSData *json, NSString *name, void (^done)(BOOL ok)) {
    NSString *target = [endpoint containsString:@":"] ? endpoint : [endpoint stringByAppendingString:@":47800"];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@/report",target]];
    if(!url.host.length) { done(NO); return; }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST"; request.HTTPBody = json; request.timeoutInterval = 15;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:name forHTTPHeaderField:@"X-BTR-Name"];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        BOOL ok = !error && [response isKindOfClass:NSHTTPURLResponse.class] && ((NSHTTPURLResponse *)response).statusCode == 200;
        if(ok) [NSUserDefaults.standardUserDefaults setObject:target forKey:BTRReportEndpointKey];
        [session finishTasksAndInvalidate];
        dispatch_async(dispatch_get_main_queue(), ^{ done(ok); });
    }] resume];
}
static NSData *BTRReportJSON(NSString **name) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:BTRProbeSnapshot() options:NSJSONWritingPrettyPrinted error:nil];
    *name = [NSString stringWithFormat:@"BTR-probe-%@.json",NSUUID.UUID.UUIDString];
    return json;
}
// Main thread. done(YES) once the PC stored the report.
static void BTRSendToPC(BOOL askIfNeeded, void (^done)(BOOL ok)) {
    NSString *name = nil; NSData *json = BTRReportJSON(&name);
    if(!json) { done(NO); return; }
    void (^manual)(void) = ^{
        if(!askIfNeeded) { done(NO); return; }
        UIAlertController *ask = [UIAlertController alertControllerWithTitle:@"发送到电脑"
            message:@"没有自动找到电脑。请输入电脑接收端显示的地址（如 192.168.0.109）。" preferredStyle:UIAlertControllerStyleAlert];
        [ask addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.text = [NSUserDefaults.standardUserDefaults stringForKey:BTRReportEndpointKey];
            field.placeholder = @"192.168.0.109"; field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        }];
        [ask addAction:[UIAlertAction actionWithTitle:@"发送" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            NSString *typed = [ask.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if(!typed.length) { done(NO); return; }
            BTRPostReport(typed,json,name,done);
        }]];
        [ask addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { done(NO); }]];
        [BTRPresenter() presentViewController:ask animated:YES completion:nil];
    };
    gReportSender = [BTRReportSender new];
    [gReportSender discover:^(NSString *endpoint) {
        gReportSender = nil;
        NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:BTRReportEndpointKey];
        NSString *first = endpoint ?: saved;
        if(!first) { manual(); return; }
        BTRPostReport(first,json,name,^(BOOL ok) {
            if(ok) { done(YES); return; }
            if(endpoint && saved && ![saved isEqual:endpoint]) BTRPostReport(saved,json,name,^(BOOL again) { if(again) done(YES); else manual(); });
            else manual();
        });
    }];
}
static void BTRSendOrShare(UIViewController *presenter) {
    BTRSendToPC(YES,^(BOOL ok) {
        if(!ok) { BTRShareReport(BTRPresenter()); return; }
        UIAlertController *sent = [UIAlertController alertControllerWithTitle:@"已发送到电脑" message:nil preferredStyle:UIAlertControllerStyleAlert];
        [sent addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [BTRPresenter() presentViewController:sent animated:YES completion:nil];
    });
}
static void BTRStartSelfTest(void) {
    NSDictionary *source;
    @synchronized(gLock) { if(gSelfTestRunning) return; gSelfTestRunning = YES; source = gSelfTestSource; }
    UIViewController *presenter = BTRPresenter();
    UIAlertController *running = [UIAlertController alertControllerWithTitle:@"BTR 一键自检进行中"
        message:source ? @"约 5–7 分钟，会下载约 140MB 真实视频数据（建议 Wi-Fi）。请停留在本页面、保持亮屏。完成后自动发送到电脑。"
                       : @"约 2 分钟。未捕获到视频地址，将跳过真实 CDN 项（先开启并发实验并播放视频几秒可补上）。"
        preferredStyle:UIAlertControllerStyleAlert];
    [presenter presentViewController:running animated:YES completion:nil];
    BTRSelfTestRun(source, ^(NSDictionary *result) {
        @synchronized(gLock) { gSelfTestResult = result; gSelfTestRunning = NO; }
        NSArray *failed = result[@"failed"];
        NSString *message = [NSString stringWithFormat:@"通过 %@/%@，用时 %@ 秒%@%@",result[@"passed"],result[@"total"],result[@"seconds"],
            failed.count ? @"\n失败：\n" : @"",[failed componentsJoinedByString:@"\n"]];
        [running dismissViewControllerAnimated:YES completion:^{
          // Hand the report to the PC automatically; the buttons stay for a retry or the share sheet.
          BTRSendToPC(NO,^(BOOL sent) {
            UIViewController *top = BTRPresenter();
            UIAlertController *done = [UIAlertController alertControllerWithTitle:@"BTR 自检结果"
                message:[message stringByAppendingString:sent ? @"\n\n报告已自动发送到电脑。" : @"\n\n未能自动发送到电脑。"]
                preferredStyle:UIAlertControllerStyleAlert];
            [done addAction:[UIAlertAction actionWithTitle:sent ? @"再发送一次" : @"发送到电脑（手动输入地址）" style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *action) { BTRSendOrShare(BTRPresenter()); }]];
            [done addAction:[UIAlertAction actionWithTitle:@"分享 JSON" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                BTRShareReport(BTRPresenter());
            }]];
            [done addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
            [top presentViewController:done animated:YES completion:nil];
          });
        }];
    });
}
void BTRProbeShowMenu(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = BTRPresenter();
        if(!presenter) return;
        BOOL concurrent = BTRConcurrentIsEnabled();
        UIAlertController *menu = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"BTR诊断 v%d",BTR_PROBE_REVISION]
            message:@"并发实验默认关闭，仅尝试当前视频。开启后重新进入视频；关闭会取消本地请求，可能需重开视频恢复。请记录并导出以核对实际返回数据，尚未证明提速。" preferredStyle:UIAlertControllerStyleActionSheet];
        [menu addAction:[UIAlertAction actionWithTitle:concurrent ? @"并发下载实验：开（点击关闭）" : @"并发下载实验：关（点击开启）"
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { BTRSetConcurrentEnabled(!concurrent); }]];
        BOOL legacy; @synchronized(gLock) { legacy = gLegacyTransport; }
        [menu addAction:[UIAlertAction actionWithTitle:legacy ? @"下载引擎：旧版（点击换桌面版）" : @"下载引擎：桌面版（点击换旧版）"
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                BTRLoopbackRangeAdapter *adapter;
                @synchronized(gLock) { gLegacyTransport = !legacy; adapter = gRangeAdapter; }
                BTRApplyTransportChoice(adapter); // Applies to connections opened from now on.
            }]];
        [menu addAction:[UIAlertAction actionWithTitle:@"一键全面自检（约 5–7 分钟）" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) { BTRStartSelfTest(); }]];
        [menu addAction:[UIAlertAction actionWithTitle:@"开始记录" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { BTRProbeStart(); }]];
        [menu addAction:[UIAlertAction actionWithTitle:@"标记即将 seek" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { BTRProbeMarkSeek(); }]];
        [menu addAction:[UIAlertAction actionWithTitle:@"停止并发送到电脑" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            BTRProbeStop(); BTRSendOrShare(presenter);
        }]];
        [menu addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
        menu.popoverPresentationController.sourceView = presenter.view;
        menu.popoverPresentationController.sourceRect = CGRectMake(20,20,1,1);
        [presenter presentViewController:menu animated:YES completion:nil];
    });
}

// Opt-in UI appears in the SAME process after launch. This does not attach to
// another application or perform loading/injection itself.
@interface BTRProbeButton : UIButton
@end
@implementation BTRProbeButton
- (void)open { BTRProbeShowMenu(); }
@end
__attribute__((constructor)) static void BTRProbeLoaded(void) {
    BTRInit();
    if(!BTRAllowedProcess()) return;
    // Capture long-lived sessions constructed at startup. Logging stays off
    // until the user starts a sample; missing private classes are retried then.
    BTRInstall();
    for(NSString *name in @[UIApplicationWillResignActiveNotification,UIApplicationDidEnterBackgroundNotification,
                           UIApplicationWillEnterForegroundNotification]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *note) {
                BTREntry([@"lifecycle/" stringByAppendingString:name],UIApplication.sharedApplication);
                BTRRecord(@"app_lifecycle",nil,@{@"transition":name,@"appState":BTRAppState()});
            }];
    }
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                BTREntry(@"lifecycle/UIApplicationDidBecomeActiveNotification",UIApplication.sharedApplication);
                BTRRecord(@"app_lifecycle",nil,@{@"transition":UIApplicationDidBecomeActiveNotification,@"appState":BTRAppState()});
#if BTR_RELEASE
                // Release: acceleration is built in and always on (desktop engine, v15 settings);
                // no floating button, menu or switch.
                static dispatch_once_t enableOnce;
                dispatch_once(&enableOnce, ^{ BTRSetConcurrentEnabled(YES); });
#else
                for(UIWindow *window in BTRWindows()) {
                    if(!window.isKeyWindow || [window viewWithTag:0x425452]) continue;
                    BTRProbeButton *button = [BTRProbeButton buttonWithType:UIButtonTypeSystem];
                    button.tag = 0x425452; button.backgroundColor = UIColor.secondarySystemBackgroundColor;
                    button.layer.cornerRadius = 8; [button setTitle:@"BTR诊断" forState:UIControlStateNormal];
                    button.frame = CGRectMake(12,window.bounds.size.height-100,90,36);
                    button.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleRightMargin;
                    [button addTarget:button action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
                    [window addSubview:button];
            }
#endif
        }];
}
