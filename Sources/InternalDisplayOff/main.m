#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/graphics/IOGraphicsLib.h>
#import <dlfcn.h>

extern CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef config, CGDirectDisplayID display, bool enabled);

enum {
    kMaxDisplays = 16
};

typedef int (*DisplayServicesGetBrightnessFunction)(CGDirectDisplayID display, float *brightness);
typedef int (*DisplayServicesSetBrightnessFunction)(CGDirectDisplayID display, float brightness);

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSWindow *blackoutWindow;
@property(nonatomic, strong) id globalPointerMonitor;
@property(nonatomic, strong) id localPointerMonitor;
@property(nonatomic, assign) CFMachPortRef pointerEventTap;
@property(nonatomic, assign) CFRunLoopSourceRef pointerEventSource;
@property(nonatomic, assign) CGDirectDisplayID builtInDisplayID;
@property(nonatomic, assign) float previousBrightness;
@property(nonatomic, assign) BOOL hasPreviousBrightness;
@property(nonatomic, assign) BOOL hardDisabled;
- (void)enablePointerEventTap;
- (void)handlePointerMovement;
@end

static CGEventRef PointerGuardEventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo) {
    AppDelegate *delegate = (__bridge AppDelegate *)userInfo;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        [delegate enablePointerEventTap];
        return event;
    }

    [delegate handlePointerMovement];
    return event;
}

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
    [self startPointerGuard];

    self.statusItem.button.title = @"Internal Dimmed";
}

- (IBAction)restoreInternalDisplay:(id)sender {
    if (self.hardDisabled && self.builtInDisplayID != kCGNullDirectDisplay) {
        [self setDisplay:self.builtInDisplayID enabled:true];
        self.hardDisabled = NO;
    }

    [self.blackoutWindow orderOut:nil];
    self.blackoutWindow = nil;
    [self stopPointerGuard];

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
    void *handle = [self displayServicesHandle];
    if (handle != NULL) {
        DisplayServicesGetBrightnessFunction getBrightness = (DisplayServicesGetBrightnessFunction)dlsym(handle, "DisplayServicesGetBrightness");
        if (getBrightness != NULL && getBrightness(displayID, brightness) == 0) {
            return YES;
        }
    }

    io_service_t service = CGDisplayIOServicePort(displayID);
    return IODisplayGetFloatParameter(service, kNilOptions, CFSTR(kIODisplayBrightnessKey), brightness) == kIOReturnSuccess;
}

- (BOOL)setBrightness:(float)brightness forDisplay:(CGDirectDisplayID)displayID {
    void *handle = [self displayServicesHandle];
    if (handle != NULL) {
        DisplayServicesSetBrightnessFunction setBrightness = (DisplayServicesSetBrightnessFunction)dlsym(handle, "DisplayServicesSetBrightness");
        if (setBrightness != NULL && setBrightness(displayID, brightness) == 0) {
            return YES;
        }
    }

    io_service_t service = CGDisplayIOServicePort(displayID);
    return IODisplaySetFloatParameter(service, kNilOptions, CFSTR(kIODisplayBrightnessKey), brightness) == kIOReturnSuccess;
}

- (void *)displayServicesHandle {
    static void *handle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY);
        if (handle == NULL) {
            handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/A/DisplayServices", RTLD_LAZY);
        }
    });
    return handle;
}

- (void)movePointerToExternalDisplayIfNeededFromDisplay:(CGDirectDisplayID)builtInDisplayID {
    NSPoint mouseLocation = NSEvent.mouseLocation;
    NSScreen *currentScreen = nil;
    NSScreen *externalScreen = [self nearestExternalScreenToPoint:mouseLocation excludingDisplay:builtInDisplayID];

    for (NSScreen *screen in [NSScreen screens]) {
        NSNumber *screenNumber = screen.deviceDescription[@"NSScreenNumber"];
        if (screenNumber == nil) {
            continue;
        }

        if (NSPointInRect(mouseLocation, screen.frame)) {
            currentScreen = screen;
        }
    }

    if (currentScreen == nil || externalScreen == nil) {
        return;
    }

    NSNumber *currentScreenNumber = currentScreen.deviceDescription[@"NSScreenNumber"];
    if (currentScreenNumber != nil && currentScreenNumber.unsignedIntValue == builtInDisplayID) {
        CGPoint target = [self safePointOnScreen:externalScreen nearPoint:mouseLocation];
        CGWarpMouseCursorPosition(target);
    }
}

- (void)startPointerGuard {
    [self stopPointerGuard];
    if (![self startPointerEventTap]) {
        [self startPointerEventMonitors];
    }
    [self movePointerToExternalDisplayIfNeededFromDisplay:self.builtInDisplayID];
}

