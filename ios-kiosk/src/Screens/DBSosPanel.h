#import <UIKit/UIKit.h>

#import "DBWidgets.h"

@class DBTexts;

// The compact SOS control: a stock button with the alert icon and a title in the negative
// colour. It only opens the confirmation panel; it never arms anything by itself.
UIButton *DBSosTriggerButton(void);

// The SOS confirmation surface, presented inside the screen like the admin password panel
// (iOS 5 modal presentation is unreliable). It says what an alert does and hosts the slide
// control: sliding end to end starts the existing cancellable countdown, Cancel or ten seconds
// without a slide closes it. Core is still told only by the screen's own sosSliderDidFire:.
//
// The panel is the slider's delegate and forwards every callback to the screen unchanged.
@interface DBSosPanel : UIView <DBSosSliderDelegate>

- (id)initWithSlider:(DBSosSlider *)slider delegate:(id<DBSosSliderDelegate>)delegate;
- (void)applyTexts:(DBTexts *)texts;
// below is the screen's emergency overlay, which must stay above the panel; nil adds on top.
- (void)presentInView:(UIView *)host below:(UIView *)below;
// Closes the panel and returns the slider to idle.
- (void)dismiss;
@property(nonatomic, readonly) BOOL presented;

@end
