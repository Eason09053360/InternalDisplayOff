#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/graphics/IOGraphicsLib.h>
#import <dlfcn.h>

enum {
    kMaxDisplays = 16
};

typedef int (*DisplayServicesGetBrightnessFunction)(CGDirectDisplayID display, float *brightness);
typedef int (*DisplayServicesSetBrightnessFunction)(CGDirectDisplayID display, float brightness);

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSValue *> *savedDisplayOrigins;
@property(nonatomic, strong) NSWindow *blackoutWindow;
@property(nonatomic, strong) id globalPointerMonitor;
@property(nonatomic, strong) id localPointerMonitor;
@property(nonatomic, assign) CFMachPortRef pointerEventTap;
@property(nonatomic, assign) CFRunLoopSourceRef pointerEventSource;
@property(nonatomic, assign) CGDirectDisplayID builtInDisplayID;
@property(nonatomic, assign) float previousBrightness;
@property(nonatomic, assign) BOOL hasPreviousBrightness;
@property(nonatomic, assign) BOOL hasSavedDisplayArrangement;
@property(nonatomic, assign) BOOL pointerPermissionAlertShown;
@property(nonatomic, assign) BOOL pointerGuardActive;
@property(nonatomic, assign) BOOL pointerGuardRetryScheduled;
@property(nonatomic, assign) BOOL wakeReapplyScheduled;
@property(nonatomic, assign) BOOL wantsInternalDisplayHidden;
@property(nonatomic, assign) NSInteger wakeReapplyAttempts;
- (void)enablePointerEventTap;
- (void)handleDisplayConfigurationChanged;
- (void)handlePointerMovement;
- (void)handleSystemWake:(NSNotification *)notification;
- (BOOL)clampPointerEvent:(CGEventRef)event;
@end

static CGEventRef PointerGuardEventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo) {
    AppDelegate *delegate = (__bridge AppDelegate *)userInfo;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        [delegate enablePointerEventTap];
        return event;
    }

    [delegate clampPointerEvent:event];
    return event;
}

static void DisplayConfigurationCallback(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *userInfo) {
    AppDelegate *delegate = (__bridge AppDelegate *)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate handleDisplayConfigurationChanged];
    });
}

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.builtInDisplayID = kCGNullDirectDisplay;
    CGDisplayRegisterReconfigurationCallback(DisplayConfigurationCallback, (__bridge void *)self);
    NSNotificationCenter *workspaceCenter = [[NSWorkspace sharedWorkspace] notificationCenter];
    [workspaceCenter addObserver:self
                         selector:@selector(handleSystemWake:)
                             name:NSWorkspaceDidWakeNotification
                           object:nil];
    [workspaceCenter addObserver:self
                         selector:@selector(handleSystemWake:)
                             name:NSWorkspaceScreensDidWakeNotification
                           object:nil];
    [self setupStatusItem];
    [self dimAndCoverInternalDisplay:nil];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self restoreInternalDisplay:nil];
    CGDisplayRemoveReconfigurationCallback(DisplayConfigurationCallback, (__bridge void *)self);
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
}

- (void)setupStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"Display Ready";

    NSMenu *menu = [[NSMenu alloc] init];
    [menu addItemWithTitle:@"Dim + Cover Internal Display" action:@selector(dimAndCoverInternalDisplay:) keyEquivalent:@"d"];
    [menu addItemWithTitle:@"Restore Internal Display" action:@selector(restoreInternalDisplay:) keyEquivalent:@"r"];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Open Accessibility Settings" action:@selector(openAccessibilitySettings:) keyEquivalent:@""];
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
    [self arrangeBuiltInDisplayAtUpperRightOfExternalDisplay:builtIn];

    if (self.blackoutWindow == nil && !self.hasPreviousBrightness) {
        float brightness = 1.0f;
        if ([self readBrightness:&brightness forDisplay:builtIn]) {
            self.previousBrightness = brightness;
            self.hasPreviousBrightness = YES;
        }
    }

    BOOL brightnessChanged = [self setBrightness:0.0f forDisplay:builtIn];
    BOOL coverShown = [self showBlackoutWindowOnDisplay:builtIn];
    if (!coverShown) {
        if (brightnessChanged && self.hasPreviousBrightness) {
            [self setBrightness:self.previousBrightness forDisplay:builtIn];
        }
        [self restoreDisplayArrangementIfNeeded];
        self.statusItem.button.title = @"Display Ready";
        [self showAlertWithTitle:@"Could not cover the internal display"
                         message:@"The app found the built-in display, but macOS did not expose a matching screen for the black cover. The display was not hidden."];
        return;
    }

    self.wantsInternalDisplayHidden = YES;
    [self movePointerToExternalDisplayIfNeededFromDisplay:builtIn];
    BOOL pointerGuardReady = [self startPointerGuard];

    if (!pointerGuardReady) {
        self.statusItem.button.title = @"Needs Pointer Permission";
    } else {
        self.statusItem.button.title = brightnessChanged ? @"Internal Hidden" : @"Internal Covered";
    }
}

