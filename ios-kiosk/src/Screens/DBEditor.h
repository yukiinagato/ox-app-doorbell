#import <UIKit/UIKit.h>

@class DBUiPalette;
@class DBEditPage;

// A small native form and list editor for the iOS 5 kiosk. Every settings item
// that used to say "open in Admin" is a page of fields built from the live
// configuration; a change is written straight through Core and the page is
// rebuilt from the configuration that results. iOS 5.1 UIKit only.
typedef enum {
  DBEditKindInfo = 0,     // read-only value
  DBEditKindText,         // single-line text (UIAlertView plain text input)
  DBEditKindSecret,       // write-only secret (secure text input); value shows set/unset
  DBEditKindNumber,       // integer (number pad)
  DBEditKindBool,         // UISwitch
  DBEditKindChoice,       // one of choices, picked on a sub-page
  DBEditKindMulti,        // any of choices, picked on a sub-page
  DBEditKindTime,         // "HH:MM", UIDatePicker
  DBEditKindColor,        // "#RRGGBB", swatches plus hex entry
  DBEditKindPage,         // opens a sub-page
  DBEditKindAction,       // runs a block
} DBEditKind;

@interface DBEditField : NSObject
@property(nonatomic, assign) DBEditKind kind;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *detail;       // display value (computed when nil)
@property(nonatomic, strong) id value;             // raw value
@property(nonatomic, strong) NSArray *choices;     // @[ @[value, label], ... ]
@property(nonatomic, copy) NSString *placeholder;
@property(nonatomic, assign) UIKeyboardType keyboard;
@property(nonatomic, assign) BOOL destructive;
@property(nonatomic, assign) BOOL confirm;         // ask before running an action
@property(nonatomic, assign) NSInteger minimum;
@property(nonatomic, assign) NSInteger maximum;
@property(nonatomic, strong) UIImage *image;
// Returns YES when the write succeeded; the editor then rebuilds the page.
@property(nonatomic, copy) BOOL (^onChange)(id value);
@property(nonatomic, copy) DBEditPage *(^page)(void);
@property(nonatomic, copy) void (^action)(void);
+ (DBEditField *)kind:(DBEditKind)kind title:(NSString *)title value:(id)value;
@end

@interface DBEditSection : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *footer;
@property(nonatomic, strong) NSArray *fields;
// A list section offers swipe/edit-mode delete and, with onMove, reordering.
@property(nonatomic, copy) BOOL (^onDelete)(NSInteger index);
@property(nonatomic, copy) BOOL (^onMove)(NSInteger from, NSInteger to);
+ (DBEditSection *)title:(NSString *)title fields:(NSArray *)fields;
@end

@interface DBEditPage : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSArray *(^build)(void);   // DBEditSection list, rebuilt on every change
@property(nonatomic, copy) void (^onAdd)(void);         // shows a "+" button
@property(nonatomic, assign) BOOL searchable;          // filter rows by title/detail
@property(nonatomic, copy) void (^onAppear)(void);
+ (DBEditPage *)title:(NSString *)title build:(NSArray *(^)(void))build;
@end

@interface DBEditorView : UIView
@property(nonatomic, copy) NSString *backTitle;
@property(nonatomic, copy) NSString *doneTitle;
@property(nonatomic, copy) NSString *editTitle;
@property(nonatomic, copy) NSString *cancelTitle;
@property(nonatomic, copy) NSString *okTitle;
@property(nonatomic, copy) NSString *confirmTitle;
@property(nonatomic, copy) NSString *setText;       // a stored secret
@property(nonatomic, copy) NSString *unsetText;
@property(nonatomic, copy) NSString *customColorTitle;
@property(nonatomic, copy) NSString *searchPlaceholder;
@property(nonatomic, copy) void (^onClose)(void);
- (void)applyPalette:(DBUiPalette *)palette;
- (void)pushPage:(DBEditPage *)page;
- (void)popPage;
- (void)reloadPage;
// Single-line prompt shared by pages that need a value before building an entry.
- (void)promptTitle:(NSString *)title value:(NSString *)value placeholder:(NSString *)placeholder
           keyboard:(UIKeyboardType)keyboard secure:(BOOL)secure
               then:(void (^)(NSString *text))then;
- (void)confirmTitle:(NSString *)title message:(NSString *)message then:(void (^)(void))then;
- (void)showMessage:(NSString *)message;
@end
