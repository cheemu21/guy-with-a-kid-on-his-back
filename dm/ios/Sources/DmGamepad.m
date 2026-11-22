// Virtual gamepad (Nintendo button positions) + physical controllers (GameController), handed to the host through dm_input_set and dm_pad_set_player (hle_hid.c, bit layout in dm_input.h).
//   Two layouts, three in handheld mode, picked in the in-game menu (GameMenu.swift) that the menu button at the top centre (a gear) opens; the choice is kept in NSUserDefaults (each game is its own app, so per game); the first launch uses the game profile's pad_layout (DM_GAME_PAD_LAYOUT).
//   The menu button stays while a physical controller is connected, so the menu is there in every layout and with every controller.
//   Tap (touch): no control but the menu button, every other touch goes to the game's local touch viewport; offered only while the game is in handheld mode, the only one in which it reads the touch screen (Balatro, played by touch).
//   2D (simple): top corners ZL above L (one column), ZR above R likewise, teardrops with the tip toward the screen corner; − and + side by side at the top centre; the left stick in the bottom-left corner (fixed ring, tilt measured from the ring centre, small dead zone);
//     the A (right) B (bottom) X (top) Y (left) diamond in the bottom-right corner, sliding a finger between keys switches keys. Each bottom corner holds a single control, so it sits close in (reaching halfway into the side safe-area inset).
//   3D (full, Pro Controller style): everything in 2D (left stick and diamond keep their place and size), plus a D-pad (inward of and below the left stick, 8-way), a right stick that is not drawn
//     (a touch landing in the right third of the screen on no control holds it: centred where it lands, the centre dragged along once the finger passes the stick radius) and L3 / R3 (small round keys in the top row, inward of ZL / ZR).
//     Breath of the Wild crouches with L3 and uses the scope with R3; 3D World and Breath of the Wild turn the camera with the right stick.
//   Touch-down ownership: the menu button where it is nearer than a locked key (a view of its own, DmMenuButton), locked keys next (shoulders, − / +, L3 / R3), then whichever of the diamond, the D-pad and the left stick has the smallest distance / grab radius (the left stick's grab circle borders the D-pad),
//     then in 3D the right stick for a touch in the right third.
//   Everything hugs the edges and corners to leave the picture room; controls sit over the picture, one CAShapeLayer each: a press only swaps the fill, a stick only moves its knob, nothing redraws the whole screen.
//   Touches no control takes (in 3D, those outside the right third) go to the game's touch screen when DmLayout assigns a local game viewport (pushGame; Super Mario Galaxy's pointer in handheld mode).
//   The virtual gamepad (all but the menu button) hides while a physical controller is connected and comes back when it is removed; unclaimed touches go to the game only when a local game viewport exists. Physical controllers keep every button (D-pad and right stick included) and map by position: bottom = B, right = A, left = Y, top = X (same positions as on a Switch controller); a Nintendo pad maps by its labels (pad_apple.h).
//   Each physical controller is a player of its own (local co-op), as on the Mac: the first one connected is player 1, together with the touch gamepad, the next player 2, and so on up to 8; see "Physical controllers" below.
//   Shaking the phone shakes the controller (DM_BTN_SHAKE: its six-axis sensor, hle_hid.c), whichever controls are in use; see "Shaking the phone" below.
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreText/CoreText.h>
#include <pthread.h>
#include "dm.h"
#include "dm_input.h"
#include "front.h"
#include "game_profile.h"
#include "haptics_apple.h"
#include "motion_apple.h"
#include "motion_fusion.h"
#include "pad_apple.h"
#include "pad_slots.h"
#include "ctrl_prompt.h"
#include <stdatomic.h>
#import "DmLayout.h"
#import "DmGameMenu.h"

enum { B_A = 0, B_B, B_X, B_Y, B_LS, B_RS, B_L, B_R, B_ZL, B_ZR, B_PLUS, B_MINUS, B_LEFT, B_UP, B_RIGHT, B_DOWN, B_N };
enum { C_NONE = 0, C_STICK, C_DPAD, C_FACE, C_BTN, C_GAME,   // which control a touch holds; C_GAME: none, the touch goes to the game's touch screen (finger slot << 8)
       C_ZL, C_HUB, C_ZLOFF, C_FIRE2 };   // Orbit: the ZL pad (held, or locked on by a short tap), the ZR hub (also the right stick), the tap that lets a locked ZL go (presses nothing),
                                          // the second fire key (ZR only, shown while ZL is on)

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_touch_btn, g_shake_btn;
static int32_t g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry;
static void publish(void) {   // the touch gamepad and the shake; the host ORs them with player 1's controller and takes whichever stick is deflected more (hle_hid.c)
    pthread_mutex_lock(&g_mu);
    dm_input_set(g_touch_btn | g_shake_btn, g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry);
    pthread_mutex_unlock(&g_mu);
}

// ---- Shaking the phone ----
// The accelerometer at 60 Hz (no gyroscope, no permission prompt): gravity is followed by a slow low-pass (about 0.8 s), and a sample whose acceleration beyond it exceeds DM_SHAKE_G
// (1.5 G by default; Documents/env.txt overrides) is a hit. The controller is shaken until 120 ms after the last hit: a flick is one shake (the host finishes it as a whole cycle)
// and shaking on keeps it going. Holding the phone and pressing the screen stays far below the threshold. Each detected shake is logged with its peak
static CMMotionManager *g_motion;
static void motion_start(void) {
    if (g_motion) return;
    g_motion = [CMMotionManager new];
    if (!g_motion.accelerometerAvailable) { LOG("front end: no accelerometer, shaking the phone does nothing"); return; }
    const char *e = getenv("DM_SHAKE_G"); double thr = e && atof(e) > 0 ? atof(e) : 1.5;
    LOG("front end: shaking the phone shakes the controller (threshold %.2f G)", thr);
    g_motion.accelerometerUpdateInterval = 1.0 / 60;
    NSOperationQueue *q = [NSOperationQueue new]; q.maxConcurrentOperationCount = 1;
    __block double gx = 0, gy = 0, gz = 0, last = -1, peak = 0; __block BOOL init = NO;
    [g_motion startAccelerometerUpdatesToQueue:q withHandler:^(CMAccelerometerData *d, NSError *err) {
        (void)err; if (!d) return;
        CMAcceleration a = d.acceleration;
        if (!init) { gx = a.x; gy = a.y; gz = a.z; init = YES; }
        double dx = a.x - gx, dy = a.y - gy, dz = a.z - gz, g = sqrt(dx * dx + dy * dy + dz * dz);
        gx += (a.x - gx) * 0.02; gy += (a.y - gy) * 0.02; gz += (a.z - gz) * 0.02;
        if (g > thr) { if (last < 0) peak = 0; last = d.timestamp; peak = fmax(peak, g); }
        BOOL on = last >= 0 && d.timestamp - last < 0.12;
        if (!on && last >= 0) { LOG("front end: phone shaken (peak %.1f G)", peak); last = -1; }
        uint64_t want = on ? DM_BTN_SHAKE : 0;
        pthread_mutex_lock(&g_mu); BOOL changed = g_shake_btn != want; g_shake_btn = want; pthread_mutex_unlock(&g_mu);
        if (changed) publish();
    }];
}

// ---- The phone's gyro ----
// A controller mounted on the phone (Backbone One, Razer Kishi, GameSir G8) has no motion sensors of its own: the phone in the middle is the console, as a Switch in handheld.
// So the phone's device motion (gyro + accelerometer, CoreMotion's fused gravity and user acceleration, 100 Hz, no permission prompt) drives player 1's six-axis sensor, turned
// into the Switch frame for the screen's orientation (motion_phone_to_switch, motion_fusion.h): x to the right of the picture, y to its top, z toward the player.
// The host keeps phone and controller orientations separately, choosing fresh controller data in auto mode and the phone alone in forced mode.
// DM_PHONE_MOTION: auto (default) while no controller supplies fresh gyro data (a DualSense held apart from the phone uses its own, motion_apple.h), 1 always, 0 never.
// DM_MOTION=0 (all live motion off; the NSP script's --no-motion builds it in) never starts device motion.
// Which frame the samples come in: on iOS 27 and later the pad view (full screen, over the picture) is the motion body (CMMotionManager.deviceMotionBody), so Core Motion delivers
// them in that view's frame for whichever display shows it and however it is turned: x to the right of the picture, y to its top, z toward the player, the Switch frame as it is.
// Before that they come in the hardware frame, turned here by the interface orientation, which holds only where the hardware frame is the screen's portrait frame: not on iPhone
// Duo's inner display, whose picture is a quarter turn from it (up / down and left / right swapped, GitHub issue #569). Open: while the scene is not full screen (Split View on the
// inner display) Core Motion falls back to the hardware frame without saying so, and the samples are then taken as the view's frame
static _Atomic int g_iface_orient = 3;      // UIInterfaceOrientation, updated on layout
static BOOL g_motion_body;                  // samples in the body's frame (iOS 27+)
static void phone_motion_start(UIView *body) {
    const char *e = getenv("DM_MOTION");
    if (e && !atoi(e)) { LOG("front end: motion is off (DM_MOTION=0), the phone's gyro is not used"); return; }
    e = getenv("DM_PHONE_MOTION"); int mode = !e || !strcmp(e, "auto") ? -1 : atoi(e);
    if (!mode) { LOG("front end: the phone's gyro is off (DM_PHONE_MOTION=0)"); return; }
    if (!g_motion.deviceMotionAvailable) { LOG("front end: no device motion, the phone's gyro is not used"); return; }
    LOG("front end: the phone's gyro drives the controller's six-axis sensor %s", mode < 0 ? "while no controller supplies fresh motion" : "always (DM_PHONE_MOTION=1)");
    g_motion.deviceMotionUpdateInterval = 1.0 / 100;
    if (@available(iOS 27.0, *)) { g_motion.deviceMotionBody = body; g_motion_body = YES; LOG("front end: the phone's motion comes in the pad view's frame (deviceMotionBody)"); }
    NSOperationQueue *q = [NSOperationQueue new]; q.maxConcurrentOperationCount = 1;
    [g_motion startDeviceMotionUpdatesToQueue:q withHandler:^(CMDeviceMotion *d, NSError *err) {
        (void)err; if (!d) return;
        float a[3] = {(float)(d.gravity.x + d.userAcceleration.x), (float)(d.gravity.y + d.userAcceleration.y), (float)(d.gravity.z + d.userAcceleration.z)};
        float w[3] = {(float)d.rotationRate.x, (float)d.rotationRate.y, (float)d.rotationRate.z}, as[3], ws[3];
        int o = g_motion_body ? 1 : atomic_load(&g_iface_orient);   // the body's frame is already the picture's: the portrait map, which leaves it as it is
        motion_phone_to_switch(o, a, as); motion_phone_to_switch(o, w, ws);
        dm_motion_set_switch(0, as, ws);
    }];
}

// ---- Layout constants (in u; x measured from the outer edge, the right half mirrors) ----
static const CGFloat
    K_ZL_X = 44, K_ZL_Y = 40, K_ZL_R = 26,          // ZL / ZR: centre from the outer edge and the top, radius
    K_L_X = 44, K_L_Y = 108, K_L_R = 24,            // L / R: same column as ZL / ZR
    K_DROP_TIP = 1.45,                              // teardrop tip distance from the centre (times the radius)
    K_CORNER_IN = 0.5,                              // how far the bottom-corner controls reach into the side safe-area inset (in landscape there is only the rounded screen corner there; the Dynamic Island is mid-edge)
    K_FACE_X = 81, K_PAD_Y = 82,                    // diamond centre from the outer edge; diamond and stick centre from the bottom (B's lower edge about 5 above it)
    K_FACE_GAP = 50, K_FACE_R = 27,                 // diamond: key distance from the centre, key radius
    K_PILL_DX = 52, K_PILL_Y = 22, K_PILL_W = 50, K_PILL_H = 28,   // − / +: centre from the screen's midline (the middle goes to the layout button) and from the top, size
    K_MENU_R = 15,                                  // menu button: top centre, level with − / +; it takes a touch within 1.6 times this (at least 22 points, half of a 44-point target)
    K_STICK_X = 81, K_STICK_R = 77, K_KNOB_R = 30,  // left stick: mirrors the diamond, the ring as large as the whole diamond (key distance + key radius), the knob a little larger than a diamond key
    K_STICK_GRAB = 1.4,                             // how near the ring centre a touch-down grabs a stick (times the ring radius)
    K_FULL = 0.8,                                   // full tilt at this fraction of the ring radius (the knob still travels to the ring edge)
    K_DEAD = 0.1,                                   // stick dead zone (times the ring radius)
    // controls only the 3D layout has
    K_LOW_X = 231, K_LOW_Y = 64,                    // D-pad centre from the outer edge and the bottom (inward of and below the left stick, as on a Pro Controller)
    K_DPAD_R = 48, K_ARM_W = 17, K_ARM_IN = 11,     // D-pad: arm outer edge from the centre, half-width, tip from the centre
    K_DPAD_GRAB = 1.3,                              // D-pad grab radius (times the outer edge)
    K_RSTICK_R = 60,                                // right stick (not drawn): radius around its centre, the touch-down point
    K_RSWIPE = 1.0 / 3,                             // right stick area: this fraction of the screen width from the right edge (not in u)
    K_CLICK_X = 102, K_CLICK_R = 17;                // L3 / R3: centre from the outer edge (level with ZL / ZR), radius