- (IBAction)restoreInternalDisplay:(id)sender {
    self.wantsInternalDisplayHidden = NO;
    self.wakeReapplyScheduled = NO;
    self.wakeReapplyAttempts = 0;

    [self.blackoutWindow orderOut:nil];
    self.blackoutWindow = nil;
    [self stopPointerGuard];
    [self restoreDisplayArrangementIfNeeded];

    if (self.builtInDisplayID != kCGNullDirectDisplay && self.hasPreviousBrightness) {
        [self setBrightness:MAX(self.previousBrightness, 0.25f) forDisplay:self.builtInDisplayID];
    }

    self.hasPreviousBrightness = NO;
    self.statusItem.button.title = @"Display Ready";
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

- (CGDirectDisplayID)preferredExternalDisplayID {
    CGDirectDisplayID mainDisplay = CGMainDisplayID();
    if (mainDisplay != kCGNullDirectDisplay && !CGDisplayIsBuiltin(mainDisplay)) {
        return mainDisplay;
    }

    CGDisplayCount count = 0;
    CGDirectDisplayID displays[kMaxDisplays] = {0};

    CGError error = CGGetActiveDisplayList(kMaxDisplays, displays, &count);
    if (error != kCGErrorSuccess) {
        return kCGNullDirectDisplay;
    }

    CGDirectDisplayID bestDisplay = kCGNullDirectDisplay;
    CGFloat bestArea = 0.0;

    for (CGDisplayCount index = 0; index < count; index++) {
        CGDirectDisplayID displayID = displays[index];
        if (CGDisplayIsBuiltin(displayID)) {
            continue;
        }

        CGRect bounds = CGDisplayBounds(displayID);
        CGFloat area = CGRectGetWidth(bounds) * CGRectGetHeight(bounds);
        if (bestDisplay == kCGNullDirectDisplay || area > bestArea) {
            bestDisplay = displayID;
            bestArea = area;
        }
    }

    return bestDisplay;
}

- (void)saveDisplayArrangementIfNeeded {
    if (self.hasSavedDisplayArrangement) {
        return;
    }

    CGDisplayCount count = 0;
    CGDirectDisplayID displays[kMaxDisplays] = {0};

    CGError error = CGGetActiveDisplayList(kMaxDisplays, displays, &count);
    if (error != kCGErrorSuccess) {
        return;
    }

    self.savedDisplayOrigins = [NSMutableDictionary dictionary];
    for (CGDisplayCount index = 0; index < count; index++) {
        CGDirectDisplayID displayID = displays[index];
        CGRect bounds = CGDisplayBounds(displayID);
        self.savedDisplayOrigins[@(displayID)] = [NSValue valueWithPoint:NSMakePoint(CGRectGetMinX(bounds),
                                                                                     CGRectGetMinY(bounds))];
    }

    self.hasSavedDisplayArrangement = YES;
}

- (BOOL)arrangeBuiltInDisplayAtUpperRightOfExternalDisplay:(CGDirectDisplayID)builtInDisplayID {
    CGDirectDisplayID externalDisplayID = [self preferredExternalDisplayID];
    if (externalDisplayID == kCGNullDirectDisplay || externalDisplayID == builtInDisplayID) {
        return NO;
    }

    [self saveDisplayArrangementIfNeeded];

    CGRect externalBounds = CGDisplayBounds(externalDisplayID);
    CGRect builtInBounds = CGDisplayBounds(builtInDisplayID);
    int32_t builtInX = (int32_t)lrint(CGRectGetMaxX(externalBounds));
    int32_t builtInY = (int32_t)lrint(CGRectGetMinY(externalBounds) - CGRectGetHeight(builtInBounds));

    CGDisplayConfigRef config = NULL;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess || config == NULL) {
        return NO;
    }

    CGError configureError = CGConfigureDisplayOrigin(config, builtInDisplayID, builtInX, builtInY);
    CGError completeError = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    return configureError == kCGErrorSuccess && completeError == kCGErrorSuccess;
}

