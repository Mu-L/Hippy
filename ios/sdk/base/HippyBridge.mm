/*!
 * iOS SDK
 *
 * Tencent is pleased to support the open source community by making
 * Hippy available.
 *
 * Copyright (C) 2019 THL A29 Limited, a Tencent company.
 * All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "HippyBridge.h"
#import "HippyBridge+Private.h"

#import <objc/runtime.h>

#import "HippyConvert.h"
#import "HippyEventDispatcher.h"
#import "HippyKeyCommands.h"
#import "HippyLog.h"
#import "HippyModuleData.h"
#import "HippyPerformanceLogger.h"
#import "HippyUtils.h"
#import "HippyUIManager.h"
#import "HippyExtAnimationModule.h"
#import "HippyRedBox.h"
#import "HippyTurboModule.h"

NSString *const HippyReloadNotification = @"HippyReloadNotification";
NSString *const HippyJavaScriptWillStartLoadingNotification = @"HippyJavaScriptWillStartLoadingNotification";
NSString *const HippyJavaScriptDidLoadNotification = @"HippyJavaScriptDidLoadNotification";
NSString *const HippyJavaScriptDidFailToLoadNotification = @"HippyJavaScriptDidFailToLoadNotification";
NSString *const HippyDidInitializeModuleNotification = @"HippyDidInitializeModuleNotification";
NSString *const HippyBusinessDidLoadNotification = @"HippyBusinessDidLoadNotification";
NSString *const _HippySDKVersion = @"unspecified";

static NSMutableArray<Class> *HippyModuleClasses;
NSArray<Class> *HippyGetModuleClasses(void) {
    return HippyModuleClasses;
}

/**
 * Register the given class as a bridge module. All modules must be registered
 * prior to the first bridge initialization.
 */

HIPPY_EXTERN void HippyRegisterModule(Class);
void HippyRegisterModule(Class moduleClass) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        HippyModuleClasses = [NSMutableArray new];
    });

    HippyAssert([moduleClass conformsToProtocol:@protocol(HippyBridgeModule)], @"%@ does not conform to the HippyBridgeModule protocol", moduleClass);

    // Register module
    [HippyModuleClasses addObject:moduleClass];
}

/**
 * This function returns the module name for a given class.
 */
NSString *HippyBridgeModuleNameForClass(Class cls) {
#if HIPPY_DEBUG
    HippyAssert([cls conformsToProtocol:@protocol(HippyBridgeModule)] || [cls conformsToProtocol:@protocol(HippyTurboModule)],
                @"Bridge module `%@` does not conform to HippyBridgeModule or HippyTurboModule", cls);
#endif
    NSString *name = nil;
    // The two protocols(HippyBridgeModule and HippyTurboModule)  should be mutually exclusive.
    if ([cls conformsToProtocol:@protocol(HippyBridgeModule)]) {
        name = [cls moduleName];
    } else if ([cls conformsToProtocol:@protocol(HippyTurboModule)]) {
        name = [cls turoboModuleName];
    }
    if (name.length == 0) {
        name = NSStringFromClass(cls);
    }
    if ([name hasPrefix:@"Hippy"] || [name hasPrefix:@"hippy"]) {
        // an exception,QB uses it
        if ([name isEqualToString:@"HippyIFrame"]) {
        } else {
            name = [name substringFromIndex:5];
        }
    }

    return name;
}

#if HIPPY_DEBUG
void HippyVerifyAllModulesExported(NSArray *extraModules) {
    // Check for unexported modules
    unsigned int classCount;
    Class *classes = objc_copyClassList(&classCount);

    NSMutableSet *moduleClasses = [NSMutableSet new];
    [moduleClasses addObjectsFromArray:HippyGetModuleClasses()];
    [moduleClasses addObjectsFromArray:[extraModules valueForKeyPath:@"class"]];

    for (unsigned int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        Class superclass = cls;
        while (superclass) {
            if (class_conformsToProtocol(superclass, @protocol(HippyBridgeModule))) {
                if ([moduleClasses containsObject:cls]) {
                    break;
                }

                // Verify it's not a super-class of one of our moduleClasses
                BOOL isModuleSuperClass = NO;
                for (Class moduleClass in moduleClasses) {
                    if ([moduleClass isSubclassOfClass:cls]) {
                        isModuleSuperClass = YES;
                        break;
                    }
                }
                if (isModuleSuperClass) {
                    break;
                }

                HippyLogWarn(@"Class %@ was not exported. Did you forget to use HIPPY_EXPORT_MODULE()?", cls);
                break;
            }
            superclass = class_getSuperclass(superclass);
        }
    }

    free(classes);
}
#endif

