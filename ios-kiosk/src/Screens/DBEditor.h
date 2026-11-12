#import <UIKit/UIKit.h>

@class DBEditPage;
@class DBNavBar;

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
  DBEditKindTime,         // "HH:MM", UIDatePicker on a sub-page
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
// The consequence named in that confirmation, for a destructive or confirmed action.
@property(nonatomic, copy) NSString *confirmMessage;
@property(nonatomic, assign) BOOL checked;         // shows the checkmark accessory
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
// The consequence named when a row of this section is about to be deleted.
@property(nonatomic, copy) NSString *(^deleteMessage)(NSInteger index);
@property(nonatomic, copy) BOOL (^onMove)(NSInteger from, NSInteger to);
+ (DBEditSection *)title:(NSString *)title fields:(NSArray *)fields;
@end

@interface DBEditPage : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSArray *(^build)(void);   // DBEditSection list, rebuilt on every change
@property(nonatomic, copy) void (^onAdd)(void);         // shows the system Add bar button
@property(nonatomic, copy) void (^onDone)(void);        // shows the system Done bar button
@property(nonatomic, assign) BOOL searchable;          // filter rows by title/detail
// With searchable: build reads the editor's filterText and returns the matching rows itself.
@property(nonatomic, assign) BOOL filtersItself;
// Replaces the editor's search placeholder on this page.
@property(nonatomic, copy) NSString *searchPlaceholder;
// Free-form content above the rows (a picker); it replaces the search bar.
@property(nonatomic, strong) UIView *headerView;
@property(nonatomic, copy) void (^onAppear)(void);
+ (DBEditPage *)title:(NSString *)title build:(NSArray *(^)(void))build;
@end

// The page stack lives on the host's DBNavBar: every page pushes one navigation item above
// whatever the host already shows there, the bar's own back button leaves a page, and add,
// edit, and done are bar button items. The view itself is only the grouped table; it hides
// when its last page is left.
@interface DBEditorView : UIView
- (id)initWithNavBar:(DBNavBar *)navBar;
@property(nonatomic, copy) NSString *cancelTitle;
@property(nonatomic, copy) NSString *okTitle;
@property(nonatomic, copy) NSString *confirmTitle;
@property(nonatomic, copy) NSString *setText;       // a stored secret
@property(nonatomic, copy) NSString *unsetText;
@property(nonatomic, copy) NSString *customColorTitle;
@property(nonatomic, copy) NSString *searchPlaceholder;
// Runs after the last page was left.
@property(nonatomic, copy) void (^onClose)(void);
// Receives showMessage: texts; without it they appear in an alert.
@property(nonatomic, copy) void (^onMessage)(NSString *message);
// Runs after a page was pushed or left, so the host can follow the bar's top item.
@property(nonatomic, copy) void (^onStackChanged)(void);
@property(nonatomic, readonly) NSUInteger pageCount;
@property(nonatomic, readonly) NSString *filterText;
- (void)pushPage:(DBEditPage *)page;
- (void)popPage;
- (void)closeAllPages;
- (void)reloadPage;
// Single-line prompt shared by pages that need a value before building an entry.
- (void)promptTitle:(NSString *)title value:(NSString *)value placeholder:(NSString *)placeholder
           keyboard:(UIKeyboardType)keyboard secure:(BOOL)secure
               then:(void (^)(NSString *text))then;
- (void)confirmTitle:(NSString *)title message:(NSString *)message then:(void (^)(void))then;
- (void)showMessage:(NSString *)message;
@end

// Stock grouped cells shared by the editor and the settings tables. The cell style follows
// the texts: Default without a value, Value1 while title and value fit one line, Subtitle
// with wrapped lines otherwise.
typedef struct {
  UITableViewCellStyle style;
  CGFloat height;
} DBEditCellLayout;

// The width a grouped cell leaves for its labels beside an accessory and an image.
CGFloat DBEditCellTextWidth(UITableView *table, CGFloat accessoryWidth, CGFloat imageWidth);
DBEditCellLayout DBEditCellLayoutMake(NSString *title, NSString *detail, CGFloat textWidth);
// A reset cell of that style. A destructive cell carries the system red on its title, the
// one colour a settings row may set.
UITableViewCell *DBEditDequeueCell(UITableView *table, UITableViewCellStyle style,
                                   BOOL destructive);
