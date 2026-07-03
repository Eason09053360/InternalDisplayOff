#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/graphics/IOGraphicsLib.h>

extern CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef config, CGDirectDisplayID display, bool enabled);

enum {
    kMaxDisplays = 16
};

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSWindow *blackoutWindow;
@property(nonatomic, assign) CGDirectDisplayID builtInDisplayID;
@property(nonatomic, assign) float previousBrightness;
@property(nonatomic, assign) BOOL hasPreviousBrightness;
@property(nonatomic, assign) BOOL hardDisabled;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.builtInDisplayID = kCGNullDirectDisplay;
    [self setupStatusItem];
    [self dimAndCoverInternalDisplay:nil];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self restoreInternalDisplay:nil];
}

- (void)setupStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"Internal Dimmed";

    NSMenu *menu = [[NSMenu alloc] init];
    [menu addItemWithTitle:@"Dim + Cover Internal Display" action:@selector(dimAndCoverInternalDisplay:) keyEquivalent:@"d"];
    [menu addItemWithTitle:@"Restore Internal Display" action:@selector(restoreInternalDisplay:) keyEquivalent:@"r"];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Experimental Hard Disable..." action:@selector(experimentalHardDisable:) keyEquivalent:@"e"];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Quit" action:@selector(quit:) keyEquivalent:@"q"];
    self.statusItem.menu = menu;
}

- (IBAction)dimAndCoverInternalDisplay:(id)sender {
    CGDirectDisplayID builtIn = [self builtInDisplayIDFromActiveDisplays];
    if (builtIn == kCGNullDirectDisplay) {
        [self showAlertWithTitle:@"No built-in display found"
                         message:@"This Mac does not report an active built-in display."];
        return;
    }

    if (![self hasActiveExternalDisplay]) {
        [self showAlertWithTitle:@"Connect an external display first"
                         message:@"The internal display was left on so you do not lose access to your screen."];
        return;
    }

    self.builtInDisplayID = builtIn;

    float brightness = 1.0f;
    if ([self readBrightness:&brightness forDisplay:builtIn]) {
        self.previousBrightness = brightness;
        self.hasPreviousBrightness = YES;
    }

    [self setBrightness:0.0f forDisplay:builtIn];
    [self showBlackoutWindowOnDisplay:builtIn];
    [self movePointerToExternalDisplayIfNeededFromDisplay:builtIn];

    self.statusItem.button.title = @"Internal Dimmed";
}

- (IBAction)restoreInternalDisplay:(id)sender {
    if (self.hardDisabled && self.builtInDisplayID != kCGNullDirectDisplay) {
        [self setDisplay:self.builtInDisplayID enabled:true];
        self.hardDisabled = NO;
    }

    [self.blackoutWindow orderOut:nil];
    self.blackoutWindow = nil;

    if (self.builtInDisplayID != kCGNullDirectDisplay && self.hasPreviousBrightness) {
        [self setBrightness:MAX(self.previousBrightness, 0.25f) forDisplay:self.builtInDisplayID];
    }

    self.statusItem.button.title = @"Display Ready";
}