- (void)restoreDisplayArrangementIfNeeded {
    if (!self.hasSavedDisplayArrangement || self.savedDisplayOrigins.count == 0) {
        return;
    }

    CGDisplayConfigRef config = NULL;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess || config == NULL) {
        return;
    }

    BOOL configuredAnyDisplay = NO;
    for (NSNumber *displayNumber in self.savedDisplayOrigins) {
        NSValue *originValue = self.savedDisplayOrigins[displayNumber];
        NSPoint origin = originValue.pointValue;
        CGDirectDisplayID displayID = displayNumber.unsignedIntValue;
        if (CGConfigureDisplayOrigin(config, displayID, (int32_t)lrint(origin.x), (int32_t)lrint(origin.y)) == kCGErrorSuccess) {
            configuredAnyDisplay = YES;
        }
    }

    CGError completeError = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    if (configuredAnyDisplay && completeError == kCGErrorSuccess) {
        self.hasSavedDisplayArrangement = NO;
        self.savedDisplayOrigins = nil;
    }
}

- (void)handleDisplayConfigurationChanged {
    BOOL displayIsHidden = self.blackoutWindow != nil;
    if (!displayIsHidden) {
        return;
    }

    if (![self hasActiveExternalDisplay]) {
        if (!self.wakeReapplyScheduled) {
            [self restoreInternalDisplay:nil];
            self.statusItem.button.title = @"Display Restored";
        }
        return;
    }

    if (self.blackoutWindow != nil && self.builtInDisplayID != kCGNullDirectDisplay) {
        [self showBlackoutWindowOnDisplay:self.builtInDisplayID];
        [self movePointerToExternalDisplayIfNeededFromDisplay:self.builtInDisplayID];
    }
}

- (void)handleSystemWake:(NSNotification *)notification {
    if (!self.wantsInternalDisplayHidden || self.wakeReapplyScheduled) {
        return;
    }

    self.wakeReapplyScheduled = YES;
    self.wakeReapplyAttempts = 0;
    [self scheduleWakeReapplyAfterDelay:1.5];
}

- (void)scheduleWakeReapplyAfterDelay:(NSTimeInterval)delay {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self attemptWakeReapply];
    });
}

- (void)attemptWakeReapply {
    if (!self.wantsInternalDisplayHidden) {
        self.wakeReapplyScheduled = NO;
        self.wakeReapplyAttempts = 0;
        return;
    }

    self.wakeReapplyAttempts += 1;

    if ([self hasActiveExternalDisplay]) {
        self.wakeReapplyScheduled = NO;
        self.wakeReapplyAttempts = 0;
        [self dimAndCoverInternalDisplay:nil];
        return;
    }

    if (self.wakeReapplyAttempts < 6) {
        [self scheduleWakeReapplyAfterDelay:1.0];
        return;
    }

    self.wakeReapplyScheduled = NO;
    self.wakeReapplyAttempts = 0;
    [self restoreInternalDisplay:nil];
    self.statusItem.button.title = @"Display Restored";
}