static const int k_btns[] = {B_ZL, B_L, B_ZR, B_R, B_MINUS, B_PLUS, B_LS, B_RS};   // keys locked at touch-down (L3 / R3 only in the 3D layout)
static NSString *const k_layout_key = @"DmPadLayout";   // NSUserDefaults: 0 = 2D, 1 = 3D, 2 = Tap (DM_GAME_PAD_LAYOUT's numbers)
int dm_opmode(void);   // hle_oe.c: 0 = handheld

@interface DmGamepad : UIView
- (void)arrange:(DmLayout)layout;
- (BOOL)menuTakes:(CGPoint)p;
@end
// The menu button: a UIButton whose menu is the in-game menu (UIKit draws it and takes the touches while it is open). Its hit circle is larger than the drawn one, and a key nearer
// to the touch wins (− / + sit beside it), so it asks the pad
@interface DmMenuButton : UIButton
@end
@implementation DmMenuButton
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e { DmGamepad *pad = (DmGamepad *)self.superview; return [pad menuTakes:[self convertPoint:p toView:pad]]; }
@end
static __weak DmGamepad *g_view;
static void pads_start(void);   // Physical controllers, below

@implementation DmGamepad {
    NSMapTable<UITouch *, NSNumber *> *_owner;     // touch → control (with the key for C_BTN or the stick for C_STICK, << 8)
    UITouch *_stick[2]; CGPoint _stickNow[2];      // the touch holding each stick and where it is now (0 left, 1 right)
    CGPoint _rCentre;                              // the right stick's centre: where its touch landed, dragged along past K_RSTICK_R
    uint64_t _faceBits, _dpadBits, _btnBits;
    NSMapTable<UITouch *, NSNumber *> *_faceOf;    // which keys each touch on the diamond currently holds
    CAShapeLayer *_key[B_N]; CATextLayer *_label[B_N];   // one layer per key
    CAShapeLayer *_ring, *_knob;                   // the left stick (the right one is not drawn)
    CAShapeLayer *_knobIn;                         // the knob's inner shape: a ring in the classic look, the grip dots in Orbit's (held here: Orbit adds other sublayers to the knob)
    DmMenuButton *_menu;                           // opens the in-game menu (GameMenu.swift)
    UIImpactFeedbackGenerator *_touchFeedback;       // one short feedback per touch-control press edge
    unsigned _hapticSticks;
    BOOL _stickShown;                              // the left stick was held at the last refresh
    BOOL _full, _tap;                              // the 3D layout / the Tap layout is current
    CALayer *_controls;                            // holds every control layer: hidden while a physical controller is connected (the view itself stays, for game touches)
    BOOL _padOff;                                  // a physical controller is connected: every touch goes to the game
    DmLayout _layout;
    UITouch *_game[16];                            // touches on the game's touch screen by finger slot
    // The Orbit layout (profile touch_style orbit, DM_GAME_TOUCH_STYLE; see "Orbit" below)
    CAShapeLayer *_icon[B_N + 2], *_tag[B_N + 2], *_arrow[4];   // line icon and letter tag per key (B_N: the Overdrive key, B_N + 1: the second fire key); the face keys' cursor arrows in hacking mode
    CAShapeLayer *_od; CATextLayer *_odLabel;      // the Overdrive key (LS + RS)
    CAShapeLayer *_fire2; CATextLayer *_fire2Label;   // the second fire key (ZR), top left, shown while ZL is on
    CAGradientLayer *_knobShade; CAShapeLayer *_knobShadeMask, *_knobLip;   // the knob's nub look: concave shading (masked to the knob), the lip near its edge; its grip dots are the knob's first sublayer
    CAShapeLayer *_dpadGuide, *_dchev[4];          // the D-pad's faint circle and its arms' chevrons (left, up, right, down: B_LEFT order)
    CATextLayer *_lockHint;
    BOOL _zlLocked; double _zlDown; UITouch *_zlTouch;   // ZL locked on by a short tap; the touch pressing it and when it came down
    UITouch *_hubAim;                              // the ZR hub's touch, which drives the right stick from where it landed
    UITouch *_rsTouch; double _lookTap; CGPoint _lookTapAt;   // a double tap in the aim area holds RS; the last tap there
    CGPoint _lCentre;                              // the floating left stick's centre while held
    NSTimer *_dim; BOOL _dimmed;                   // auto-dim
}

static UIColor *k_idle, *k_on, *k_line, *k_ringFill, *k_text, *k_textOn;
static UIColor *k_badge, *k_micro, *k_onLine, *k_accent, *k_capFill;   // the Orbit look's other colours: tag fill, hint text, pressed outline, PRAGMATA's blue, the knob's cap
static UIColor *k_stickLine, *k_guide;   // Orbit's stick rim; the D-pad's faint circle (unused since V23)
// The stick as the Ocarina of Time port draws it (kid-with-sword-remake L8.1, Native layout, the player's choice): a faint white ring and a plain translucent white knob, brighter while
// held, each with a thin white outline and a soft shadow; no grip dots, shading or lip
static UIColor *k_okRing, *k_okLine, *k_okKnob, *k_okKnobOn;
static CAShapeLayer *shape(CALayer *parent) {
    CAShapeLayer *l = [CAShapeLayer layer];
    l.fillColor = k_idle.CGColor; l.strokeColor = k_line.CGColor; l.lineWidth = 1.5;
    if (DM_GAME_TOUCH_STYLE) l.shadowColor = k_accent.CGColor;   // Orbit: no drop shadow; a blue glow while pressed (refresh)
    else { l.shadowColor = UIColor.blackColor.CGColor; l.shadowOpacity = 0.2; l.shadowRadius = 3; l.shadowOffset = CGSizeMake(0, 1); }
    [parent addSublayer:l]; return l;
}
static CAShapeLayer *line(CALayer *parent, UIColor *c, CGFloat w) {   // an outline only: icons and the cursor arrows
    CAShapeLayer *l = [CAShapeLayer layer]; l.fillColor = nil; l.strokeColor = c.CGColor; l.lineWidth = w; l.lineCap = kCALineCapRound; l.lineJoin = kCALineJoinRound;
    [parent addSublayer:l]; return l;
}
static CATextLayer *label(CALayer *parent, NSString *s) {
    CATextLayer *t = [CATextLayer layer];
    t.string = s; t.alignmentMode = kCAAlignmentCenter; t.foregroundColor = k_text.CGColor;
    [parent addSublayer:t]; return t;
}
static BOOL fullOnly(int b) { return b == B_LS || b == B_RS || b >= B_LEFT; }   // keys shown only in the 3D layout

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        _layout = dm_layout(self.bounds, UIEdgeInsetsZero, NO, CGRectNull, DM_PICTURE_16_9);   // until the front end arranges it
        [self registerForTraitChanges:@[UITraitDisplayScale.class] withHandler:^(id<UITraitEnvironment> environment, UITraitCollection *previous) {
            [(UIView *)environment setNeedsLayout];
        }];
        self.multipleTouchEnabled = YES; self.opaque = NO; self.backgroundColor = UIColor.clearColor;
        const char *feedback = getenv("DM_TOUCH_HAPTICS");
        if (!feedback || atoi(feedback)) {
            _touchFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [_touchFeedback prepare];
        }
        _owner = [NSMapTable strongToStrongObjectsMapTable]; _faceOf = [NSMapTable strongToStrongObjectsMapTable];
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            // each colour carries its own low opacity instead of lowering the whole view's alpha (that would add an off-screen pass for the full-screen layer)
            if (DM_GAME_TOUCH_STYLE) {   // Orbit, in PRAGMATA's own HUD look (the player's choice): dark glass keys like its tutorial panels, which also stay visible in its white rooms,
                // white line work and text, and its blue for whatever is on (pressed, ZL locked, hacking, running). DM_TOUCH_OPACITY (40-160 %) scales every alpha but the pressed ones
                const char *e = getenv("DM_TOUCH_OPACITY"); double k = e && atoi(e) > 0 ? fmin(fmax(atoi(e), 40), 160) / 100.0 : 1;
                #define W(a) [UIColor colorWithWhite:1 alpha:fmin((a) * k, 1)]
                #define INK(a) [UIColor colorWithRed:8 / 255.0 green:14 / 255.0 blue:22 / 255.0 alpha:fmin((a) * k, 0.9)]
                k_idle = INK(0.42); k_ringFill = INK(0.24); k_line = W(0.78); k_text = W(0.95); k_badge = INK(0.62); k_capFill = W(0.22);
                k_stickLine = W(0.6); k_guide = W(0.16);
                k_okRing = W(0.06); k_okLine = W(0.38); k_okKnob = W(0.14); k_okKnobOn = [UIColor colorWithWhite:1 alpha:0.45];
                #undef W
                #undef INK
                // the blue is a near-white one with only a hint of blue, at low opacity (the player's choice, V7): what is on reads as a light tint, not a coloured fill or a strong glow
                k_micro = [UIColor colorWithRed:236 / 255.0 green:242 / 255.0 blue:250 / 255.0 alpha:0.9];
                k_accent = [UIColor colorWithRed:226 / 255.0 green:236 / 255.0 blue:250 / 255.0 alpha:0.9]; k_on = [k_accent colorWithAlphaComponent:0.3]; k_onLine = k_textOn = UIColor.whiteColor;
                if (e) LOG("front end: touch controls at %d %% opacity (DM_TOUCH_OPACITY)", (int)lrint(k * 100));
            } else {
                k_idle = [UIColor colorWithWhite:1 alpha:0.14]; k_on = [UIColor colorWithWhite:1 alpha:0.45]; k_line = [UIColor colorWithWhite:1 alpha:0.38];
                k_ringFill = [UIColor colorWithWhite:1 alpha:0.06]; k_text = [UIColor colorWithWhite:1 alpha:0.6]; k_textOn = [UIColor colorWithWhite:0 alpha:0.7];
                k_micro = k_text; k_badge = k_capFill = k_idle; k_onLine = k_line; k_accent = UIColor.whiteColor;
            }
        });
        _controls = [CALayer layer]; [self.layer addSublayer:_controls];
        _controls.allowsGroupOpacity = NO;   // auto-dim lowers its opacity: each layer blends on its own, no off-screen pass for the full-screen layer
        _ring = shape(_controls); _ring.fillColor = k_ringFill.CGColor;
        _knob = shape(_controls);
        CAShapeLayer *in = [CAShapeLayer layer]; in.fillColor = nil; in.strokeColor = k_line.CGColor; in.lineWidth = 1.5;   // inner ring of the knob
        [_knob addSublayer:in]; _knobIn = in;
        static NSString *const names[B_N] = {@"A", @"B", @"X", @"Y", @"L3", @"R3", @"L", @"R", @"ZL", @"ZR", @"+", @"−"};
        for (int b = 0; b < B_N; b++) {
            _key[b] = shape(_controls);
            if (DM_GAME_TOUCH_STYLE && names[b]) { _icon[b] = line(_key[b], k_text, 1.7); _tag[b] = shape(_key[b]); _tag[b].fillColor = k_badge.CGColor; _tag[b].lineWidth = 1; }
            if (names[b]) _label[b] = label(DM_GAME_TOUCH_STYLE ? _tag[b] : _key[b], names[b]);   // the D-pad arms carry no label; Orbit: the letter is the tag's
        }
        if (DM_GAME_TOUCH_STYLE) {
            _od = shape(_controls); _icon[B_N] = line(_od, k_text, 1.7); _tag[B_N] = shape(_od); _tag[B_N].fillColor = k_badge.CGColor; _tag[B_N].lineWidth = 1; _odLabel = label(_tag[B_N], @"OD");
            for (int i = 0; i < 4; i++) { _arrow[i] = line(_key[B_A + i], k_text, 1.7); _arrow[i].hidden = YES; }
            _fire2 = shape(_controls); _icon[B_N + 1] = line(_fire2, k_text, 1.7); _tag[B_N + 1] = shape(_fire2); _tag[B_N + 1].fillColor = k_badge.CGColor; _tag[B_N + 1].lineWidth = 1;
            _fire2Label = label(_tag[B_N + 1], @"ZR"); _fire2.hidden = YES;
            // the knob as an analog nub: a soft diagonal shade (lighter top left, darker bottom right: a shallow dish), its grip dots (the knob's first sublayer, set in orbitLayout) and a lip
            _knobShade = [CAGradientLayer layer]; _knobShade.startPoint = CGPointMake(0.15, 0.1); _knobShade.endPoint = CGPointMake(0.85, 0.95);
            _knobShade.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.16].CGColor, (id)[UIColor colorWithWhite:1 alpha:0].CGColor, (id)[UIColor colorWithWhite:0 alpha:0.28].CGColor];
            _knobShade.locations = @[@0, @0.5, @1]; _knobShadeMask = [CAShapeLayer layer]; _knobShade.mask = _knobShadeMask; [_knob insertSublayer:_knobShade atIndex:0];
            _knobLip = line(_knob, [UIColor colorWithWhite:1 alpha:0.28], 1);
            _dpadGuide = line(_controls, k_guide, 1); [_controls insertSublayer:_dpadGuide atIndex:0];   // under every key
            for (int i = 0; i < 4; i++) _dchev[i] = line(_key[B_LEFT + i], k_text, 1.6);
            _lockHint = label(_controls, @"LOCKED"); _lockHint.hidden = YES; _lockHint.foregroundColor = k_micro.CGColor;   // no HACKING or RUN text (the player's choice, V7)
        }
        _menu = [DmMenuButton buttonWithType:UIButtonTypeCustom];
        _menu.backgroundColor = k_idle; _menu.layer.borderColor = k_line.CGColor; _menu.layer.borderWidth = 1.5;
        _menu.layer.shadowColor = UIColor.blackColor.CGColor; _menu.layer.shadowOpacity = DM_GAME_TOUCH_STYLE ? 0 : 0.2;   // Orbit: no drop shadow
        _menu.layer.shadowRadius = 3; _menu.layer.shadowOffset = CGSizeMake(0, 1);
        _menu.tintColor = k_text; _menu.accessibilityLabel = @"Menu";
        _menu.menu = CFBridgingRelease(dm_game_menu()); _menu.showsMenuAsPrimaryAction = YES;
        __weak DmGamepad *weakSelf = self;
        [_menu addAction:[UIAction actionWithHandler:^(UIAction *a) { (void)a; [weakSelf reset]; }] forControlEvents:UIControlEventMenuActionTriggered];   // the menu opens: release every key and touch first
        [self addSubview:_menu];
        NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:k_layout_key];
        int l = saved ? (int)saved.integerValue : DM_GAME_PAD_LAYOUT;
        if (l == 2 && dm_opmode() != 0) l = 0;   // Tap only in handheld mode (env.txt's DM_OPMODE may have changed it)
        _full = l == 1; _tap = l == 2;
        [self applyLayout];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(padsChanged:) name:GCControllerDidConnectNotification object:nil];
        [nc addObserver:self selector:@selector(padsChanged:) name:GCControllerDidDisconnectNotification object:nil];
        pads_start();
        [self padsChanged:nil];
        motion_start();
        phone_motion_start(self);
    }
    return self;
}
- (void)applyLayout {   // show / hide the controls for the current layout
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    BOOL o = self.orbit;
    for (int b = 0; b < B_N; b++) _key[b].hidden = _tap || (fullOnly(b) && !_full) || (o && (b == B_LS || b == B_RS || (b == B_L && !_full)));   // Orbit: L3 by running, R3 by a double tap in the aim area
    _ring.hidden = _knob.hidden = _tap;
    if (DM_GAME_TOUCH_STYLE) { _od.hidden = _tap || !o; if (_tap || !o) _fire2.hidden = YES;   // the second fire key: shown by refresh while ZL is on
        _dpadGuide.hidden = YES; for (int i = 0; i < 4; i++) _dchev[i].hidden = !o; }   // Orbit's landscape D-pad: its arrowheads, no circle (V23)
    [CATransaction commit];
}
- (int)padLayout { return _tap ? 2 : _full ? 1 : 0; }
- (void)setPadLayout:(int)l {   // the in-game menu's pick: release every touch first (no key stays held), save, lay out again
    if (l == 2 && dm_opmode() != 0) l = 0;
    [self reset];
    _full = l == 1; _tap = l == 2;
    [NSUserDefaults.standardUserDefaults setObject:@(l) forKey:k_layout_key];
    [self applyLayout]; [self setNeedsLayout];
}
- (void)opmodeChanged {   // docked: the Tap layout goes (the game reads no touch screen then), unsaved, so handheld mode at the next start brings it back
    if (!_tap || dm_opmode() == 0) return;
    [self reset]; _tap = NO; _full = NO; [self applyLayout]; [self setNeedsLayout];
}
- (void)setTouchFeedback:(BOOL)on {
    if (!on) { _touchFeedback = nil; return; }
    if (!_touchFeedback) { _touchFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight]; [_touchFeedback prepare]; }
}