@implementation HippyBridge {
    NSURL *_delegateBundleURL;
    id<HippyImageViewCustomLoader> _imageLoader;
    id<HippyCustomTouchHandlerProtocol> _customTouchHandler;
    NSSet<Class<HippyImageProviderProtocol>> *_imageProviders;
    BOOL _isInitImageLoader;
    __weak id<HippyMethodInterceptorProtocol> _methodInterceptor;
}

dispatch_queue_t HippyJSThread;

+ (void)initialize {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Set up JS thread
        HippyJSThread = (id)kCFNull;
    });
}

static HippyBridge *HippyCurrentBridgeInstance = nil;

/**
 * The last current active bridge instance. This is set automatically whenever
 * the bridge is accessed. It can be useful for static functions or singletons
 * that need to access the bridge for purposes such as logging, but should not
 * be relied upon to return any particular instance, due to race conditions.
 */
+ (instancetype)currentBridge {
    return HippyCurrentBridgeInstance;
}

+ (void)setCurrentBridge:(HippyBridge *)currentBridge {
    HippyCurrentBridgeInstance = currentBridge;
}

- (instancetype)initWithDelegate:(id<HippyBridgeDelegate>)delegate launchOptions:(NSDictionary *)launchOptions {
    return [self initWithDelegate:delegate bundleURL:nil moduleProvider:nil launchOptions:launchOptions executorKey:nil];
}

- (instancetype)initWithBundleURL:(NSURL *)bundleURL
                   moduleProvider:(HippyBridgeModuleProviderBlock)block
                    launchOptions:(NSDictionary *)launchOptions
                      executorKey:(NSString *)executorKey;
{ return [self initWithDelegate:nil bundleURL:bundleURL moduleProvider:block launchOptions:launchOptions executorKey:executorKey]; }

- (instancetype)initWithDelegate:(id<HippyBridgeDelegate>)delegate
                       bundleURL:(NSURL *)bundleURL
                  moduleProvider:(HippyBridgeModuleProviderBlock)block
                   launchOptions:(NSDictionary *)launchOptions
                     executorKey:(NSString *)executorKey {
    if (self = [super init]) {
        _delegate = delegate;
        _bundleURL = bundleURL;
        _moduleProvider = block;
        _debugMode = [launchOptions[@"DebugMode"] boolValue];
        _enableTurbo = !!launchOptions[@"EnableTurbo"] ? [launchOptions[@"EnableTurbo"] boolValue] : YES;
        _shareOptions = [NSMutableDictionary new];
        _appVerson = @"";
        _executorKey = executorKey;
        _invalidateReason = HippyInvalidateReasonDealloc;
        [self setUp];

        HippyExecuteOnMainQueue(^{
            [self bindKeys];
        });
        HippyLogInfo(@"[Hippy_OC_Log][Life_Circle],%@ Init %p", NSStringFromClass([self class]), self);
    }
    return self;
}

HIPPY_NOT_IMPLEMENTED(-(instancetype)init)

- (void)dealloc {
    /**
     * This runs only on the main thread, but crashes the subclass
     * HippyAssertMainQueue();
     */
    HippyLogInfo(@"[Hippy_OC_Log][Life_Circle],%@ dealloc %p", NSStringFromClass([self class]), self);
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    self.invalidateReason = HippyInvalidateReasonDealloc;
    self.batchedBridge.invalidateReason = HippyInvalidateReasonDealloc;
    [self invalidate];
}