- (IBAction)experimentalHardDisable:(id)sender {
    CGDirectDisplayID builtIn = [self builtInDisplayIDFromActiveDisplays];
    if (builtIn == kCGNullDirectDisplay || ![self hasActiveExternalDisplay]) {
        [self showAlertWithTitle:@"External display required"
                         message:@"Hard disable is only available while an external display is active."];
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Experimental hard disable";
    alert.informativeText = @"This uses a private macOS API. It can fail on Apple Silicon and may require a reboot if the app is killed before restore. Use the safer dim + cover mode unless you are testing.";
    [alert addButtonWithTitle:@"Cancel"];
    [alert addButtonWithTitle:@"Hard Disable"];
    alert.alertStyle = NSAlertStyleCritical;

    if ([alert runModal] != NSAlertSecondButtonReturn) {
        return;
    }

    self.builtInDisplayID = builtIn;
    if ([self setDisplay:builtIn enabled:false]) {
        self.hardDisabled = YES;
        self.statusItem.button.title = @"Internal Disabled";
    } else {
        [self showAlertWithTitle:@"Could not hard disable the internal display"
                         message:@"macOS rejected the private display configuration call on this machine or OS version."];
    }
}

- (IBAction)quit:(id)sender {
    [NSApp terminate:nil];
}

- (CGDirectDisplayID)builtInDisplayIDFromActiveDisplays {
    CGDisplayCount count = 0;
    CGDirectDisplayID displays[kMaxDisplays] = {0};

    CGError error = CGGetActiveDisplayList(kMaxDisplays, displays, &count);
    if (error != kCGErrorSuccess) {
        return kCGNullDirectDisplay;
    }

    for (CGDisplayCount index = 0; index < count; index++) {
        if (CGDisplayIsBuiltin(displays[index])) {
            return displays[index];
        }
    }

    return kCGNullDirectDisplay;
}

- (BOOL)hasActiveExternalDisplay {
    CGDisplayCount count = 0;
    CGDirectDisplayID displays[kMaxDisplays] = {0};

    CGError error = CGGetActiveDisplayList(kMaxDisplays, displays, &count);
    if (error != kCGErrorSuccess) {
        return NO;
    }

    for (CGDisplayCount index = 0; index < count; index++) {
        if (!CGDisplayIsBuiltin(displays[index])) {
            return YES;
        }
    }

    return NO;
}

- (void)showBlackoutWindowOnDisplay:(CGDirectDisplayID)displayID {
    NSScreen *targetScreen = nil;
    for (NSScreen *screen in [NSScreen screens]) {
        NSNumber *screenNumber = screen.deviceDescription[@"NSScreenNumber"];
        if (screenNumber != nil && screenNumber.unsignedIntValue == displayID) {
            targetScreen = screen;
            break;
        }
    }

    if (targetScreen == nil) {
        return;
    }

    [self.blackoutWindow orderOut:nil];

    NSWindow *window = [[NSWindow alloc] initWithContentRect:targetScreen.frame
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO
                                                      screen:targetScreen];
    window.backgroundColor = NSColor.blackColor;
    window.opaque = YES;
    window.level = NSScreenSaverWindowLevel;
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                NSWindowCollectionBehaviorFullScreenAuxiliary |
                                NSWindowCollectionBehaviorStationary;
    window.ignoresMouseEvents = YES;
    [window makeKeyAndOrderFront:nil];
    self.blackoutWindow = window;
}

- (BOOL)readBrightness:(float *)brightness forDisplay:(CGDirectDisplayID)displayID {
    io_service_t service = CGDisplayIOServicePort(displayID);
    return IODisplayGetFloatParameter(service, kNilOptions, CFSTR(kIODisplayBrightnessKey), brightness) == kIOReturnSuccess;
}

- (void)setBrightness:(float)brightness forDisplay:(CGDirectDisplayID)displayID {
    io_service_t service = CGDisplayIOServicePort(displayID);
    IODisplaySetFloatParameter(service, kNilOptions, CFSTR(kIODisplayBrightnessKey), brightness);
}

- (void)movePointerToExternalDisplayIfNeededFromDisplay:(CGDirectDisplayID)builtInDisplayID {
    NSPoint mouseLocation = NSEvent.mouseLocation;
    NSScreen *currentScreen = nil;
    NSScreen *externalScreen = nil;

    for (NSScreen *screen in [NSScreen screens]) {
        NSNumber *screenNumber = screen.deviceDescription[@"NSScreenNumber"];
        if (screenNumber == nil) {
            continue;
        }

        if (NSPointInRect(mouseLocation, screen.frame)) {
            currentScreen = screen;
        }

        if (screenNumber.unsignedIntValue != builtInDisplayID && externalScreen == nil) {
            externalScreen = screen;
        }
    }

    if (currentScreen == nil || externalScreen == nil) {
        return;
    }

    NSNumber *currentScreenNumber = currentScreen.deviceDescription[@"NSScreenNumber"];
    if (currentScreenNumber != nil && currentScreenNumber.unsignedIntValue == builtInDisplayID) {
        CGPoint target = CGPointMake(NSMidX(externalScreen.frame), NSMidY(externalScreen.frame));
        CGWarpMouseCursorPosition(target);
    }
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
