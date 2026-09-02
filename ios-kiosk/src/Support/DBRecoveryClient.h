#import <Foundation/Foundation.h>

// Bounded client for the optional fixed-purpose root supervisor. It sends only
// strict heartbeat JSON plus the frozen STATUS and MODE off|auto|on commands.
@interface DBRecoveryClient : NSObject

@property(nonatomic, readonly) BOOL helperReachable;
@property(nonatomic, readonly) BOOL helperSupervising;
@property(nonatomic, readonly, copy) NSString *configuredMode;
@property(nonatomic, readonly, copy) NSString *effectiveMode;
@property(nonatomic, copy) void (^statusHandler)(NSDictionary *status);

- (id)initWithPolicy:(NSString *)policy
                 role:(NSString *)role
        stateProvider:(NSString * (^)(void))stateProvider;

// The caller resolves the canonical fleet value or the local boot fallback.
// Invalid canonical values are rejected and become effective mode off.
- (void)updateConfiguredPolicy:(NSString *)policy
                         source:(NSString *)source
          nativeKioskAvailable:(BOOL)nativeKioskAvailable
            nativeKioskHealthy:(BOOL)nativeKioskHealthy;

- (void)start;
- (void)stop;
- (void)noteMemoryPressure;

+ (BOOL)isValidHelperMode:(NSString *)mode;
+ (NSString *)effectiveModeForConfiguredMode:(NSString *)mode
                        nativeKioskAvailable:(BOOL)nativeKioskAvailable
                          nativeKioskHealthy:(BOOL)nativeKioskHealthy
           consecutiveNativeKioskFailures:(NSUInteger)failureCount;

// Pure policy helpers shared by launch recovery, the watchdog, and host tests.
+ (BOOL)shouldEnterSafeModeWithPreviousCleanExit:(NSNumber *)previousCleanExit
                                         launches:(NSArray *)launches
                                              now:(NSTimeInterval)now
                                  updatedLaunches:(NSArray **)updatedLaunches;
+ (NSUInteger)restartBackoffSecondsForAttempt:(NSUInteger)attempt;

@end