- (void)bindKeys {
    HippyAssertMainQueue();

#if TARGET_IPHONE_SIMULATOR
    HippyKeyCommands *commands = [HippyKeyCommands sharedInstance];

    // reload in current mode
    __weak __typeof(self) weakSelf = self;
    [commands registerKeyCommandWithInput:@"r" modifierFlags:UIKeyModifierCommand action:^(__unused UIKeyCommand *command) {
        // 暂时屏蔽掉RN的调试
        [weakSelf requestReload];
    }];
#endif
}

- (NSArray<Class> *)moduleClasses {
    return self.batchedBridge.moduleClasses;
}

- (id)moduleForName:(NSString *)moduleName {
    if ([self isKindOfClass:[HippyBatchedBridge class]]) {
        return [self moduleForName:moduleName];
    } else
        return [self.batchedBridge moduleForName:moduleName];
}

- (id)moduleForClass:(Class)moduleClass {
    return [self moduleForName:HippyBridgeModuleNameForClass(moduleClass)];
}

- (HippyExtAnimationModule *)animationModule {
    return [self moduleForName:@"AnimationModule"];
}

- (id<HippyImageViewCustomLoader>)imageLoader {
    if (!_isInitImageLoader) {
        _imageLoader = [[self modulesConformingToProtocol:@protocol(HippyImageViewCustomLoader)] lastObject];

        if (_imageLoader) {
            _isInitImageLoader = YES;
        }
    }
    return _imageLoader;
}

- (id<HippyCustomTouchHandlerProtocol>)customTouchHandler {
    if (!_customTouchHandler) {
        _customTouchHandler = [[self modulesConformingToProtocol:@protocol(HippyCustomTouchHandlerProtocol)] lastObject];
    }
    return _customTouchHandler;
}

- (NSSet<Class<HippyImageProviderProtocol>> *)imageProviders {
    if (!_imageProviders) {
        NSMutableSet *set = [NSMutableSet setWithCapacity:8];
        for (Class moduleClass in self.moduleClasses) {
            if ([moduleClass conformsToProtocol:@protocol(HippyImageProviderProtocol)]) {
                [set addObject:moduleClass];
            }
        }
        _imageProviders = [NSSet setWithSet:set];
    }
    return _imageProviders;
}

- (NSArray *)modulesConformingToProtocol:(Protocol *)protocol {
    NSMutableArray *modules = [NSMutableArray new];
    for (Class moduleClass in self.moduleClasses) {
        if ([moduleClass conformsToProtocol:protocol]) {
            id module = [self moduleForClass:moduleClass];
            if (module) {
                [modules addObject:module];
            }
        }
    }
    return [modules copy];
}

- (BOOL)moduleIsInitialized:(Class)moduleClass {
    return [self.batchedBridge moduleIsInitialized:moduleClass];
}

- (void)whitelistedModulesDidChange {
    [self.batchedBridge whitelistedModulesDidChange];
}

- (void)reload {
    /**
     * Any thread
     */
    dispatch_async(dispatch_get_main_queue(), ^{
        self.invalidateReason = HippyInvalidateReasonReload;
        self.batchedBridge.invalidateReason = HippyInvalidateReasonReload;
        [self invalidate];
        [self setUp];
    });
}

- (void)requestReload {
    if (self.batchedBridge.debugMode) {
        [[NSNotificationCenter defaultCenter] postNotificationName:HippyReloadNotification object:self];
        [self reload];
    }
}

- (void)setUp {
    HippyLogInfo(@"[Hippy_OC_Log][Life_Circle],%@ setUp %p", NSStringFromClass([self class]), self);
    _performanceLogger = [HippyPerformanceLogger new];
    [_performanceLogger markStartForTag:HippyPLBridgeStartup];

    // Only update bundleURL from delegate if delegate bundleURL has changed
    NSURL *previousDelegateURL = _delegateBundleURL;
    if ([self.delegate respondsToSelector:@selector(sourceURLForBridge:)]) {
        _delegateBundleURL = [self.delegate sourceURLForBridge:self];
    }
    if (_delegateBundleURL && ![_delegateBundleURL isEqual:previousDelegateURL]) {
        _bundleURL = _delegateBundleURL;
    }

    // Sanitize the bundle URL
    _bundleURL = [HippyConvert NSURL:_bundleURL.absoluteString];
    @try {
        [self createBatchedBridge];
        [self.batchedBridge start];
    } @catch (NSException *exception) {
        MttHippyException(exception);
    }
}