- (BOOL)showBlackoutWindowOnDisplay:(CGDirectDisplayID)displayID {
    NSScreen *targetScreen = nil;
    for (NSScreen *screen in [NSScreen screens]) {
        NSNumber *screenNumber = screen.deviceDescription[@"NSScreenNumber"];
        if (screenNumber != nil && screenNumber.unsignedIntValue == displayID) {
            targetScreen = screen;
            break;
        }
    }

    if (targetScreen == nil) {
        return NO;
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
    [window orderFrontRegardless];
    self.blackoutWindow = window;
    return YES;
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
    CGEventRef currentEvent = CGEventCreate(NULL);
    if (currentEvent == NULL) {
        return;
    }

    CGPoint mouseLocation = CGEventGetLocation(currentEvent);
    CFRelease(currentEvent);
    CGRect externalBounds = [self nearestExternalDisplayBoundsToPoint:mouseLocation excludingDisplay:builtInDisplayID];

    if (CGRectIsNull(externalBounds) || [self pointIsOnExternalDisplay:mouseLocation excludingDisplay:builtInDisplayID]) {
        return;
    }

    CGPoint target = [self safePointInDisplayBounds:externalBounds nearPoint:mouseLocation];
    CGWarpMouseCursorPosition(target);
}

- (BOOL)startPointerGuard {
    [self stopPointerGuard];
    if ([self startPointerEventTap]) {
        self.pointerGuardActive = YES;
        [self movePointerToExternalDisplayIfNeededFromDisplay:self.builtInDisplayID];
        return YES;
    }

    // The event tap could not be created yet (usually missing Accessibility
    // permission). Fall back to best-effort monitors and keep retrying so the
    // guard activates automatically once permission is granted — no relaunch
    // needed.
    self.pointerGuardActive = NO;
    [self startPointerEventMonitors];
    [self schedulePointerGuardRetry];
    if (!self.pointerPermissionAlertShown) {
        self.pointerPermissionAlertShown = YES;
        [self promptForPointerPermission];
    }
    return NO;
}

- (void)schedulePointerGuardRetry {
    if (self.pointerGuardRetryScheduled) {
        return;
    }
    self.pointerGuardRetryScheduled = YES;
    [self schedulePointerGuardRetryTick];
}

- (void)schedulePointerGuardRetryTick {
    __weak AppDelegate *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf attemptPointerGuardRetry];
    });
}

- (void)attemptPointerGuardRetry {
    if (!self.wantsInternalDisplayHidden || self.blackoutWindow == nil) {
        self.pointerGuardRetryScheduled = NO;
        return;
    }

    if (self.pointerGuardActive) {
        self.pointerGuardRetryScheduled = NO;
        return;
    }

    if ([self startPointerEventTap]) {
        // Permission was granted while running; drop the fallback monitors and
        // switch to the authoritative event tap.
        if (self.globalPointerMonitor != nil) {
            [NSEvent removeMonitor:self.globalPointerMonitor];
            self.globalPointerMonitor = nil;
        }
        if (self.localPointerMonitor != nil) {
            [NSEvent removeMonitor:self.localPointerMonitor];
            self.localPointerMonitor = nil;
        }
        self.pointerGuardActive = YES;
        self.pointerGuardRetryScheduled = NO;
        [self movePointerToExternalDisplayIfNeededFromDisplay:self.builtInDisplayID];
        self.statusItem.button.title = @"Internal Hidden";
        return;
    }

    [self schedulePointerGuardRetryTick];
}

- (void)promptForPointerPermission {
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    BOOL trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    if (trusted) {
        // Already trusted — the retry loop will pick up the tap shortly.
        return;
    }

    // A common gotcha with ad-hoc-signed builds: the Accessibility toggle can
    // still appear ON in the list, but it points at a previous build's code
    // signature. Rebuilding changes the signature, so macOS treats it as a
    // different app and the stale grant no longer applies.
    [self showAlertWithTitle:@"Pointer guard needs permission"
                     message:@"Grant this app Accessibility permission in System Settings ▸ Privacy & Security ▸ Accessibility. The pointer guard turns on automatically once you do — no relaunch needed.\n\nIf the app already appears with its switch ON but this message keeps showing, the grant is stale from an earlier build: select it in the list, remove it with the “−” button, then relaunch and grant again (or run “tccutil reset Accessibility local.codex.InternalDisplayOff” in Terminal)."];
}