// ---- Orbit (profile touch_style orbit: PRAGMATA) ----
// A two-thumb landscape layout built around the game's controls: the ZR fire hub under the right thumb with A B X Y around it at their Switch places (hacking moves the cursor
// with them while ZL is held: X up, B down, Y left, A right), R (dodge) above them on the right thumb's arc; ZL (aim; held, or locked on by a tap, for hacking; while it is on, a second fire key (ZR) shows at the top left for the left thumb), the Overdrive
// key (LS + RS) and the D-pad (weapons) on the left thumb's arc; a floating left stick that runs (LS) past its rim; the right half of the screen aims (a double tap there holds RS).
// White line icons with letter tags, no drop shadows and no decorative lines (no arcs, rings or aim marker: the player asked for the keys alone), auto-dim after 4 s with
// nothing held. An arc position is an angle from the bottom edge and a radius from the corner
// rectangle's bottom corner. Portrait and the separated layouts keep the classic places with the white look. Every value is in u, as above
static const CGFloat
    O_ARC = 230,                                                                // the thumbs' arc: radius from each bottom corner (keys only: no line is drawn)
    O_HUB_X = 100, O_HUB_Y = 100, O_HUB_R = 30, O_HUB_HIT = 1.15,               // ZR hub: centre from the right and the bottom, radius, hit radius (times the radius)
    O_GAP = 62, O_KEY_R = 24, O_KEY_HIT = 1.2,                                  // A B X Y: distance from the hub, radius, hit radius
    O_R_ANGLE = 70, O_R_ARC = 240, O_R_R = 26,                                  // R: on the right arc, a little outside it
    O_RIGHT_IN = 30,                                                            // the right thumb's keys (hub, A B X Y, R) this much nearer the centre than the design's places
    O_ZL_ANGLE = 40, O_ZL_R = 30, O_ZL_HIT = 1.3, O_OD_ANGLE = 68, O_OD_R = 22,  // ZL and Overdrive on the left arc
    O_DPAD_ANGLE = 14, O_DPAD_R = 50, O_ARM_W = 18, O_ARM_IN = 11,              // D-pad on the left arc (3D layout only); 38 / 14 / 9 until V22, bigger at the player's request
    O_STICK_R = 66, O_KNOB_R = 29, O_RUN = 1.2, O_ZONE_W = 0.42, O_ZONE_TOP = 110,   // floating stick: ring, knob; LS past this times the ring; its area: the left 42 % of the width, below 110
    O_LOOK_X = 0.5,                                                             // aim area: the right half
    O_PILL_DX = 44, O_PILL_Y = 20, O_PILL_R = 13.6, O_MENU_R = 12,              // − / + beside the menu at the top centre
    O_DPAD_HEAD_W = 0.42, O_DPAD_HEAD_IN = 0.6, O_DPAD_HEAD_OUT = 0.86, O_DPAD_DX = 16, O_DPAD_DY = 12,          // D-pad arrowheads (Ocarina of Time port's): half-width (times the arm's), base and tip (times its radius); no circle around it since V23
    O_TOP_IN = 70,                                                              // − menu + at the top right: the menu this far in from the safe area's right edge (the player's choice)
    O_L_X = 44, O_L_Y = 40, O_L_R = 18,                                         // L (3D layout only; the game gives it no action)
    O_F2_X = 132, O_F2_Y = 72, O_F2_R = 38,                                     // the second fire key (ZR), right of L at the top left: shown while ZL is on, for the left thumb; larger than the hub
    O_ZL_TAP = 0.25,                                                            // ZL: a press shorter than this locks it on (a tap); a longer one is held and let go
    O_SIZE = 115,                                                               // the keys' size, % (a little larger than the design's first sizes)
    O_TAP2 = 0.28, O_TAP2_D = 40,                                               // double tap: within 280 ms and 40 u
    O_DIM_AFTER = 4, O_DIM = 0.45, O_DIM_FADE = 0.35;                           // auto-dim: after 4 s, to 45 %, over 350 ms
enum { B_OD = B_N, B_F2 = B_N + 1 };   // the Overdrive key's index in the Orbit arrays and in a C_BTN owner; the second fire key's in the Orbit arrays
static CGPoint arcAt(CGRect s, int right, CGFloat deg, CGFloat r) { CGFloat a = deg * M_PI / 180; return CGPointMake(right ? CGRectGetMaxX(s) - r * cos(a) : CGRectGetMinX(s) + r * cos(a), CGRectGetMaxY(s) - r * sin(a)); }
- (BOOL)orbit { return DM_GAME_TOUCH_STYLE && !_layout.separated && self.bounds.size.width > self.bounds.size.height; }
// Orbit's unit for its keys: u times the size, O_SIZE % by default (DM_TOUCH_SIZE in Documents/env.txt, 80-140 %). Keys, their places from the corners, gaps and the stick grow
// together from the bottom corners; the aim and move areas and the double tap's distance stay in u. Outside the Orbit layout it is u
- (CGFloat)ou {
    static double k = -1; if (k < 0) { const char *e = getenv("DM_TOUCH_SIZE"); k = (e && atoi(e) > 0 ? fmin(fmax(atoi(e), 80), 140) : O_SIZE) / 100.0; if (e) LOG("front end: touch controls at %d %% size (DM_TOUCH_SIZE)", (int)lrint(k * 100)); }
    return self.orbit ? self.u * k : self.u;
}

// ---- Layout (points; computed inside the safe area) ----
- (void)arrange:(DmLayout)layout {
    if (CGRectEqualToRect(_layout.controls, layout.controls) && CGRectEqualToRect(_layout.game, layout.game) && _layout.separated == layout.separated && _layout.topSafeOnly == layout.topSafeOnly) return;
    [self reset];   // A finger held across a pose change must not leave a key or game touch stuck.
    _layout = layout;
    [self setNeedsLayout];
}
- (CGRect)safe { return CGRectIntersection(_layout.controls, UIEdgeInsetsInsetRect(self.bounds, dm_game_safe_insets(self.bounds, self.safeAreaInsets, _layout.topSafeOnly))); }
- (CGRect)corner { if (_layout.separated) return self.safe; UIEdgeInsets i = self.safeAreaInsets; i.left *= K_CORNER_IN; i.right *= K_CORNER_IN; return UIEdgeInsetsInsetRect(self.bounds, i); }   // the rectangle the bottom-corner controls use
- (CGFloat)u { if (_layout.separated) { CGRect s = self.safe; return MIN(MIN(s.size.height / 430.0, s.size.width / 700.0), 1.3); } return MIN(self.bounds.size.height / 430.0, 1.3); }   // 1 = 430 points tall (iPhone Pro Max landscape)
static CGPoint side(CGRect s, int right, CGFloat dx, CGFloat y) { return CGPointMake(right ? CGRectGetMaxX(s) - dx : CGRectGetMinX(s) + dx, y); }
- (BOOL)portraitControls { return _layout.separated && self.bounds.size.height > self.bounds.size.width; }
- (CGPoint)portraitThumbCenter:(BOOL)right {
    CGRect s = self.safe;
    return CGPointMake(CGRectGetMinX(s) + s.size.width * (right ? 0.72 : 0.28),
                       CGRectGetMinY(s) + s.size.height * 0.58);
}
- (CGPoint)faceCenter { CGRect s = self.corner; CGFloat u = self.u;
    if (self.portraitControls) return [self portraitThumbCenter:YES];
    if (self.orbit) return [self oKey:B_ZR];   // around the hub
    CGFloat edge = _layout.separated ? self.faceGap + self.faceHitR : 0;
    return side(s, 1, MAX(K_FACE_X * u, edge), CGRectGetMaxY(s) - MAX(K_PAD_Y * u, edge)); }
