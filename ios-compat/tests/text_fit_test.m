#import <Foundation/Foundation.h>

#import "DBTextFit.h"

static void require(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    exit(1);
  }
}

// A deterministic measurer: a character is `size` wide (CJK) or half of that (Latin), a line is
// 1.2 * size tall, wrapping per character, and explicit newlines start a new line.
static DBTextMeasure measurer(NSString *text) {
  return ^CGFloat(CGFloat size, CGFloat width) {
    NSInteger lines = 0;
    for (NSString *paragraph in [text componentsSeparatedByString:@"\n"]) {
      CGFloat used = 0;
      NSInteger count = 1;
      for (NSUInteger i = 0; i < [paragraph length]; i++) {
        CGFloat w = [paragraph characterAtIndex:i] < 0x300 ? size * 0.5 : size;
        if (used + w > width && used > 0) {
          count++;
          used = 0;
        }
        used += w;
      }
      lines += count;
    }
    return lines * size * 1.2;
  };
}

static BOOL fits(NSString *text, CGSize box, CGFloat size) {
  return measurer(text)(size, box.width) <= box.height;
}

static void check(NSString *name, NSString *text, CGSize box) {
  CGFloat size = DBTextFitSize(box, 28, box.height, measurer(text));
  if (fits(text, box, 28)) {
    require(fits(text, box, size), [name stringByAppendingString:@": result must fit"]);
    require(size >= box.height || !fits(text, box, size + 1),
            [name stringByAppendingString:@": result must be the largest"]);
  } else {
    require(size == 28, [name stringByAppendingString:@": floor when nothing fits"]);
  }
}

int main(void) {
  @autoreleasepool {
    CGSize landscape = CGSizeMake(900, 420), portrait = CGSizeMake(340, 640);
    NSArray *texts = @[
      @"OK", @"Please wait a moment, I am coming right now.",
      @"少々お待ちください。すぐに参ります。", @"请稍等，我马上就来。",
      @"First line\nSecond line\nThird", @"",
    ];
    for (NSUInteger i = 0; i < [texts count]; i++) {
      check([NSString stringWithFormat:@"landscape %lu", (unsigned long)i], texts[i], landscape);
      check([NSString stringWithFormat:@"portrait %lu", (unsigned long)i], texts[i], portrait);
    }
    NSMutableString *longText = [NSMutableString string];
    for (int i = 0; i < 400; i++) [longText appendString:@"あ"];
    require(DBTextFitSize(portrait, 28, portrait.height, measurer(longText)) == 28,
            @"a very long text keeps the floor");
    require(DBTextFitSize(landscape, 28, landscape.height, measurer(@"OK")) > 200,
            @"a short text grows large");
    CGFloat lines = DBTextFitSize(landscape, 28, landscape.height, measurer(@"a\nb\nc\nd"));
    require(lines <= 420 / (4 * 1.2), @"explicit newlines count as lines");
    __block int calls = 0;
    DBTextFitSize(portrait, 28, portrait.height, ^CGFloat(CGFloat s, CGFloat w) {
      calls++;
      return measurer(@"少々お待ちください。すぐに参ります。")(s, w);
    });
    require(calls <= 12, @"the search measures O(log n) times");
    require(DBTextFitSize(CGSizeMake(0, 0), 28, 100, measurer(@"x")) == 28, @"empty box");
    NSLog(@"text_fit_test ok");
  }
  return 0;
}
