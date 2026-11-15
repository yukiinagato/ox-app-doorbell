#import <Foundation/Foundation.h>

@class DBTexts;

// What the home screen draws for db_core_air_quality_json. Core decides the state and the
// level; this only turns the document into one line of text, a level colour, and a spoken label.
@interface DBAirQualityModel : NSObject

// visible is NO for "hidden", an unknown state, and a nil document.
@property(nonatomic, readonly) BOOL visible;
// YES for "stale": the last reading is still shown, dimmed.
@property(nonatomic, readonly) BOOL dimmed;
@property(nonatomic, readonly, copy) NSString *state;
@property(nonatomic, readonly, copy) NSString *text;
@property(nonatomic, readonly, copy) NSString *accessibilityLabel;
// The level dot's colour, or nil when there is no reading to grade.
@property(nonatomic, readonly, copy) NSString *levelHex;

+ (DBAirQualityModel *)modelWithDocument:(NSDictionary *)document texts:(DBTexts *)texts;
// US EPA AQI category colours, keyed by Core's level names; nil for an unknown level.
+ (NSString *)hexForLevel:(NSString *)level;
// The reading rounded to whole units, or one decimal when Core reports a fraction.
+ (NSString *)valueString:(NSNumber *)pm25;

@end
