#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <unistd.h>

@interface NSObject (DoorbellRegistration)
+ (id)containerWithIdentifier:(NSString *)identifier createIfNecessary:(BOOL)create existed:(BOOL *)existed error:(NSError **)error;
- (NSURL *)url;
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) return 2;
        NSString *mode = [NSString stringWithUTF8String:argv[1]];
        if ([mode isEqualToString:@"register"] && argc > 2) {
            dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
            Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
            if (!workspaceClass) return 8;
            id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, NSSelectorFromString(@"defaultWorkspace"));
            NSString *path = [NSString stringWithUTF8String:argv[2]];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
            NSString *identifier = info[@"CFBundleIdentifier"];
            if (![identifier isEqualToString:@"jp.ox.doorbell.t15uitest"]) return 10;
            dlopen("/System/Library/PrivateFrameworks/MobileContainerManager.framework/MobileContainerManager", RTLD_NOW);
            id container = [NSClassFromString(@"MCMAppDataContainer") containerWithIdentifier:identifier createIfNecessary:YES existed:NULL error:NULL];
            NSString *dataPath = [[container url] path];
            if (!dataPath) return 11;
            NSMutableDictionary *registration = [@{@"CFBundleIdentifier":identifier,
                @"Path":path, @"Container":dataPath, @"ApplicationType":@"System",
                @"BundleNameIsLocalized":@YES, @"CompatibilityState":@NO,
                @"IsDeletable":@YES, @"_LSBundlePlugins":@{}} mutableCopy];
            BOOL result = ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, NSSelectorFromString(@"registerApplicationDictionary:"), registration);
            printf("application_registered=%s\n", result ? "true" : "false");
            return result ? 0 : 9;
        }
        if ([mode isEqualToString:@"launch"]) {
            void *handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
            int (*launch)(CFStringRef, Boolean) = dlsym(handle, "SBSLaunchApplicationWithIdentifier");
            if (!launch) return 3;
            int result = launch(CFSTR("jp.ox.doorbell.t15uitest"), false);
            printf("springboard_launch_result=%d\n", result);
            return result;
        }
        if ([mode isEqualToString:@"screenshot"] && argc > 2) {
            CGImageRef (*capture)(void) = dlsym(RTLD_DEFAULT, "UIGetScreenImage");
            if (!capture) return 4;
            CGImageRef screen = capture();
            if (!screen) return 5;
            NSData *data = UIImagePNGRepresentation([UIImage imageWithCGImage:screen]);
            CGImageRelease(screen);
            return [data writeToFile:[NSString stringWithUTF8String:argv[2]] atomically:YES] ? 0 : 6;
        }
        if ([mode isEqualToString:@"inspect"] && argc > 2) {
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithUTF8String:argv[2]]];
            if (!info) return 7;
            NSMutableDictionary *result = [NSMutableDictionary dictionary];
            for (NSString *key in @[@"CFBundleIdentifier", @"CFBundleShortVersionString", @"CFBundleVersion", @"MinimumOSVersion"])
                if (info[key]) result[key] = info[key];
            NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
            fwrite(json.bytes, 1, json.length, stdout);
            puts("");
            return 0;
        }
        return 2;
    }
}