- (CGFloat)faceGap { return self.orbit ? O_GAP * self.ou : K_FACE_GAP * self.u; }
- (CGFloat)faceR { return self.orbit ? O_KEY_R * self.ou : K_FACE_R * self.u; }
- (CGFloat)faceHitR { return self.orbit ? MAX(self.faceR * O_KEY_HIT, 22) : MAX(self.faceR * 1.25, _layout.separated ? 22 : 0); }
- (CGPoint)oKey:(int)b {   // Orbit: the centre of a key other than A B X Y and the D-pad
    CGRect s = self.corner, f = self.safe; CGFloat u = self.ou;
    switch (b) {
    case B_ZR: return CGPointMake(CGRectGetMaxX(s) - (O_HUB_X + O_RIGHT_IN) * u, CGRectGetMaxY(s) - O_HUB_Y * u);   // A B X Y go with it (facePos)
    case B_R: { CGPoint r = arcAt(s, 1, O_R_ANGLE, O_R_ARC * u); r.x -= O_RIGHT_IN * u; return r; }
    case B_ZL: return arcAt(s, 0, O_ZL_ANGLE, O_ARC * u);
    case B_OD: return arcAt(s, 0, O_OD_ANGLE, O_ARC * u);
    case B_L: return CGPointMake(CGRectGetMinX(f) + O_L_X * u, CGRectGetMinY(f) + O_L_Y * u);
    case B_F2: return CGPointMake(CGRectGetMinX(f) + O_F2_X * u, CGRectGetMinY(f) + O_F2_Y * u);
    default: return CGPointMake(CGRectGetMaxX(f) - O_TOP_IN * u + (b == B_PLUS ? O_PILL_DX : -O_PILL_DX) * u, CGRectGetMinY(f) + O_PILL_Y * u);   // top right: − left of the menu, + right of it
    }
}
- (CGFloat)oKeyR:(int)b { return (b == B_ZR ? O_HUB_R : b == B_R ? O_R_R : b == B_ZL ? O_ZL_R : b == B_OD ? O_OD_R : b == B_L ? O_L_R : b == B_F2 ? O_F2_R : O_PILL_R) * self.ou; }
- (CGFloat)oKeyDistance:(int)b point:(CGPoint)p {   // distance / hit radius (at least 22 points, half of a 44-point target)
    CGPoint c = [self oKey:b]; CGFloat r = [self oKeyR:b] * (b == B_ZR || b == B_F2 ? O_HUB_HIT : b == B_ZL ? O_ZL_HIT : 1.35);
    return hypot(p.x - c.x, p.y - c.y) / MAX(r, 22);
}
- (CGPoint)facePos:(int)b { CGPoint c = self.faceCenter; CGFloat g = self.faceGap;
    switch (b) { case B_A: return CGPointMake(c.x + g, c.y); case B_B: return CGPointMake(c.x, c.y + g); case B_X: return CGPointMake(c.x, c.y - g); default: return CGPointMake(c.x - g, c.y); } }
- (CGPoint)stickHome {
    if (self.portraitControls) {
        CGPoint p = [self portraitThumbCenter:NO];
        if (_full) p.x -= self.dpadR + 6 * self.u;
        return p;
    }
    CGRect s = self.corner;
    return side(s, 0, K_STICK_X * self.ou, CGRectGetMaxY(s) - K_PAD_Y * self.ou);   // ou is u outside the Orbit layout
}
- (CGPoint)stickCentre:(int)i { return i ? _rCentre : self.orbit && _stick[0] ? _lCentre : self.stickHome; }   // Orbit: the left stick floats to where its touch landed
- (CGFloat)stickR:(int)i { return i ? K_RSTICK_R * self.u : self.orbit ? O_STICK_R * self.ou : K_STICK_R * self.u; }
- (BOOL)inRightArea:(CGPoint)p { CGRect b = _layout.controls; return p.x >= CGRectGetMaxX(b) - b.size.width * (self.orbit ? 1 - O_LOOK_X : K_RSWIPE); }
- (CGPoint)dpadCenter {
    if (self.portraitControls) {
        CGPoint p = [self portraitThumbCenter:NO];
        p.x += [self stickR:0] + 6 * self.u;
        return p;
    }
    CGRect s = self.corner; CGFloat u = self.u;
    if (self.orbit) { CGPoint p = arcAt(s, 0, O_DPAD_ANGLE, O_ARC * self.ou); p.x += O_DPAD_DX * self.ou; p.y -= O_DPAD_DY * self.ou; return p; }   // V23: moved up and right for its larger size (its down arm clear of the home bar, its up arm clear of ZL)
    return side(s, 0, K_LOW_X * u, CGRectGetMaxY(s) - K_LOW_Y * u);
}
- (CGFloat)dpadR { return self.orbit ? O_DPAD_R * self.ou : K_DPAD_R * self.u; }
static BOOL isDrop(int b) { return b == B_ZL || b == B_L || b == B_ZR || b == B_R; }
static BOOL isClick(int b) { return b == B_LS || b == B_RS; }
- (CGPoint)dropCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; BOOL z = b == B_ZL || b == B_ZR;
    CGFloat edge = _layout.separated ? 22 : 0;
    return side(s, b == B_ZR || b == B_R, MAX((z ? K_ZL_X : K_L_X) * u, edge), CGRectGetMinY(s) + MAX((z ? K_ZL_Y : K_L_Y) * u, edge)); }
- (CGFloat)dropR:(int)b { return (b == B_ZL || b == B_ZR ? K_ZL_R : K_L_R) * self.u; }
- (CGPoint)clickCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; CGFloat edge = _layout.separated ? 22 : 0;
    return side(s, b == B_RS, MAX(K_CLICK_X * u, edge), CGRectGetMinY(s) + MAX(K_ZL_Y * u, edge)); }
- (CGRect)pillRect:(int)b { CGRect s = self.safe; CGFloat u = self.u, w = K_PILL_W * u, h = K_PILL_H * u;
    CGPoint c = CGPointMake(CGRectGetMidX(s) + (b == B_PLUS ? K_PILL_DX : -K_PILL_DX) * u, CGRectGetMinY(s) + MAX(K_PILL_Y * u, _layout.separated ? 14 : 0));   // − on the left, + on the right
    return CGRectMake(c.x - w / 2, c.y - h / 2, w, h); }
- (CGPoint)menuCenter { CGRect s = self.safe; return CGPointMake(self.orbit ? CGRectGetMaxX(s) - O_TOP_IN * self.ou : CGRectGetMidX(s), CGRectGetMinY(s) + MAX(self.orbit ? O_PILL_Y * self.ou : K_PILL_Y * self.u, _layout.separated ? 14 : 0)); }
- (CGFloat)menuR { return self.orbit ? O_MENU_R * self.ou : K_MENU_R * self.u; }

static CGFloat dist(CGPoint a, CGPoint b) { return hypot(a.x - b.x, a.y - b.y); }
- (CGFloat)buttonDistance:(int)b point:(CGPoint)p {
    CGFloat u = self.u;
    if (self.orbit) return [self oKeyDistance:b point:p];
    if (isDrop(b)) return dist(p, [self dropCenter:b]) / MAX([self dropR:b] * 1.35, _layout.separated ? 22 : 0);
    if (isClick(b)) return dist(p, [self clickCenter:b]) / MAX(K_CLICK_R * u * 1.35, _layout.separated ? 22 : 0);
    CGRect r = CGRectInset([self pillRect:b], -8 * u, -8 * u);
    if (!_layout.separated && !CGRectContainsPoint(r, p)) return CGFLOAT_MAX;
    CGFloat w = MAX(r.size.width, _layout.separated ? 28 : 0), h = MAX(r.size.height, _layout.separated ? 28 : 0);
    return MAX(fabs(p.x - CGRectGetMidX(r)) / (w / 2), fabs(p.y - CGRectGetMidY(r)) / (h / 2));
}
- (int)btnAt:(CGPoint)p {   // Locked at touch-down; nearest normalized target wins overlapping separated-layout hits.
    int best = -1; CGFloat distance = 1;
    if (self.orbit) {   // the keys that are not the thumbs' nearest-wins group (orbitKindAt): R, − / +, L, Overdrive
        static const int ob[] = {B_R, B_MINUS, B_PLUS, B_L, B_OD};
        for (int i = 0; i < 5; i++) { int b = ob[i]; if (b == B_L && !_full) continue;
            CGFloat d = [self oKeyDistance:b point:p]; if (d <= 1 && (best < 0 || d < distance)) { best = b; distance = d; } }
        return best;
    }
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (fullOnly(b) && !_full) continue;
        CGFloat d = [self buttonDistance:b point:p];
        if (d <= 1 && (best < 0 || d < distance)) {
            best = b; distance = d;
            if (!_layout.separated) return b;
        }
    }
    return best;
}
- (CGFloat)menuDistance:(CGPoint)p { return dist(p, self.menuCenter) / MAX(self.menuR * 1.6, 22); }
- (BOOL)menuTakes:(CGPoint)p {   // the menu button takes a touch in its hit circle unless a locked key's target is nearer (the drawn keys are hidden in Tap and with a controller)
    CGFloat d = [self menuDistance:p]; if (d > 1) return NO;
    if (_tap || _padOff || (_layout.separated && !CGRectContainsPoint(_layout.controls, p))) return YES;
    int hit = [self btnAt:p];
    return hit < 0 || d < [self buttonDistance:hit point:p];
}
- (uint64_t)faceAt:(CGPoint)p {   // keys under the finger in the diamond (between two keys both count)
    uint64_t m = 0; CGFloat r = self.faceHitR;
    for (int b = B_A; b <= B_Y; b++) if (dist(p, [self facePos:b]) <= r) m |= 1ull << b;
    return m;
}
- (uint64_t)dpadAt:(CGPoint)p {   // 8 directions: 45° each, diagonals press two keys; a small centre circle counts as none
    CGPoint c = self.dpadCenter; CGFloat dx = p.x - c.x, dy = p.y - c.y;
    if (hypot(dx, dy) < self.dpadR * 0.25) return 0;
    double a = atan2(-dy, dx) * 180 / M_PI; uint64_t m = 0;
    if (a > -67.5 && a < 67.5) m |= 1ull << B_RIGHT;
    if (a > 22.5 && a < 157.5) m |= 1ull << B_UP;
    if (a > 112.5 || a < -112.5) m |= 1ull << B_LEFT;
    if (a < -22.5 && a > -157.5) m |= 1ull << B_DOWN;
    return m;
}
- (CGPoint)knobOffset:(int)i {   // knob offset from the stick centre (clamped to the stick radius)
    if (!_stick[i]) return CGPointZero;
    CGPoint h = [self stickCentre:i]; CGFloat dx = _stickNow[i].x - h.x, dy = _stickNow[i].y - h.y, d = hypot(dx, dy), R = [self stickR:i];
    if (d > R) { dx *= R / d; dy *= R / d; }
    return CGPointMake(dx, dy);
}