- (void)setMethodInterceptor:(id<HippyMethodInterceptorProtocol>)methodInterceptor {
    if ([self isKindOfClass:[HippyBatchedBridge class]]) {
        HippyBatchedBridge *batchedBrige = (HippyBatchedBridge *)self;
        batchedBrige.parentBridge.methodInterceptor = methodInterceptor;
    } else {
        _methodInterceptor = methodInterceptor;
    }
}

- (id<HippyMethodInterceptorProtocol>)methodInterceptor {
    if ([self isKindOfClass:[HippyBatchedBridge class]]) {
        HippyBatchedBridge *batchedBrige = (HippyBatchedBridge *)self;
        return batchedBrige.parentBridge.methodInterceptor;
    } else {
        return _methodInterceptor;
    }
}

- (void)setUpDevClientWithName:(NSString *)name {
    [self.batchedBridge setUpDevClientWithName:name];
}

- (void)createBatchedBridge {
    self.batchedBridge = [[HippyBatchedBridge alloc] initWithParentBridge:self];
}

- (BOOL)isLoading {
    return self.batchedBridge.loading;
}

- (BOOL)isValid {
    return self.batchedBridge.valid;
}

- (BOOL)isErrorOccured {
    return self.batchedBridge.errorOccured;
}

- (BOOL)isBatchActive {
    return [_batchedBridge isBatchActive];
}

- (void)invalidate {
    HippyLogInfo(@"[Hippy_OC_Log][Life_Circle],%@ invalide %p", NSStringFromClass([self class]), self);
    HippyBridge *batchedBridge = self.batchedBridge;
    self.batchedBridge = nil;

    if (batchedBridge) {
        HippyExecuteOnMainQueue(^{
            [batchedBridge invalidate];
        });
    }
}

- (void)enqueueJSCall:(NSString *)moduleDotMethod args:(NSArray *)args {
    NSArray<NSString *> *ids = [moduleDotMethod componentsSeparatedByString:@"."];
    NSString *module = ids[0];
    NSString *method = ids[1];
    [self enqueueJSCall:module method:method args:args completion:NULL];
}

- (void)enqueueJSCall:(NSString *)module method:(NSString *)method args:(NSArray *)args completion:(dispatch_block_t)completion {
    [self.batchedBridge enqueueJSCall:module method:method args:args completion:completion];
}

- (void)enqueueCallback:(NSNumber *)cbID args:(NSArray *)args {
    [self.batchedBridge enqueueCallback:cbID args:args];
}

- (JSValue *)callFunctionOnModule:(NSString *)module method:(NSString *)method arguments:(NSArray *)arguments error:(NSError **)error {
    return [self.batchedBridge callFunctionOnModule:module method:method arguments:arguments error:error];
}

- (void)setRedBoxShowEnabled:(BOOL)enabled {
#if HIPPY_DEBUG
    HippyRedBox *redBox = [self redBox];
    redBox.showEnabled = enabled;
#endif  // HIPPY_DEBUG
}

- (HippyOCTurboModule *)turboModuleWithName:(NSString *)name {
    return [self.batchedBridge turboModuleWithName:name];
}

@end

@implementation UIView(Bridge)

#define kBridgeKey @"bridgeKey"

- (void)setBridge:(HippyBridge *)bridge {
    if (bridge) {
        NSMapTable *mapTable = [NSMapTable strongToWeakObjectsMapTable];
        [mapTable setObject:bridge forKey:kBridgeKey];
        objc_setAssociatedObject(self, @selector(bridge), mapTable, OBJC_ASSOCIATION_RETAIN);
    }
}

- (HippyBridge *)bridge {
    NSMapTable *mapTable = objc_getAssociatedObject(self, _cmd);
    HippyBridge *bridge = [mapTable objectForKey:kBridgeKey];
    return bridge;
}

@end
