#import <Foundation/Foundation.h>

// A refused visitor-flow write (docs/en/visitor-flow-contract.md, section 8.1). The error string
// is `visitor_flow.<code>[: <location>]`; numbers and the language ride in `detail`. Pure data:
// it imports no UI and never talks to Core.
@interface DBFlowError : NSObject
@property(nonatomic, readonly, copy) NSString *code;      // without the visitor_flow. prefix
@property(nonatomic, readonly, copy) NSString *location;  // empty when Core named none
@property(nonatomic, readonly, copy) NSString *stepID;    // nil when the location names no step
@property(nonatomic, readonly, copy) NSString *optionID;
@property(nonatomic, readonly, copy) NSString *field;     // title, body, message, label or alt
@property(nonatomic, readonly, copy) NSString *lang;
@property(nonatomic, readonly, assign) NSInteger imageIndex;  // -1 when none
@property(nonatomic, readonly, copy) NSDictionary *detail;
@property(nonatomic, readonly, copy) NSString *raw;

// Parses a failed write result's `err` and `detail`. Returns nil when err is not a
// visitor_flow.* error.
+ (DBFlowError *)errorFromResult:(NSDictionary *)result;
+ (DBFlowError *)errorFromString:(NSString *)err detail:(NSDictionary *)detail;

// The i18n key of this error's message: flow_error.<code>.
- (NSString *)messageKey;

// `template` is the localized flow_error.<code> text. {limit}, {value}, {min}, {max} come from
// detail; {lang} is run through langName.
- (NSString *)messageFromTemplate:(NSString *)template
                         langName:(NSString *(^)(NSString *lang))langName;

// The control this error belongs to, most specific first: the location itself, then each shorter
// prefix. A location-free error yields an empty list.
- (NSArray *)anchors;

// The anchor of a warning key such as visitor_flow.steps.<step>[.<option>], or nil.
+ (NSString *)anchorForWarningKey:(NSString *)key;
@end