// ---- Touch ----
- (void)recompute {
    uint64_t face = 0; for (UITouch *t in _faceOf) face |= [_faceOf objectForKey:t].unsignedLongLongValue;
    uint64_t btn = 0, dpad = 0;
    for (UITouch *t in _owner) { uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff);
        if (c == C_BTN) btn |= (v >> 8) == B_OD ? 1ull << B_LS | 1ull << B_RS : 1ull << (v >> 8);   // Overdrive: LS + RS together
        else if (c == C_DPAD) dpad |= [self dpadAt:[t locationInView:self]];
        else if (c == C_ZL) btn |= 1ull << B_ZL;
        else if (c == C_HUB || c == C_FIRE2) btn |= 1ull << B_ZR; }
    if (_zlLocked) btn |= 1ull << B_ZL;
    if (_rsTouch) btn |= 1ull << B_RS;
    if (_stick[0] && self.orbit) { CGPoint h = [self stickCentre:0]; if (dist(_stickNow[0], h) > [self stickR:0] * O_RUN) btn |= 1ull << B_LS; }   // run: past the rim
    int32_t ax[4] = {0};
    for (int i = 0; i < 2; i++) {
        CGPoint o = [self knobOffset:i]; CGFloat R = [self stickR:i], d = hypot(o.x, o.y), dz = R * K_DEAD;
        if (d <= dz) continue;
        CGFloat m = fmin((d - dz) / (R * K_FULL - dz), 1) / d;   // outside the dead zone: 0 rising to full at the full-tilt radius
        ax[i * 2] = (int32_t)lrint(o.x * m * 32767); ax[i * 2 + 1] = (int32_t)lrint(-o.y * m * 32767);   // host: up is positive; rounded so full tilt is exactly 32767
    }
    BOOL changed = face != _faceBits || dpad != _dpadBits || btn != _btnBits;
    uint64_t pressed = (face | dpad | btn) & ~(_faceBits | _dpadBits | _btnBits);
    unsigned gripping = (_stick[0] ? 1u : 0) | (_stick[1] ? 2u : 0);
    if (pressed || (gripping & ~_hapticSticks)) {
        [_touchFeedback impactOccurredWithIntensity:0.6]; [_touchFeedback prepare];
    }
    _hapticSticks = gripping;
    _faceBits = face; _dpadBits = dpad; _btnBits = btn;
    pthread_mutex_lock(&g_mu);
    g_touch_btn = face | dpad | btn; g_touch_lx = ax[0]; g_touch_ly = ax[1]; g_touch_rx = ax[2]; g_touch_ry = ax[3];
    pthread_mutex_unlock(&g_mu);
    publish();
    BOOL stick = _stick[0] != nil;   // only the left stick is drawn: the right one needs no refresh
    if (changed || stick || _stickShown) [self refresh];   // also refresh on the stick release so the knob returns to the centre
    _stickShown = stick;
}
// Touches no control takes go to the game's touch screen, normalized on front_ios.m's actual 16:9 viewport (including portrait and tabletop splits, and the cropped Fill picture): Super Mario Galaxy's pointer in handheld mode (profile op_mode). The host reports them only in handheld mode, as on the Switch (hle_hid.c touch_read)
- (void)pushGame {
    CGRect b = _layout.game;
    if (b.size.width <= 0 || b.size.height <= 0) { dm_touch_set(NULL, 0); return; }
    dm_touch t[16]; int n = 0;
    for (int i = 0; i < 16; i++) if (_game[i]) {
        CGPoint p = dm_game_touch_point(b, [_game[i] locationInView:self]);   // with Fill the game rectangle is larger than the view (DmLayout.h)
        t[n++] = (dm_touch){(uint32_t)i, (float)p.x, (float)p.y};
    }
    dm_touch_set(t, n);
}
- (BOOL)gameBegin:(UITouch *)t {
    if (CGRectIsEmpty(_layout.game) || (_layout.separated && !CGRectContainsPoint(_layout.game, [t locationInView:self]))) return NO;
    for (int i = 0; i < 16; i++) if (!_game[i]) { _game[i] = t; [_owner setObject:@(C_GAME | (uint64_t)i << 8) forKey:t]; return YES; }
    return NO;
}
// While an offline HTML page is shown over the picture (web_apple.m front_web_touch), a touch no control would take goes to the page instead of the game's touch screen:
// the gamepad lets it through. The same tests as touchesBegan
int front_web_touch(void);
// Orbit: what a touch-down at p takes, in order: a locked key (R, − / +, L, Overdrive: btnAt), then the nearest of ZL, the ZR hub, the face keys and the D-pad by distance over
// hit radius, then the move area (the floating stick, if free), then the aim area (the right stick, if free); C_NONE: the game's touch screen. *key: the key for C_BTN
- (int)orbitKindAt:(CGPoint)p key:(int *)key {
    if (!_fire2.hidden && [self oKeyDistance:B_F2 point:p] <= 1) return C_FIRE2;   // the second fire key, while it is shown (ZL on)
    int hit = [self btnAt:p]; if (hit >= 0) { *key = hit; return C_BTN; }
    CGFloat best = 1; int kind = C_NONE, d;
    CGFloat z = [self oKeyDistance:B_ZL point:p]; if (z <= best) { best = z; kind = C_ZL; }
    CGFloat h = [self oKeyDistance:B_ZR point:p]; if (h < best) { best = h; kind = C_HUB; }
    CGFloat f = CGFLOAT_MAX; for (d = B_A; d <= B_Y; d++) f = MIN(f, dist(p, [self facePos:d]) / self.faceHitR);
    if (f < best) { best = f; kind = C_FACE; }
    if (_full) { CGFloat g = dist(p, self.dpadCenter) / MAX(self.dpadR * K_DPAD_GRAB, 22); if (g < best) { best = g; kind = C_DPAD; } }
    if (kind != C_NONE) return kind;
    CGRect b = _layout.controls;
    if (!_stick[0] && p.x < CGRectGetMinX(b) + b.size.width * O_ZONE_W && p.y > CGRectGetMinY(self.safe) + O_ZONE_TOP * self.u) { *key = 0; return C_STICK; }
    if (!_stick[1] && [self inRightArea:p]) { *key = 1; return C_STICK; }
    return C_NONE;
}
- (void)orbitBegin:(UITouch *)t at:(CGPoint)p game:(BOOL *)game {
    int key = 0, kind = [self orbitKindAt:p key:&key]; double now = CACurrentMediaTime(); CGFloat u = self.u;
    switch (kind) {
    case C_BTN: [_owner setObject:@(C_BTN | (uint64_t)key << 8) forKey:t]; return;
    case C_ZL:   // a tap (let go within O_ZL_TAP) locks ZL on, so the left thumb is free while the right one hacks and shoots; a longer press is ZL held and let go (no lock);
                 // while locked, the next touch only lets it go (the player's choice, V7: was a double tap)
        if (_zlLocked) { _zlLocked = NO; [_owner setObject:@(C_ZLOFF) forKey:t]; return; }
        _zlTouch = t; _zlDown = now;
        [_owner setObject:@(C_ZL) forKey:t]; return;
    case C_FIRE2: [_owner setObject:@(C_FIRE2) forKey:t]; return;   // ZR alone: it takes no stick, so dragging on it neither aims nor turns the camera (the hub and the aim area do)
    case C_HUB:   // fires; with the right stick free the same finger aims from where it landed (the centre stays: drag to turn while firing)
        [_owner setObject:@(C_HUB) forKey:t];
        if (!_stick[1]) { _stick[1] = t; _stickNow[1] = p; _rCentre = p; _hubAim = t; }
        return;
    case C_FACE: [_owner setObject:@(C_FACE) forKey:t]; [_faceOf setObject:@([self faceAt:p]) forKey:t]; return;
    case C_DPAD: [_owner setObject:@(C_DPAD) forKey:t]; return;
    case C_STICK:
        if (key == 0) {   // the stick centres on the touch, the ring kept inside the move area and the corner rectangle
            CGRect c = self.corner, b = _layout.controls; CGFloat R = [self stickR:0];
            CGFloat x0 = CGRectGetMinX(c) + R, x1 = CGRectGetMinX(b) + b.size.width * O_ZONE_W - R, y0 = CGRectGetMinY(self.safe) + O_ZONE_TOP * u + R, y1 = CGRectGetMaxY(c) - R;
            _lCentre = CGPointMake(fmin(fmax(p.x, x0), fmax(x0, x1)), fmin(fmax(p.y, y0), fmax(y0, y1)));
        } else {   // aim: a second touch-down within O_TAP2 and O_TAP2_D of the last one holds RS (reset camera) while it is down; the camera still turns
            if (now - _lookTap < O_TAP2 && dist(p, _lookTapAt) < O_TAP2_D * u) _rsTouch = t;
            _lookTap = now; _lookTapAt = p; _rCentre = p;
        }
        [_owner setObject:@(C_STICK | (uint64_t)key << 8) forKey:t]; _stick[key] = t; _stickNow[key] = p; return;
    default: *game |= [self gameBegin:t];
    }
}
// Auto-dim (Orbit): O_DIM_AFTER after the last touch, with nothing held and ZL not locked, the controls fade to O_DIM; any touch brings them back at once. DM_TOUCH_DIM=0: off
- (void)wake {
    if (_dimmed) { [_controls removeAnimationForKey:@"dim"]; _controls.opacity = 1; _dimmed = NO; }
    [_dim invalidate]; _dim = nil;
}
- (void)armDim {
    static int off = -1; if (off < 0) { const char *e = getenv("DM_TOUCH_DIM"); off = e && !atoi(e); }
    if (!DM_GAME_TOUCH_STYLE || off || _owner.count || _zlLocked || _padOff) return;
    [_dim invalidate]; __weak DmGamepad *w = self;
    _dim = [NSTimer scheduledTimerWithTimeInterval:O_DIM_AFTER repeats:NO block:^(NSTimer *tm) { (void)tm; [w dimNow]; }];
}
- (void)dimNow {
    _dim = nil; if (_owner.count || _zlLocked || _dimmed) return;
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"opacity"]; a.fromValue = @1; a.toValue = @(O_DIM); a.duration = O_DIM_FADE;
    _controls.opacity = O_DIM; [_controls addAnimation:a forKey:@"dim"]; _dimmed = YES;
}
- (BOOL)controlAt:(CGPoint)p {
    if (_padOff || (_layout.separated && !CGRectContainsPoint(_layout.controls, p))) return NO;
    if (_tap) return NO;
    if (self.orbit) { int key; return [self orbitKindAt:p key:&key] != C_NONE; }
    if ([self btnAt:p] >= 0) return YES;
    if (dist(p, self.faceCenter) / (self.faceGap + MAX(self.faceR * 1.6, self.faceHitR)) <= 1) return YES;
    if (_full && dist(p, self.dpadCenter) / MAX(self.dpadR * K_DPAD_GRAB, _layout.separated ? 22 : 0) < 1) return YES;
    if (!_stick[0] && dist(p, self.stickHome) / MAX([self stickR:0] * K_STICK_GRAB, _layout.separated ? 22 : 0) < 1) return YES;
    return _full && !_stick[1] && [self inRightArea:p];
}
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    return v == self && front_web_touch() && ![self controlAt:p] ? nil : v;
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    BOOL game = NO;
    for (UITouch *t in ts) {
        if (_padOff) { game |= [self gameBegin:t]; continue; }
        CGPoint p = [t locationInView:self];
        if (_layout.separated && !CGRectContainsPoint(_layout.controls, p)) { game |= [self gameBegin:t]; continue; }
        if (DM_GAME_TOUCH_STYLE) [self wake];
        if (!_tap && self.orbit) { [self orbitBegin:t at:p game:&game]; continue; }
        int hit = _tap ? -1 : [self btnAt:p];   // the menu button took its own touches (menuTakes)
        if (hit >= 0) { [_owner setObject:@(C_BTN | (uint64_t)hit << 8) forKey:t]; continue; }
        if (_tap) { game |= [self gameBegin:t]; continue; }
        // diamond, D-pad, left stick: take the one with the smallest distance / grab radius, if it is <= 1
        CGFloat best = 1; int kind = C_NONE, idx = 0;
        CGFloat f = dist(p, self.faceCenter) / (self.faceGap + MAX(self.faceR * 1.6, self.faceHitR)); if (f <= best) { best = f; kind = C_FACE; }
        if (_full) { CGFloat d = dist(p, self.dpadCenter) / MAX(self.dpadR * K_DPAD_GRAB, _layout.separated ? 22 : 0); if (d < best) { best = d; kind = C_DPAD; } }
        if (!_stick[0]) { CGFloat s = dist(p, self.stickHome) / MAX([self stickR:0] * K_STICK_GRAB, _layout.separated ? 22 : 0); if (s < best) { best = s; kind = C_STICK; } }
        if (kind == C_NONE && _full && !_stick[1] && [self inRightArea:p]) { kind = C_STICK; idx = 1; _rCentre = p; }   // the right stick: centred where the touch lands
        if (kind == C_FACE) { [_owner setObject:@(C_FACE) forKey:t]; [_faceOf setObject:@([self faceAt:p]) forKey:t]; }
        else if (kind == C_DPAD) [_owner setObject:@(C_DPAD) forKey:t];
        else if (kind == C_STICK) { [_owner setObject:@(C_STICK | (uint64_t)idx << 8) forKey:t]; _stick[idx] = t; _stickNow[idx] = p; }
        else game |= [self gameBegin:t];
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    BOOL game = NO;
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff); CGPoint p = [t locationInView:self];
        if (c == C_FACE) [_faceOf setObject:@([self faceAt:p]) forKey:t];
        else if (c == C_HUB && t == _hubAim) _stickNow[1] = p;   // the hub's aim keeps its centre
        else if (c == C_STICK) { _stickNow[v >> 8] = p;
            if ((v >> 8) == 1) { CGFloat d = dist(p, _rCentre), R = [self stickR:1];   // the right stick's centre follows a finger past its radius, so turning back responds at once
                if (d > R) _rCentre = CGPointMake(p.x - (p.x - _rCentre.x) * R / d, p.y - (p.y - _rCentre.y) * R / d); } }
        else if (c == C_GAME) game = YES;
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)endTouches:(NSSet<UITouch *> *)ts tapped:(BOOL)ended {
    BOOL game = NO;
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue;
        if ((v & 0xff) == C_GAME && (v >> 8) < 16) { _game[v >> 8] = nil; game = YES; }
        if (t == _zlTouch) { if (ended && (v & 0xff) == C_ZL && CACurrentMediaTime() - _zlDown < O_ZL_TAP) _zlLocked = YES; _zlTouch = nil; }   // a tap locks ZL on
        if (t == _hubAim) _hubAim = nil;
        if (t == _rsTouch) _rsTouch = nil;
        [_owner removeObjectForKey:t]; [_faceOf removeObjectForKey:t]; for (int i = 0; i < 2; i++) if (t == _stick[i]) _stick[i] = nil;
    }
    if (game) [self pushGame];
    [self recompute];
    [self armDim];
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:YES]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:NO]; }
- (void)reset { [_owner removeAllObjects]; [_faceOf removeAllObjects]; _stick[0] = _stick[1] = nil; for (int i = 0; i < 16; i++) _game[i] = nil;
    _zlLocked = NO; _hubAim = _rsTouch = _zlTouch = nil; [self wake];   // no key stays held: a locked ZL goes too
    [self pushGame]; [self recompute]; [self armDim]; }

