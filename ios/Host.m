#import <UIKit/UIKit.h>
#include <stdlib.h>
#import "BTRRangeDownloader.h"

@interface BTRHostViewController : UIViewController
@property(nonatomic,strong) UITextField *urlInput;
@property(nonatomic,strong) UITextField *backupInput;
@property(nonatomic,strong) UITextField *rangeInput;
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) BTRRangeDownloader *downloader;
@property(nonatomic) NSUInteger generation;
@end

@implementation BTRHostViewController
- (UITextField *)field:(NSString *)placeholder {
    UITextField *field = [[UITextField alloc] init];
    field.placeholder = placeholder; field.borderStyle = UITextBorderStyleRoundedRect;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    [field.heightAnchor constraintEqualToConstant:44].active = YES;
    return field;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = @"BTR transport experiment";
    UIStackView *stack = [[UIStackView alloc] init]; stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
      [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:20],
      [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-20],
      [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:20]]];
    UILabel *intro = [[UILabel alloc] init]; intro.numberOfLines = 0;
    intro.text = @"Native download test host. Enter a media URL you are authorized to access and a byte range. Tests the download component only; not connected to the Bilibili player.";
    [stack addArrangedSubview:intro];
    self.urlInput = [self field:@"HTTPS media URL (.m4s / .mp4 / .flv)"];
    self.urlInput.keyboardType = UIKeyboardTypeURL; [stack addArrangedSubview:self.urlInput];
    self.backupInput = [self field:@"Backup URL for the same file (optional)"];
    self.backupInput.keyboardType = UIKeyboardTypeURL; [stack addArrangedSubview:self.backupInput];
    self.rangeInput = [self field:@"Byte range start-end (at most 8 MiB)"];
    self.rangeInput.text = @"0-262143"; [stack addArrangedSubview:self.rangeInput];
    UIButton *start = [UIButton buttonWithType:UIButtonTypeSystem]; [start setTitle:@"Start download" forState:UIControlStateNormal];
    [start addTarget:self action:@selector(startDownload) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:start];
    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem]; [cancel setTitle:@"Cancel" forState:UIControlStateNormal];
    [cancel addTarget:self action:@selector(cancelDownload) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:cancel];
    self.status = [[UILabel alloc] init]; self.status.numberOfLines = 0;
    self.status.text = @"Waiting for a test; compatibility and speedup not proven."; [stack addArrangedSubview:self.status];
    NSError *error = nil;
    NSString *core = [NSString stringWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"range-core" ofType:@"js"] encoding:NSUTF8StringEncoding error:&error];
    NSString *policy = [NSString stringWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"policy" ofType:@"js"] encoding:NSUTF8StringEncoding error:&error];
    if(core && policy) self.downloader = [[BTRRangeDownloader alloc] initWithRangeCore:core policy:policy error:&error];
    if(!self.downloader) self.status.text = error.localizedDescription ?: @"Missing policy resource";
}
- (void)startDownload {
    if(!self.downloader) return;
    [self.view endEditing:YES];
    NSString *range = [self.rangeInput.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]+-[0-9]+$" options:0 error:nil];
    if(![pattern firstMatchInString:range options:0 range:NSMakeRange(0,range.length)]) {
        self.status.text = @"Range must be start-end"; return;
    }
    NSArray *bounds = [range componentsSeparatedByString:@"-"];
    if([bounds[0] length] > 16 || [bounds[1] length] > 16) { self.status.text = @"Range too large"; return; }
    uint64_t begin = strtoull([bounds[0] UTF8String],NULL,10), end = strtoull([bounds[1] UTF8String],NULL,10);
    NSMutableArray *urls = [NSMutableArray arrayWithObject:self.urlInput.text ?: @""];
    if(self.backupInput.text.length) [urls addObject:self.backupInput.text];
    NSUInteger generation = ++self.generation; NSTimeInterval began = NSProcessInfo.processInfo.systemUptime;
    self.status.text = @"Downloading (up to 4 concurrent requests)…";
    __weak typeof(self) weakSelf = self;
    [self.downloader downloadURLs:urls start:begin end:end headers:@{} completion:^(NSData *data, NSNumber *total, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if(!strongSelf || generation != strongSelf.generation) return;
        NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime - began;
        strongSelf.status.text = error ? [NSString stringWithFormat:@"Failed / cancelled: %@",error.localizedDescription]
          : [NSString stringWithFormat:@"Done: %lu bytes\nFile total: %@ bytes\nElapsed: %.3f s\nNo player or speed comparison done.",(unsigned long)data.length,total,elapsed];
    }];
}
- (void)cancelDownload { self.generation++; [self.downloader cancel]; self.status.text = @"Cancelled"; }
- (void)dealloc { [self.downloader close]; }
@end

@interface BTRSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation BTRSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    if(![scene isKindOfClass:UIWindowScene.class]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:[[BTRHostViewController alloc] init]];
    [self.window makeKeyAndVisible];
}
@end
@interface BTRAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation BTRAppDelegate
@end
int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(BTRAppDelegate.class)); }
}
