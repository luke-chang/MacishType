// Re-declare WebKit's private JavaScriptCore module API.
// These exist in the framework binary but are not in the public macOS SDK.
// Source: https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/API/JSScript.h
#import <JavaScriptCore/JavaScriptCore.h>

typedef NS_ENUM(int32_t, JSScriptType) {
    kJSScriptTypeProgram = 0,
    kJSScriptTypeModule = 1,
};

@interface JSScript : NSObject
+ (nullable instancetype)scriptOfType:(JSScriptType)type
                           withSource:(NSString *)source
                         andSourceURL:(NSURL *)sourceURL
                     andBytecodeCache:(nullable NSURL *)cachePath
                     inVirtualMachine:(JSVirtualMachine *)vm
                                error:(out NSError **)error;
@end

@protocol JSModuleLoaderDelegate <NSObject>
- (void)context:(JSContext *)context
       fetchModuleForIdentifier:(JSValue *)identifier
       withResolveHandler:(JSValue *)resolve
       andRejectHandler:(JSValue *)reject;
@optional
- (void)willEvaluateModule:(NSURL *)key;
- (void)didEvaluateModule:(NSURL *)key;
@end

@interface JSContext (Private)
- (JSValue *)evaluateJSScript:(JSScript *)script;
@property (nonatomic, weak, nullable) id<JSModuleLoaderDelegate> moduleLoaderDelegate;
@end

// Calls `function` with (promise, reason) when a rejection still has no
// handler once the microtask queue drains.
// Source: https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/API/JSContextRefPrivate.h
JS_EXPORT void JSGlobalContextSetUnhandledRejectionCallback(
    JSGlobalContextRef ctx, JSObjectRef function, JSValueRef *exception);

// Interrupts a synchronous JS execution slice that exceeds `limit`
// seconds: when `callback` (nullable) returns true, the slice unwinds
// with an uncatchable termination exception.
// Source: https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/API/JSContextRefPrivate.h
typedef bool (*JSShouldTerminateCallback)(JSContextRef ctx, void *context);
JS_EXPORT void JSContextGroupSetExecutionTimeLimit(
    JSContextGroupRef group, double limit,
    JSShouldTerminateCallback callback, void *context);