- (void)stopPointerGuard {
    if (self.pointerEventTap != NULL) {
        CFMachPortInvalidate(self.pointerEventTap);
        CFRelease(self.pointerEventTap);
        self.pointerEventTap = NULL;
    }

    if (self.pointerEventSource != NULL) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), self.pointerEventSource, kCFRunLoopCommonModes);
        CFRelease(self.pointerEventSource);
        self.pointerEventSource = NULL;
    }

    if (self.globalPointerMonitor != nil) {
        [NSEvent removeMonitor:self.globalPointerMonitor];
        self.globalPointerMonitor = nil;
    }

    if (self.localPointerMonitor != nil) {
        [NSEvent removeMonitor:self.localPointerMonitor];
        self.localPointerMonitor = nil;
    }
}

- (BOOL)startPointerEventTap {
    CGEventMask mask = CGEventMaskBit(kCGEventMouseMoved) |
                       CGEventMaskBit(kCGEventLeftMouseDragged) |
                       CGEventMaskBit(kCGEventRightMouseDragged) |
                       CGEventMaskBit(kCGEventOtherMouseDragged);
    self.pointerEventTap = CGEventTapCreate(kCGSessionEventTap,
                                            kCGHeadInsertEventTap,
                                            kCGEventTapOptionListenOnly,
                                            mask,
                                            PointerGuardEventCallback,
                                            (__bridge void *)self);
    if (self.pointerEventTap == NULL) {
        return NO;
    }

    self.pointerEventSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, self.pointerEventTap, 0);
    if (self.pointerEventSource == NULL) {
        CFMachPortInvalidate(self.pointerEventTap);
        CFRelease(self.pointerEventTap);
        self.pointerEventTap = NULL;
        return NO;
    }

    CFRunLoopAddSource(CFRunLoopGetMain(), self.pointerEventSource, kCFRunLoopCommonModes);
    [self enablePointerEventTap];
    return YES;
}

- (void)enablePointerEventTap {
    if (self.pointerEventTap != NULL) {
        CGEventTapEnable(self.pointerEventTap, true);
    }
}

- (void)startPointerEventMonitors {
    NSEventMask mask = NSEventMaskMouseMoved |
                       NSEventMaskLeftMouseDragged |
                       NSEventMaskRightMouseDragged |
                       NSEventMaskOtherMouseDragged;
    __weak AppDelegate *weakSelf = self;
    self.globalPointerMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:mask handler:^(NSEvent *event) {
        [weakSelf handlePointerMovement];
    }];
    self.localPointerMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent *(NSEvent *event) {
        [weakSelf handlePointerMovement];
        return event;
    }];
}

- (void)handlePointerMovement {
    if (self.builtInDisplayID == kCGNullDirectDisplay || self.blackoutWindow == nil) {
        return;
    }

    [self movePointerToExternalDisplayIfNeededFromDisplay:self.builtInDisplayID];
}

- (NSScreen *)nearestExternalScreenToPoint:(NSPoint)point excludingDisplay:(CGDirectDisplayID)builtInDisplayID {
    NSScreen *nearestScreen = nil;
    CGFloat nearestDistance = CGFLOAT_MAX;

    for (NSScreen *screen in [NSScreen screens]) {
        NSNumber *screenNumber = screen.deviceDescription[@"NSScreenNumber"];
        if (screenNumber == nil || screenNumber.unsignedIntValue == builtInDisplayID) {
            continue;
        }

        NSPoint clampedPoint = NSMakePoint(MIN(MAX(point.x, NSMinX(screen.frame)), NSMaxX(screen.frame)),
                                           MIN(MAX(point.y, NSMinY(screen.frame)), NSMaxY(screen.frame)));
        CGFloat dx = point.x - clampedPoint.x;
        CGFloat dy = point.y - clampedPoint.y;
        CGFloat distance = dx * dx + dy * dy;

        if (distance < nearestDistance) {
            nearestDistance = distance;
            nearestScreen = screen;
        }
    }

    return nearestScreen;
}

- (CGPoint)safePointOnScreen:(NSScreen *)screen nearPoint:(NSPoint)point {
    CGFloat inset = 8.0;
    NSRect frame = NSInsetRect(screen.frame, inset, inset);
    CGFloat x = MIN(MAX(point.x, NSMinX(frame)), NSMaxX(frame));
    CGFloat y = MIN(MAX(point.y, NSMinY(frame)), NSMaxY(frame));
    return CGPointMake(x, y);
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