// ---- Shapes ----
static CGPathRef circlePath(CGPoint c, CGFloat r) { return CGPathCreateWithEllipseInRect(CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r), NULL); }
static CGPathRef dropPath(CGPoint c, CGFloat r, CGFloat tipAngle, CGFloat round) {   // teardrop: circle + two tangents meeting at the tip, tip slightly rounded
    CGFloat d = r * K_DROP_TIP, th = acos(r / d);
    CGPoint tip = CGPointMake(c.x + d * cos(tipAngle), c.y + d * sin(tipAngle));
    CGPoint p1 = CGPointMake(c.x + r * cos(tipAngle + th), c.y + r * sin(tipAngle + th)), p2 = CGPointMake(c.x + r * cos(tipAngle - th), c.y + r * sin(tipAngle - th));
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, p2.x, p2.y);
    CGPathAddArcToPoint(p, NULL, tip.x, tip.y, p1.x, p1.y, round);
    CGPathAddArc(p, NULL, c.x, c.y, r, tipAngle + th, tipAngle - th + 2 * M_PI, false);
    CGPathCloseSubpath(p); return p;
}
static CGPathRef armPath(CGPoint c, CGFloat R, CGFloat w, CGFloat in, CGFloat angle, CGFloat round) {   // one D-pad arm: an upward pentagon (tip toward the centre) rotated by angle around the centre
    CGPoint v[5] = {{-w, -R}, {w, -R}, {w, -(in + w)}, {0, -in}, {-w, -(in + w)}};
    CGFloat cs = cos(angle), sn = sin(angle);
    for (int i = 0; i < 5; i++) v[i] = CGPointMake(c.x + v[i].x * cs - v[i].y * sn, c.y + v[i].x * sn + v[i].y * cs);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, (v[4].x + v[0].x) / 2, (v[4].y + v[0].y) / 2);
    for (int i = 0; i < 5; i++) CGPathAddArcToPoint(p, NULL, v[i].x, v[i].y, v[(i + 1) % 5].x, v[(i + 1) % 5].y, round);
    CGPathCloseSubpath(p); return p;
}
static void setPath(CAShapeLayer *l, CGPathRef p) { l.path = p; l.shadowPath = p; CGPathRelease(p); }
// Orbit's line icons, about half a key's radius (s) around c; strokes only (1.7 pt, round). g: the key (B_OD: Overdrive), or 100 + 0..3 for the hacking cursor arrows up / down / left / right
static void mv(CGMutablePathRef p, CGPoint c, CGFloat s, CGFloat x, CGFloat y) { CGPathMoveToPoint(p, NULL, c.x + x * s, c.y + y * s); }
static void ln(CGMutablePathRef p, CGPoint c, CGFloat s, CGFloat x, CGFloat y) { CGPathAddLineToPoint(p, NULL, c.x + x * s, c.y + y * s); }
static void ring(CGMutablePathRef p, CGPoint c, CGFloat s, CGFloat x, CGFloat y, CGFloat r) { CGPathAddEllipseInRect(p, NULL, CGRectMake(c.x + (x - r) * s, c.y + (y - r) * s, 2 * r * s, 2 * r * s)); }
static void chev(CGMutablePathRef p, CGPoint c, CGFloat s, CGFloat x, CGFloat y, CGFloat w, CGFloat h, int dir) {   // a chevron pointing dir (0 up, 1 right)
    if (dir) { mv(p, c, s, x - w, y - h); ln(p, c, s, x + w, y); ln(p, c, s, x - w, y + h); } else { mv(p, c, s, x - h, y + w); ln(p, c, s, x, y - w); ln(p, c, s, x + h, y + w); }
}
static CGPathRef iconPath(int g, CGPoint c, CGFloat s) {
    CGMutablePathRef p = CGPathCreateMutable();
    switch (g) {
    case B_ZR: ring(p, c, s, 0, 0, 0.62); for (int k = 0; k < 4; k++) { CGFloat dx = k == 0 ? 1 : k == 1 ? -1 : 0, dy = k == 2 ? 1 : k == 3 ? -1 : 0; mv(p, c, s, dx * 0.3, dy * 0.3); ln(p, c, s, dx * 1.0, dy * 1.0); } ring(p, c, s, 0, 0, 0.06); break;   // crosshair: shoot
    case B_ZL: for (int k = 0; k < 4; k++) { CGFloat sx = k & 1 ? 1 : -1, sy = k & 2 ? 1 : -1; mv(p, c, s, sx * 0.85, sy * 0.4); ln(p, c, s, sx * 0.85, sy * 0.85); ln(p, c, s, sx * 0.4, sy * 0.85); } ring(p, c, s, 0, 0, 0.18); break;   // lock-on brackets: aim / hack
    case B_R: chev(p, c, s, -0.3, 0, 0.35, 0.6, 1); chev(p, c, s, 0.35, 0, 0.35, 0.6, 1); break;   // dash chevrons: dodge
    case B_B: chev(p, c, s, 0, -0.25, 0.35, 0.6, 0); chev(p, c, s, 0, 0.4, 0.35, 0.6, 0); break;   // double up-chevron: jump / hover
    case B_X: mv(p, c, s, -0.8, 0.15); ln(p, c, s, -0.8, 0.8); ln(p, c, s, 0.8, 0.8); ln(p, c, s, 0.8, 0.15); mv(p, c, s, 0, -0.85); ln(p, c, s, 0, 0.35); mv(p, c, s, -0.35, 0); ln(p, c, s, 0, 0.35); ln(p, c, s, 0.35, 0); break;   // into a tray: interact
    case B_Y: ring(p, c, s, 0, 0, 0.9); ring(p, c, s, 0, 0, 0.45); mv(p, c, s, 0, 0); ln(p, c, s, 0.64, -0.64); break;   // radar: scan
    case B_A: mv(p, c, s, -0.25, -0.85); ln(p, c, s, 0.25, -0.85); ln(p, c, s, 0.25, -0.25); ln(p, c, s, 0.85, -0.25); ln(p, c, s, 0.85, 0.25); ln(p, c, s, 0.25, 0.25); ln(p, c, s, 0.25, 0.85);
              ln(p, c, s, -0.25, 0.85); ln(p, c, s, -0.25, 0.25); ln(p, c, s, -0.85, 0.25); ln(p, c, s, -0.85, -0.25); ln(p, c, s, -0.25, -0.25); CGPathCloseSubpath(p); break;   // repair cross
    case B_OD: ring(p, c, s, 0, 0, 0.22); for (int k = 0; k < 8; k++) { CGFloat a = k * M_PI / 4; mv(p, c, s, cos(a) * 0.45, sin(a) * 0.45); ln(p, c, s, cos(a) * (k & 1 ? 0.75 : 0.95), sin(a) * (k & 1 ? 0.75 : 0.95)); } break;   // burst: Overdrive
    case B_MINUS: CGPathAddArc(p, NULL, c.x, c.y, 0.7 * s, -M_PI * 0.35, M_PI * 1.45, false); mv(p, c, s, 0.18, -0.95); ln(p, c, s, 0.55, -0.6); ln(p, c, s, 0.12, -0.42); break;   // circular arrow: reset hacking
    case B_PLUS: mv(p, c, s, -0.32, -0.6); ln(p, c, s, -0.32, 0.6); mv(p, c, s, 0.32, -0.6); ln(p, c, s, 0.32, 0.6); break;   // pause
    case B_L: mv(p, c, s, -0.3, -0.6); ln(p, c, s, -0.3, 0.5); ln(p, c, s, 0.4, 0.5); break;
    default: if (g >= 100 && g < 104) { int d = g - 100; CGFloat dx = d == 3 ? 1 : d == 2 ? -1 : 0, dy = d == 1 ? 1 : d == 0 ? -1 : 0;   // a cursor arrow
            mv(p, c, s, -dx * 0.7, -dy * 0.7); ln(p, c, s, dx * 0.75, dy * 0.75);
            mv(p, c, s, dx * 0.75 - (dx ? dx * 0.45 : 0.45), dy * 0.75 - (dy ? dy * 0.45 : 0.45)); ln(p, c, s, dx * 0.75, dy * 0.75); ln(p, c, s, dx * 0.75 - (dx ? dx * 0.45 : -0.45), dy * 0.75 - (dy ? dy * 0.45 : -0.45)); }
    }
    return p;
}
static void placeLabel(CATextLayer *t, CGPoint c, CGFloat fs) {   // Orbit: a condensed face like PRAGMATA's HUD lettering (built into iOS), else the system's
    CTFontRef f = DM_GAME_TOUCH_STYLE ? CTFontCreateWithName(CFSTR("AvenirNextCondensed-DemiBold"), fs, NULL) : CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, fs, NULL);
    t.font = f; t.fontSize = fs;
    CGFloat h = CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f), w = fs * 3;
    t.frame = CGRectMake(c.x - w / 2, c.y - h / 2, w, h);
    CFRelease(f);
}