- (IBAction)openAccessibilitySettings:(id)sender {
    NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
    if (url != nil) {
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
}

- (void)stopPointerGuard {
    self.pointerGuardActive = NO;
    self.pointerGuardRetryScheduled = NO;
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
    self.pointerEventTap = CGEventTapCreate(kCGHIDEventTap,
                                            kCGHeadInsertEventTap,
                                            kCGEventTapOptionDefault,
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

- (BOOL)clampPointerEvent:(CGEventRef)event {
    if (self.builtInDisplayID == kCGNullDirectDisplay || self.blackoutWindow == nil) {
        return NO;
    }

    CGPoint location = CGEventGetLocation(event);
    if ([self pointIsOnExternalDisplay:location excludingDisplay:self.builtInDisplayID]) {
        return NO;
    }

    CGRect bounds = [self nearestExternalDisplayBoundsToPoint:location excludingDisplay:self.builtInDisplayID];
    if (CGRectIsNull(bounds)) {
        return NO;
    }

    CGPoint clampedLocation = [self safePointInDisplayBounds:bounds nearPoint:location];
    CGEventSetLocation(event, clampedLocation);
    CGWarpMouseCursorPosition(clampedLocation);
    return YES;
}

- (CGRect)nearestExternalDisplayBoundsToPoint:(CGPoint)point excludingDisplay:(CGDirectDisplayID)builtInDisplayID {
    CGRect nearestBounds = CGRectNull;
    CGFloat nearestDistance = CGFLOAT_MAX;
    CGDisplayCount count = 0;
    CGDirectDisplayID displays[kMaxDisplays] = {0};

    CGError error = CGGetActiveDisplayList(kMaxDisplays, displays, &count);
    if (error != kCGErrorSuccess) {
        return CGRectNull;
    }

    for (CGDisplayCount index = 0; index < count; index++) {
        CGDirectDisplayID displayID = displays[index];
        if (displayID == builtInDisplayID || CGDisplayIsBuiltin(displayID)) {
            continue;
        }

        CGRect bounds = CGDisplayBounds(displayID);
        CGPoint clampedPoint = CGPointMake(MIN(MAX(point.x, CGRectGetMinX(bounds)), CGRectGetMaxX(bounds)),
                                           MIN(MAX(point.y, CGRectGetMinY(bounds)), CGRectGetMaxY(bounds)));
        CGFloat dx = point.x - clampedPoint.x;
        CGFloat dy = point.y - clampedPoint.y;
        CGFloat distance = dx * dx + dy * dy;

        if (distance < nearestDistance) {
            nearestDistance = distance;
            nearestBounds = bounds;
        }
    }

    return nearestBounds;
}

- (BOOL)pointIsOnExternalDisplay:(CGPoint)point excludingDisplay:(CGDirectDisplayID)builtInDisplayID {
    CGDisplayCount count = 0;
    CGDirectDisplayID displays[kMaxDisplays] = {0};

    CGError error = CGGetActiveDisplayList(kMaxDisplays, displays, &count);
    if (error != kCGErrorSuccess) {
        return NO;
    }

    for (CGDisplayCount index = 0; index < count; index++) {
        CGDirectDisplayID displayID = displays[index];
        if (displayID == builtInDisplayID || CGDisplayIsBuiltin(displayID)) {
            continue;
        }

        if (CGRectContainsPoint(CGDisplayBounds(displayID), point)) {
            return YES;
        }
    }

    return NO;
}

- (CGPoint)safePointInDisplayBounds:(CGRect)bounds nearPoint:(CGPoint)point {
    CGFloat inset = 1.0;
    CGRect frame = CGRectInset(bounds, inset, inset);
    CGFloat x = MIN(MAX(point.x, CGRectGetMinX(frame)), CGRectGetMaxX(frame));
    CGFloat y = MIN(MAX(point.y, CGRectGetMinY(frame)), CGRectGetMaxY(frame));
    return CGPointMake(x, y);
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
