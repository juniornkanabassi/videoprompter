// Every window a test orders in stays invisible, and nothing a test does activates the test process,
// so `swift test`, test.sh and the snapshot checks never appear on Junior's screens, take focus or beep.
// Windows are still ordered in (isVisible, layout, hit tests and offscreen rendering all work); they are
// just fully transparent and let clicks through. Runs when the test bundle loads, before any test.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>
#import "TestOffscreen.h"

void TestOffscreenInstalled(void) {}

static void swap(Class type, SEL original, SEL replacement) {
  Method old = class_getInstanceMethod(type, original), new = class_getInstanceMethod(type, replacement);
  if (!old || !new) return;
  if (class_addMethod(type, original, method_getImplementation(new), method_getTypeEncoding(new)))
    class_replaceMethod(type, replacement, method_getImplementation(old), method_getTypeEncoding(old));
  else
    method_exchangeImplementations(old, new);
}

@implementation NSWindow (TestOffscreen)
- (void)testOffscreen_hide { [self testOffscreen_setAlphaValue:0]; self.ignoresMouseEvents = YES; }
- (void)testOffscreen_setAlphaValue:(CGFloat)value { [self testOffscreen_setAlphaValue:0]; }
- (void)testOffscreen_orderWindow:(NSWindowOrderingMode)mode relativeTo:(NSInteger)other {
  [self testOffscreen_hide]; [self testOffscreen_orderWindow:mode relativeTo:other];
}
- (void)testOffscreen_orderFront:(id)sender { [self testOffscreen_hide]; [self testOffscreen_orderFront:sender]; }
- (void)testOffscreen_orderFrontRegardless { [self testOffscreen_hide]; [self testOffscreen_orderFrontRegardless]; }
- (void)testOffscreen_makeKeyAndOrderFront:(id)sender { [self testOffscreen_hide]; [self testOffscreen_makeKeyAndOrderFront:sender]; }
@end

@implementation NSResponder (TestOffscreen)
// An unhandled key press ends here and plays the system alert sound; tests must stay silent.
- (void)testOffscreen_noResponderFor:(SEL)eventSelector {}
@end

@implementation NSApplication (TestOffscreen)
- (void)testOffscreen_activateIgnoringOtherApps:(BOOL)flag {}
- (void)testOffscreen_activate {}
@end

// Last line of defence for tests that bypass the Swift helper. Never ask or open a real device.
@implementation AVCaptureDevice (TestOffscreen)
+ (void)testOffscreen_requestAccessForMediaType:(AVMediaType)mediaType completionHandler:(void (^)(BOOL))handler {
  handler(NO);
}
@end

@implementation AVCaptureDeviceInput (TestOffscreen)
- (instancetype)testOffscreen_initWithDevice:(AVCaptureDevice *)device error:(NSError **)error {
  if (error) *error = [NSError errorWithDomain:AVFoundationErrorDomain code:AVErrorApplicationIsNotAuthorizedToUseDevice userInfo:nil];
  return nil;
}
@end

static IMP blockedAccess, blockedInput;
int TestOffscreenCaptureGuardsInstalled(void) {
  return blockedAccess && blockedInput
    && method_getImplementation(class_getClassMethod(AVCaptureDevice.class, @selector(requestAccessForMediaType:completionHandler:))) == blockedAccess
    && method_getImplementation(class_getInstanceMethod(AVCaptureDeviceInput.class, @selector(initWithDevice:error:))) == blockedInput;
}

__attribute__((constructor)) static void installTestOffscreen(void) {
  blockedAccess = method_getImplementation(class_getClassMethod(AVCaptureDevice.class, @selector(testOffscreen_requestAccessForMediaType:completionHandler:)));
  blockedInput = method_getImplementation(class_getInstanceMethod(AVCaptureDeviceInput.class, @selector(testOffscreen_initWithDevice:error:)));
  swap(object_getClass(AVCaptureDevice.class), @selector(requestAccessForMediaType:completionHandler:), @selector(testOffscreen_requestAccessForMediaType:completionHandler:));
  swap(AVCaptureDeviceInput.class, @selector(initWithDevice:error:), @selector(testOffscreen_initWithDevice:error:));
  Class window = NSWindow.class, app = NSApplication.class;
  swap(window, @selector(setAlphaValue:), @selector(testOffscreen_setAlphaValue:));
  swap(window, @selector(orderWindow:relativeTo:), @selector(testOffscreen_orderWindow:relativeTo:));
  swap(window, @selector(orderFront:), @selector(testOffscreen_orderFront:));
  swap(window, @selector(orderFrontRegardless), @selector(testOffscreen_orderFrontRegardless));
  swap(window, @selector(makeKeyAndOrderFront:), @selector(testOffscreen_makeKeyAndOrderFront:));
  swap(NSResponder.class, @selector(noResponderFor:), @selector(testOffscreen_noResponderFor:));
  swap(app, @selector(activateIgnoringOtherApps:), @selector(testOffscreen_activateIgnoringOtherApps:));
  swap(app, @selector(activate), @selector(testOffscreen_activate));
}