- (CGPoint)keyCentre:(int)b {   // where a key's icon goes, in the layout that is current
    if (b >= B_A && b <= B_Y) return [self facePos:b];
    if (self.orbit || b >= B_OD) return [self oKey:b];
    if (isDrop(b)) return [self dropCenter:b];
    if (isClick(b)) return [self clickCenter:b];
    CGRect r = [self pillRect:b]; return CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
}
- (CGFloat)keyRadius:(int)b {
    if (b >= B_A && b <= B_Y) return self.faceR;
    if (self.orbit || b >= B_OD) return [self oKeyR:b];
    if (isDrop(b)) return [self dropR:b];
    if (isClick(b)) return K_CLICK_R * self.u;
    return [self pillRect:b].size.height / 2;
}
// Orbit's shapes over the classic ones (in layoutSubviews' transaction): in landscape its places, and in every layout the line icons and letter tags (12 u tall, 13 or 17 u wide,
// at 0.7 r right and below the key's centre)
- (void)orbitLayout:(CGFloat)u {
    BOOL o = self.orbit; CGFloat scale = MAX(self.traitCollection.displayScale, 1);
    [self applyLayout];
    if (o) {
        static const int ob[] = {B_ZL, B_ZR, B_R, B_L, B_MINUS, B_PLUS};
        for (int i = 0; i < 6; i++) setPath(_key[ob[i]], circlePath([self oKey:ob[i]], [self oKeyR:ob[i]]));
        setPath(_od, circlePath([self oKey:B_OD], [self oKeyR:B_OD]));
        static const struct { int b; CGFloat angle; } arms[] = {{B_UP, 0}, {B_RIGHT, M_PI_2}, {B_DOWN, M_PI}, {B_LEFT, -M_PI_2}};   // four arrow tabs pointed at the centre
        CGPoint dc = self.dpadCenter; CGFloat dR = self.dpadR;
        for (int i = 0; i < 4; i++) {   // softer arm corners; in each arm a chevron pointing out, two thirds of the way along it
            setPath(_key[arms[i].b], armPath(dc, dR, O_ARM_W * u, O_ARM_IN * u, arms[i].angle, 7 * u));
            CGFloat hw = O_ARM_W * u * O_DPAD_HEAD_W, cs = cos(arms[i].angle), sn = sin(arms[i].angle);   // a solid arrowhead pointing out, as the Ocarina of Time port draws its D-pad
            CGPoint v[3] = {{0, -O_DPAD_HEAD_OUT * dR}, {hw, -O_DPAD_HEAD_IN * dR}, {-hw, -O_DPAD_HEAD_IN * dR}};
            CGMutablePathRef cp = CGPathCreateMutable();
            for (int k = 0; k < 3; k++) { CGPoint q = CGPointMake(dc.x + v[k].x * cs - v[k].y * sn, dc.y + v[k].x * sn + v[k].y * cs); if (k) CGPathAddLineToPoint(cp, NULL, q.x, q.y); else CGPathMoveToPoint(cp, NULL, q.x, q.y); }
            CGPathCloseSubpath(cp); _dchev[arms[i].b - B_LEFT].path = cp; CGPathRelease(cp);
            _dchev[arms[i].b - B_LEFT].lineWidth = 0; _dchev[arms[i].b - B_LEFT].strokeColor = nil;
        }
        _dpadGuide.path = NULL;   // no circle around it (the player's choice, V23)
        CGPoint zl = [self oKey:B_ZL];
        placeLabel(_lockHint, CGPointMake(zl.x, zl.y - [self oKeyR:B_ZL] - 8 * u), 7.5 * u); _lockHint.contentsScale = scale;
        setPath(_fire2, circlePath([self oKey:B_F2], [self oKeyR:B_F2])); _fire2.lineWidth = 2.4;   // drawn like the hub
        CGFloat k = O_KNOB_R * u; _knob.bounds = CGRectMake(0, 0, 2 * k, 2 * k); setPath(_knob, circlePath(CGPointMake(k, k), k));
        // the stick as the Ocarina of Time port draws it (V23, the player's choice; V7-V22 had an analog-nub knob): a plain translucent disc with a thin white outline and a soft
        // shadow, in a faint ring; nothing inside the knob
        _knobIn.hidden = YES; _knobShade.hidden = YES; _knobLip.hidden = YES;
        _knob.lineWidth = 1.5; _knob.strokeColor = k_okLine.CGColor;
        _knob.shadowColor = UIColor.blackColor.CGColor; _knob.shadowOpacity = 0.2f; _knob.shadowRadius = 3; _knob.shadowOffset = CGSizeMake(0, 1);
        CGPathRef ks = circlePath(CGPointMake(k, k), k); _knob.shadowPath = ks; CGPathRelease(ks);
    }
    _key[B_ZR].lineWidth = o ? 2.4 : 1.5;   // the hub stands out in bright rooms
    for (int b = 0; b <= B_F2; b++) { if (!_icon[b] || (b == B_F2 && !o)) continue;
        CGPoint c = [self keyCentre:b]; CGFloat r = [self keyRadius:b];
        setPath(_icon[b], iconPath(b == B_F2 ? B_ZR : b, c, r * 0.5)); _icon[b].shadowPath = NULL;   // the second fire key: the hub's crosshair
        CATextLayer *t = b == B_OD ? _odLabel : b == B_F2 ? _fire2Label : _label[b]; NSString *str = t.string; CGFloat w = (str.length > 1 ? 17 : 13) * u, h = 12 * u;
        CGPoint tc = CGPointMake(c.x + 0.7 * r, c.y + 0.7 * r);
        setPath(_tag[b], CGPathCreateWithRoundedRect(CGRectMake(tc.x - w / 2, tc.y - h / 2, w, h), h / 2, h / 2, NULL)); _tag[b].shadowPath = NULL;
        placeLabel(t, tc, 9.5 * u); if (t.contentsScale != scale) { t.contentsScale = scale; [t setNeedsDisplay]; }
    }
    static const int dir[4] = {3, 1, 0, 2};   // A right, B down, X up, Y left: the hacking cursor
    for (int i = 0; i < 4; i++) setPath(_arrow[i], iconPath(100 + dir[i], [self facePos:B_A + i], self.faceR * 0.5));
}
- (void)layoutSubviews {
    [super layoutSubviews];
    UIWindowScene *ws = self.window.windowScene; if (ws) atomic_store(&g_iface_orient, (int)ws.effectiveGeometry.interfaceOrientation);
    CGFloat u = self.u;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    CGFloat scale = MAX(self.traitCollection.displayScale, 1);
    for (int b = 0; b < B_N; b++) if (_label[b] && _label[b].contentsScale != scale) {
        _label[b].contentsScale = scale; [_label[b] setNeedsDisplay];
    }
    _controls.frame = self.layer.bounds;
    for (int b = B_A; b <= B_Y; b++) { CGPoint c = [self facePos:b]; setPath(_key[b], circlePath(c, self.faceR)); placeLabel(_label[b], c, 20 * u); }
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (isDrop(b)) {
            BOOL right = b == B_ZR || b == B_R; CGPoint c = [self dropCenter:b];
            setPath(_key[b], dropPath(c, [self dropR:b], right ? -M_PI_4 : -3 * M_PI_4, 4 * u)); placeLabel(_label[b], c, 16 * u);   // tip toward the near top corner
        } else if (isClick(b)) {
            CGPoint c = [self clickCenter:b]; setPath(_key[b], circlePath(c, K_CLICK_R * u)); placeLabel(_label[b], c, 13 * u);
        } else {
            CGRect rc = [self pillRect:b];
            setPath(_key[b], CGPathCreateWithRoundedRect(rc, rc.size.height / 2, rc.size.height / 2, NULL)); placeLabel(_label[b], CGPointMake(CGRectGetMidX(rc), CGRectGetMidY(rc)), 18 * u);
        }
    }
    static const struct { int b; CGFloat angle; } arms[] = {{B_UP, 0}, {B_RIGHT, M_PI_2}, {B_DOWN, M_PI}, {B_LEFT, -M_PI_2}};   // the same arm in 90° steps
    for (int i = 0; i < 4; i++) setPath(_key[arms[i].b], armPath(self.dpadCenter, self.dpadR, K_ARM_W * u, K_ARM_IN * u, arms[i].angle, 6 * u));
    CGFloat mr = self.menuR; CGPoint mc = self.menuCenter;
    _menu.frame = CGRectMake(mc.x - mr, mc.y - mr, 2 * mr, 2 * mr); _menu.layer.cornerRadius = mr;
    _menu.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:_menu.bounds].CGPath;
    [_menu setImage:[UIImage systemImageNamed:@"gearshape.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 * u weight:UIImageSymbolWeightSemibold]] forState:UIControlStateNormal];
    setPath(_ring, circlePath(self.stickHome, [self stickR:0]));
    CGFloat k = K_KNOB_R * u; _knob.bounds = CGRectMake(0, 0, 2 * k, 2 * k);
    setPath(_knob, circlePath(CGPointMake(k, k), k));
    CAShapeLayer *in = _knobIn; CGPathRef ip = circlePath(CGPointMake(k, k), k * 0.62);   // not the knob's first sublayer: Orbit's shade layer (a gradient, no path) comes first
    in.frame = _knob.bounds; in.path = ip; CGPathRelease(ip);
    if (DM_GAME_TOUCH_STYLE) [self orbitLayout:self.ou];   // its keys' unit
    [CATransaction commit];
    [self refresh];
}
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange]; [self setNeedsLayout]; }
// Orbit's pressed look and modes (in refresh's transaction): a pressed key gets the white glow, its outline and icon full white; hacking mode (ZL held or locked) swaps the face
// keys' icons for cursor arrows (no HACKING text) and shows the second fire key; a locked ZL stays lit and shows LOCKED; the floating stick's ring follows its centre. Nothing marks the aim area
// or where a held aim is centred: the right stick is not drawn, as in the classic layout
- (void)orbitRefresh:(uint64_t)all {
    BOOL o = self.orbit, od = NO, f2 = NO, hack0 = o && ((all >> B_ZL) & 1);   // hacking mode: the face keys' outlines in the accent
    for (UITouch *t in _owner) { uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; if ((v & 0xff) == C_BTN && (v >> 8) == B_OD) od = YES; if ((v & 0xff) == C_FIRE2) f2 = YES; }
    _fire2.hidden = !hack0 && !f2;   // shown while ZL is on (held or locked); a finger still on it keeps it until let go
    for (int b = 0; b <= B_F2; b++) { CAShapeLayer *k = b == B_OD ? _od : b == B_F2 ? _fire2 : _key[b]; BOOL on = b == B_OD ? od : b == B_F2 ? f2 : (all >> b) & 1;
        if (b >= B_OD) k.fillColor = (on ? k_on : k_idle).CGColor;
        k.strokeColor = (on ? k_onLine : hack0 && b >= B_A && b <= B_Y ? k_accent : k_line).CGColor; k.shadowOpacity = on ? 0.35f : 0; k.shadowRadius = 6; k.shadowOffset = CGSizeZero;   // a faint glow
        if (_icon[b]) _icon[b].strokeColor = (on ? k_onLine : k_text).CGColor;
        if (_tag[b]) _tag[b].strokeColor = k_line.CGColor; }
    _odLabel.foregroundColor = (od ? k_textOn : k_text).CGColor; _fire2Label.foregroundColor = (f2 ? k_textOn : k_text).CGColor;
    for (int i = 0; i < 4; i++) { _dchev[i].strokeColor = nil; _dchev[i].fillColor = (((all >> (B_LEFT + i)) & 1) ? k_onLine : k_text).CGColor; }   // a pressed D-pad arm's arrowhead in full white
    for (int i = 0; i < 4; i++) { _arrow[i].hidden = !hack0; _icon[B_A + i].hidden = hack0; _arrow[i].strokeColor = (((all >> (B_A + i)) & 1) ? k_onLine : k_text).CGColor; }
    _lockHint.hidden = !(o && _zlLocked);
    if (o) {   // the floating stick, two plain circles: its ring follows its centre; running (past O_RUN times the rim, LS) only tints the ring near-white (no text, no marks)
        CGPoint c = [self stickCentre:0]; CGFloat R = [self stickR:0];
        BOOL run = _stick[0] && dist(_stickNow[0], c) > R * O_RUN;
        CGPathRef r = circlePath(c, R); _ring.path = r; _ring.shadowPath = r; CGPathRelease(r);
        _ring.lineWidth = 1.5; _ring.fillColor = k_okRing.CGColor; _ring.strokeColor = (run ? k_accent : k_okLine).CGColor;   // the Ocarina of Time port's ring (V23): faint fill, thin outline, soft shadow
        _ring.shadowColor = UIColor.blackColor.CGColor; _ring.shadowOpacity = 0.2f; _ring.shadowRadius = 3; _ring.shadowOffset = CGSizeMake(0, 1);
    }
}
- (void)refresh {   // pressed state → fill, sticks → knob position
    uint64_t all = _faceBits | _dpadBits | _btnBits;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) { BOOL on = (all >> b) & 1;
        _key[b].fillColor = (on ? k_on : k_idle).CGColor; _label[b].foregroundColor = (on ? k_textOn : k_text).CGColor; }
    CGPoint h = [self stickCentre:0], o = [self knobOffset:0];
    _knob.position = CGPointMake(h.x + o.x, h.y + o.y); _knob.fillColor = (_stick[0] ? k_on : k_idle).CGColor;
    if (self.orbit && k_okKnob) _knob.fillColor = (_stick[0] ? k_okKnobOn : k_okKnob).CGColor;   // Orbit: the Ocarina of Time port's knob (V23)
    if (DM_GAME_TOUCH_STYLE) [self orbitRefresh:all];
    [CATransaction commit];
}

// ---- Physical controllers ----
// Each controller with an extended gamepad profile is a player of its own, as on the Mac (front_mac.m): it holds a slot (pad_slots.h: player 1 first, a reconnected controller
// gets its player back) and goes to dm_pad_set_player, and hle_hid.c reports player n on its own npad while the slot is held (dm_pad_players). Player 1's controller is ORed
// with the touch gamepad; a one-player game that supports only No1 / Handheld still sees every controller as player 1 (hle_hid.c). Each player has its controller's rumble and
// gyro; the phone's gyro is player 1's. With DM_PAD_MERGE=1 every controller is player 1, as before (the last one moved wins). With DM_PAD_PRESS_TO_JOIN=1 a controller is
// no player until one of its buttons is pressed, then it is the lowest player free (pad_slot_take_lowest), as on the Mac: the players choose their order
static pad_slots g_slots;
static GCController *g_held[DM_PLAYERS];   // the controller of each slot, kept alive while it holds it (the slot table keys on its pointer)
static int g_merge, g_press_to_join;
static int32_t axis(float v) { return (int32_t)(fmaxf(-1.f, fminf(1.f, v)) * 32767); }
static const char *pad_name(GCController *c);
static void npad_name(int p, char *out, size_t cap);
static int cp_poll(void);
static void read_pad(GCExtendedGamepad *g) {
    int p = g_merge ? 0 : pad_slot_of(&g_slots, (__bridge const void *)g.controller); if (p < 0 && !g_press_to_join) return;
    _Static_assert(DM_BTN_A == 1u << B_A && DM_BTN_B == 1u << B_B && DM_BTN_X == 1u << B_X && DM_BTN_Y == 1u << B_Y, "face button bits");
    uint64_t m = dm_pad_face(g);   // by position, a Nintendo pad by its labels
    #define K(btn, bit) if (btn.isPressed) m |= 1ull << bit
    K(g.leftShoulder, B_L); K(g.rightShoulder, B_R); K(g.leftTrigger, B_ZL); K(g.rightTrigger, B_ZR);
    K(g.buttonMenu, B_PLUS); if (g.buttonOptions) K(g.buttonOptions, B_MINUS);
    if (g.leftThumbstickButton) K(g.leftThumbstickButton, B_LS); if (g.rightThumbstickButton) K(g.rightThumbstickButton, B_RS);
    K(g.dpad.left, B_LEFT); K(g.dpad.up, B_UP); K(g.dpad.right, B_RIGHT); K(g.dpad.down, B_DOWN);
    #undef K
    if (p < 0) {   // DM_PAD_PRESS_TO_JOIN=1: it joins at its first button, a press the game also gets
        GCController *c = g.controller; char nb[16];
        if (!m) return;
        if ((p = pad_slot_take_lowest(&g_slots, (__bridge const void *)c, pad_name(c))) < 0) { LOG("controller '%s': a button pressed, but all %d players are taken", pad_name(c), DM_PLAYERS); return; }
        g_held[p] = c; dm_motion_attach(c, p); dm_pad_players(pad_slot_mask(&g_slots));
        npad_name(p, nb, sizeof nb); LOG("controller '%s': a button pressed: player %d (npad %s)", pad_name(c), p + 1, nb);
    }
    if (cp_poll()) return;   // the controller applet's prompt has the controllers (front_ctrl_support)
    dm_haptics_apple_controller(p, g.controller);
    dm_pad_set_player(p, m, axis(g.leftThumbstick.xAxis.value), axis(g.leftThumbstick.yAxis.value), axis(g.rightThumbstick.xAxis.value), axis(g.rightThumbstick.yAxis.value));
}
// Home and Capture: without this iOS takes them as system gestures (Home opens the Games overlay, Capture a screenshot); the app gives them no function
static void pad_keep_system_buttons(GCController *c) { for (NSString *b in @[GCInputButtonHome, GCInputButtonShare]) c.physicalInputProfile.buttons[b].preferredSystemGestureState = GCSystemGestureStateDisabled; }
static const char *pad_name(GCController *c) { return c.vendorName.UTF8String ?: "?"; }
static void npad_name(int p, char *out, size_t cap) { uint32_t id = dm_player_npad(p); if (id == 0x20) snprintf(out, cap, "handheld"); else snprintf(out, cap, "%u", id); }
static void pads_start(void) {
    const char *e = getenv("DM_PAD_MERGE"); g_merge = e && atoi(e);
    e = getenv("DM_PAD_PRESS_TO_JOIN"); g_press_to_join = !g_merge && e && atoi(e);
    LOG("front end: %s", g_merge ? "every controller is player 1 (DM_PAD_MERGE)" : "each controller is a player of its own, the touch gamepad plays with player 1");
    if (g_press_to_join) LOG("front end: a controller becomes a player at its first button press, the lowest player free (DM_PAD_PRESS_TO_JOIN)");
}
// Called at start and on every connect / disconnect (gone: the controller that was just removed, nil otherwise); returns whether a controller is in use
static BOOL pads_merged(GCController *gone) {
    if (gone) { gone.extendedGamepad.valueChangedHandler = nil; dm_motion_detach(gone, 0); }
    BOOL any = NO; int motion = 0;
    for (GCController *c in GCController.controllers) if (c != gone && c.extendedGamepad) {
        if (c.motion.hasRotationRate) motion = 1;
        any = YES; pad_keep_system_buttons(c); c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; read_pad(g); };
        dm_motion_attach(c, 0);   // every controller is player 1: the last one moved drives its six-axis sensor
        read_pad(c.extendedGamepad);
    }
    if (!any || !motion) dm_motion_clear(0);   // the phone's gyro (if on) takes over from its next sample
    if (!any) { dm_haptics_apple_controller(0, nil); dm_pad_set(0, 0, 0, 0, 0); }
    return any;
}
static BOOL pads_slotted(GCController *gone) {
    NSArray<GCController *> *now = GCController.controllers; char nb[16]; BOOL waiting = NO;
    for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p] && (g_held[p] == gone || ![now containsObject:g_held[p]])) {
        npad_name(p, nb, sizeof nb); LOG("controller '%s' disconnected: player %d (npad %s) is free", pad_name(g_held[p]), p + 1, nb);
        g_held[p].extendedGamepad.valueChangedHandler = nil;
        dm_motion_detach(g_held[p], p);   // player 1's: the phone's gyro (if on) takes over from its next sample
        dm_haptics_apple_controller(p, nil);
        pad_slot_free(&g_slots, (__bridge const void *)g_held[p]); g_held[p] = nil;
        dm_pad_set_player(p, 0, 0, 0, 0, 0);   // nothing stays pressed
    }
    for (GCController *c in now) if (c.extendedGamepad && c != gone && pad_slot_of(&g_slots, (__bridge const void *)c) < 0) {
        if (g_press_to_join) {   // a player at its first button (read_pad)
            waiting = YES; pad_keep_system_buttons(c);
            if (!c.extendedGamepad.valueChangedHandler) LOG("controller '%s' connected: press a button to play (DM_PAD_PRESS_TO_JOIN)", pad_name(c));
            c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; read_pad(g); };
            continue;
        }
        int p = pad_slot_take(&g_slots, (__bridge const void *)c, pad_name(c));
        if (p < 0) { LOG("controller '%s' connected: all %d players are taken, not used", pad_name(c), DM_PLAYERS); continue; }
        g_held[p] = c; pad_keep_system_buttons(c);
        c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; read_pad(g); };
        dm_motion_attach(c, p);
        npad_name(p, nb, sizeof nb); LOG("controller '%s' connected: player %d (npad %s)%s", pad_name(c), p + 1, nb, c.motion.hasRotationRate ? ", with motion (gyro)" : "");
        read_pad(c.extendedGamepad);
    }
    dm_pad_players(pad_slot_mask(&g_slots));
    dispatch_async(dispatch_get_main_queue(), ^{ cp_poll(); });   // a controller came or went while the controller applet's prompt is up
    return waiting || pad_slot_mask(&g_slots) != 0;   // a controller waiting for its first press hides the touch gamepad too
}
- (void)padsChanged:(NSNotification *)note {
    GCController *c = note.object, *gone = [note.name isEqual:GCControllerDidDisconnectNotification] ? c : nil;
    if (c && (!c.extendedGamepad || g_merge)) LOG("controller %s: %s%s", gone ? "disconnected" : "connected", pad_name(c), c.extendedGamepad ? "" : " (no extended gamepad profile: not used)");
    BOOL any = g_merge ? pads_merged(gone) : pads_slotted(gone);
    dispatch_async(dispatch_get_main_queue(), ^{ self->_padOff = any; self->_controls.hidden = any; [self reset]; });   // the touch gamepad hides while any controller is in use
}
@end

