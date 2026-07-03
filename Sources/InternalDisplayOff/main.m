#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>

extern CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef config, CGDirectDisplayID display, bool enabled);

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, assign) CGDirectDisplayID builtInDisplayID;
@property(nonatomic, assign) BOOL internalDisplayDisconnected;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [self setupStatusItem];
    [self disconnectInternalDisplay:nil];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self reconnectInternalDisplay:nil];
}

- (void)setupStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"Internal Off";

    NSMenu *menu = [[NSMenu alloc] init];
    [menu addItemWithTitle:@"Turn Off Internal Display" action:@selector(disconnectInternalDisplay:) keyEquivalent:@"o"];
    [menu addItemWithTitle:@"Restore Internal Display" action:@selector(reconnectInternalDisplay:) keyEquivalent:@"r"];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Quit" action:@selector(quit:) keyEquivalent:@"q"];
    self.statusItem.menu = menu;
}

- (IBAction)disconnectInternalDisplay:(id)sender {
    CGDirectDisplayID builtIn = [self builtInDisplayIDFromOnlineDisplays];
    if (builtIn == kCGNullDirectDisplay) {
        [self showAlertWithTitle:@"No built-in display found"
                         message:@"This Mac does not report a built-in display."];
        return;
    }

    if (![self hasActiveExternalDisplay]) {
        [self showAlertWithTitle:@"Connect an external display first"
                         message:@"The internal display was left on so you do not lose access to your screen."];
        return;
    }

    self.builtInDisplayID = builtIn;
    if ([self setDisplay:builtIn enabled:false]) {
        self.internalDisplayDisconnected = YES;
        self.statusItem.button.title = @"Internal Off";
    } else {
        [self showAlertWithTitle:@"Could not turn off the internal display"
                         message:@"macOS rejected the display change on this machine or OS version."];
    }
}

- (IBAction)reconnectInternalDisplay:(id)sender {
    CGDirectDisplayID displayID = self.builtInDisplayID;
    if (displayID == kCGNullDirectDisplay) {
        displayID = [self builtInDisplayIDFromOnlineDisplays];
    }

    if (displayID == kCGNullDirectDisplay) {
        return;
    }

    if ([self setDisplay:displayID enabled:true]) {
        self.internalDisplayDisconnected = NO;
        self.statusItem.button.title = @"Display Ready";
    }
}

- (IBAction)quit:(id)sender {
    [NSApp terminate:nil];
}

- (CGDirectDisplayID)builtInDisplayIDFromOnlineDisplays {
    CGDisplayCount count = 0;
    CGGetOnlineDisplayList(UINT32_MAX, NULL, &count);
    if (count == 0) {
        return kCGNullDirectDisplay;
    }

    CGDirectDisplayID displays[count];
    CGGetOnlineDisplayList(count, displays, &count);

    for (CGDisplayCount index = 0; index < count; index++) {
        if (CGDisplayIsBuiltin(displays[index])) {
            return displays[index];
        }
    }

    return kCGNullDirectDisplay;
}

- (BOOL)hasActiveExternalDisplay {
    CGDisplayCount count = 0;
    CGGetActiveDisplayList(UINT32_MAX, NULL, &count);
    if (count == 0) {
        return NO;
    }

    CGDirectDisplayID displays[count];
    CGGetActiveDisplayList(count, displays, &count);

    for (CGDisplayCount index = 0; index < count; index++) {
        if (!CGDisplayIsBuiltin(displays[index])) {
            return YES;
        }
    }

    return NO;
}

- (BOOL)setDisplay:(CGDirectDisplayID)displayID enabled:(bool)enabled {
    CGDisplayConfigRef config = NULL;
    CGError beginError = CGBeginDisplayConfiguration(&config);
    if (beginError != kCGErrorSuccess || config == NULL) {
        return NO;
    }

    CGError configureError = CGSConfigureDisplayEnabled(config, displayID, enabled);
    if (configureError != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        return NO;
    }

    CGError completeError = CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
    return completeError == kCGErrorSuccess;
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = message;
    alert.alertStyle = NSAlertStyleInformational;
    [alert runModal];
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