// The controller applet's prompt (front.h front_ctrl_support, ctrl_prompt.h; GitHub issue #1640), as the Mac's (front_mac.m): the game asked for more players than it sees, and
// the game's thread waits while a card is up over the game. A controller that joins meanwhile is a player at once (its first button with DM_PAD_PRESS_TO_JOIN, its connection
// without) and the count follows. A and B are GameController's buttonA and buttonB on any controller (the press that makes a controller join does not count); the card's
// Done and Cancel buttons take touches, and its scrim keeps every other touch from the game and the touch gamepad. The game gets no controller input while it is up, nor
// until the A or B that closed it is let go. A front end passes the texts in the player's language as DM_CTRL_PROMPT_TEXT (cp_text). Main thread
static ctrl_prompt g_cp; static int g_cp_confirm, g_cp_cancel, g_cp_ok;
static UIView *g_cp_view; static UILabel *g_cp_count; static UIButton *g_cp_done_btn; static dispatch_semaphore_t g_cp_done;
@interface DmCtrlPrompt : NSObject @end
@implementation DmCtrlPrompt
- (void)done { g_cp_confirm = 1; cp_poll(); }
- (void)cancel { g_cp_cancel = 1; cp_poll(); }
@end
static DmCtrlPrompt *g_cp_target;
static void cp_buttons(int *a, int *b) {
    *a = *b = 0;
    for (GCController *c in GCController.controllers) { GCExtendedGamepad *g = c.extendedGamepad; if (g) { *a |= g.buttonA.isPressed; *b |= g.buttonB.isPressed; } }
}
static int cp_waiting(void) {   // connected controllers that are no player yet
    int n = 0;
    if (!g_merge) for (GCController *c in GCController.controllers) if (c.extendedGamepad && pad_slot_of(&g_slots, (__bridge const void *)c) < 0) n++;
    return n;
}
static UILabel *cp_label(const char *text, CGFloat size, UIFontWeight w, CGFloat alpha) {
    UILabel *l = [UILabel new]; l.text = @(text); l.font = [UIFont systemFontOfSize:size weight:w]; l.textColor = [UIColor colorWithWhite:1 alpha:alpha];
    l.numberOfLines = 0; l.textAlignment = NSTextAlignmentCenter; return l;
}
static UIButton *cp_button(const char *title, SEL action, int primary) {
    UIButtonConfiguration *cfg = primary ? UIButtonConfiguration.filledButtonConfiguration : UIButtonConfiguration.grayButtonConfiguration;
    cfg.title = @(title); cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule; cfg.buttonSize = UIButtonConfigurationSizeLarge;
    UIButton *b = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
    [b addTarget:g_cp_target action:action forControlEvents:UIControlEventTouchUpInside]; return b;
}
static void cp_show(void) {   // the card once per prompt; its count and its Done button follow each step
    const char *env = getenv("DM_CTRL_PROMPT_TEXT"); char t[CP_TEXTS][256];
    for (int i = 0; i < CP_TEXTS; i++) cp_text(env, i, &g_cp, t[i], sizeof t[i]);
    if (!g_cp_view) {
        UIWindow *w = g_view.window;
        if (!w) for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) if ([sc isKindOfClass:UIWindowScene.class]) for (UIWindow *x in ((UIWindowScene *)sc).windows) if (x.isKeyWindow) w = x;
        if (!w) return;
        if (!g_cp_target) g_cp_target = [DmCtrlPrompt new];
        UIView *scrim = [[UIView alloc] initWithFrame:w.bounds]; scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        scrim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
        g_cp_count = cp_label(t[CP_TEXT_COUNT], 20, UIFontWeightSemibold, 0.9);
        g_cp_done_btn = cp_button(t[CP_TEXT_DONE], @selector(done), 1);
        UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[g_cp_done_btn, cp_button(t[CP_TEXT_CANCEL], @selector(cancel), 0)]];
        actions.spacing = 16; actions.distribution = UIStackViewDistributionFillEqually;
        UIStackView *card = [[UIStackView alloc] initWithArrangedSubviews:@[cp_label(t[CP_TEXT_TITLE], 26, UIFontWeightBold, 1), cp_label(t[CP_TEXT_HINT], 17, UIFontWeightRegular, 0.6), g_cp_count, actions]];
        card.axis = UILayoutConstraintAxisVertical; card.spacing = 14; [card setCustomSpacing:28 afterView:g_cp_count];
        card.layoutMargins = UIEdgeInsetsMake(32, 36, 28, 36); card.layoutMarginsRelativeArrangement = YES;
        card.backgroundColor = [UIColor colorWithRed:0.10 green:0.10 blue:0.11 alpha:1]; card.layer.cornerRadius = 28;
        card.translatesAutoresizingMaskIntoConstraints = NO;
        [scrim addSubview:card];
        NSLayoutConstraint *wide = [card.widthAnchor constraintEqualToConstant:520]; wide.priority = UILayoutPriorityDefaultHigh;   // narrower on a narrow screen
        [NSLayoutConstraint activateConstraints:@[[card.centerXAnchor constraintEqualToAnchor:scrim.centerXAnchor], [card.centerYAnchor constraintEqualToAnchor:scrim.centerYAnchor],
            [card.widthAnchor constraintLessThanOrEqualToAnchor:scrim.widthAnchor constant:-32], wide]];
        [w addSubview:scrim]; g_cp_view = scrim;
    }
    g_cp_count.text = @(t[CP_TEXT_COUNT]);
    g_cp_done_btn.enabled = cp_can_confirm(&g_cp);
}
// One step of the prompt (a button, a touch on the card, a controller joining, coming or going); returns whether it keeps the game's input
static int cp_poll(void) {
    if (g_cp.phase == CP_IDLE) return 0;
    int a, b, joined = dm_players_reported(); cp_buttons(&a, &b);
    int confirm = g_cp_confirm, cancel = g_cp_cancel; g_cp_confirm = g_cp_cancel = 0;
    cp_phase was = g_cp.phase, ph = cp_step(&g_cp, joined, cp_waiting(), a, b, confirm, cancel);
    if (was == CP_OPEN && ph == CP_OPEN) cp_show();
    if (was == CP_OPEN && ph != CP_OPEN) {
        [g_cp_view removeFromSuperview]; g_cp_view = nil; g_cp_count = nil; g_cp_done_btn = nil;
        LOG("front end: controller prompt closed: %d players (%s)", joined, g_cp.ok ? "done" : "canceled");
        g_cp_ok = g_cp.ok; dispatch_semaphore_signal(g_cp_done);
        ph = cp_step(&g_cp, joined, 0, a, b, 0, 0);   // nothing held: the game has its input at once
    }
    if (ph == CP_IDLE) { for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p].extendedGamepad) read_pad(g_held[p].extendedGamepad); return 0; }   // each controller read as it is now
    return 1;
}
int front_ctrl_support(int min, int max) {
    if (!front_metal_layer()) return -1;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        [g_view reset]; dm_touch_set(NULL, 0);   // nothing the game held stays pressed while the prompt has the input
        if (g_merge) dm_pad_set(0, 0, 0, 0, 0); else for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p]) dm_pad_set_player(p, 0, 0, 0, 0, 0);
        int a, b; cp_buttons(&a, &b);
        g_cp_done = done; cp_open(&g_cp, min, max, dm_players_reported(), a, b);
        LOG("front end: controller prompt open: %d to %d players wanted, %d in, %d controllers waiting to join", min, max, g_cp.joined, cp_waiting());
        cp_show(); cp_poll();
    });
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return g_cp_ok;
}

UIView *dm_gamepad_view(CGRect frame) { DmGamepad *v = [[DmGamepad alloc] initWithFrame:frame]; g_view = v; return v; }
void dm_gamepad_arrange(UIView *view, DmLayout layout) { [(DmGamepad *)view arrange:layout]; }
void dm_gamepad_opmode_changed(void) { [g_view opmodeChanged]; }
void dm_gamepad_touch_feedback(bool on) { [g_view setTouchFeedback:on]; }
int dm_pad_layout(void) { return g_view ? [g_view padLayout] : 0; }
bool dm_pad_layout_offered(int layout) { return layout == 0 || layout == 1 || (layout == 2 && dm_opmode() == 0); }
void dm_pad_layout_set(int layout) { [g_view setPadLayout:layout]; }
void dm_gamepad_active(void) { dispatch_async(dispatch_get_main_queue(), ^{ for (GCController *c in GCController.controllers) dm_motion_rearm(c); }); }   // On become active: motion_apple.h
void dm_gamepad_reset(void) {   // On resign active: release everything (a key held while switching away and released in background gets no "release")
    dispatch_async(dispatch_get_main_queue(), ^{ [g_view reset]; });
    pthread_mutex_lock(&g_mu); g_shake_btn = 0; pthread_mutex_unlock(&g_mu); publish();
    if (g_merge) dm_pad_set(0, 0, 0, 0, 0);
    else for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p]) dm_pad_set_player(p, 0, 0, 0, 0, 0);
}
