//
//  MoonlightBridge.h
//  MoonlightCore
//
//  The narrow interface between Swift and moonlight-common-c. It covers one
//  streaming session at a time, since moonlight-common-c keeps global state.
//
//  Video is delivered as whole frames ready for VideoToolbox, and audio is
//  decoded here and pulled by the audio renderer with SLStreamRenderAudio().
//

#pragma once

#include <CoreFoundation/CFAvailability.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma mark - Configuration

/// Video formats, matching moonlight-common-c's VIDEO_FORMAT_* values.
typedef CF_ENUM(int32_t, SLVideoFormat) {
    SLVideoFormatH264 = 0x0001,
    SLVideoFormatH264High8_444 = 0x0004,
    SLVideoFormatH265 = 0x0100,
    SLVideoFormatH265Main10 = 0x0200,
    SLVideoFormatH265RExt8_444 = 0x0400,
    SLVideoFormatH265RExt10_444 = 0x0800,
    SLVideoFormatAV1Main8 = 0x1000,
    SLVideoFormatAV1Main10 = 0x2000,
    SLVideoFormatAV1High8_444 = 0x4000,
    SLVideoFormatAV1High10_444 = 0x8000,
};

#define SL_VIDEO_FORMAT_MASK_H264  0x000F
#define SL_VIDEO_FORMAT_MASK_H265  0x0F00
#define SL_VIDEO_FORMAT_MASK_AV1   0xF000
#define SL_VIDEO_FORMAT_MASK_10BIT 0xAA00

typedef CF_ENUM(int32_t, SLColorSpace) {
    SLColorSpaceRec601 = 0,
    SLColorSpaceRec709 = 1,
    SLColorSpaceRec2020 = 2,
};

typedef struct {
    /// Host address without a port.
    const char* address;
    /// `appversion` from /serverinfo.
    const char* appVersion;
    /// `GfeVersion` from /serverinfo, may be NULL.
    const char* gfeVersion;
    /// `sessionUrl0` from /launch or /resume, may be NULL.
    const char* rtspSessionURL;
    /// `ServerCodecModeSupport` from /serverinfo.
    int32_t serverCodecModeSupport;

    int32_t width;
    int32_t height;
    int32_t fps;
    int32_t bitrateKbps;
    /// 2, 6 or 8.
    int32_t audioChannelCount;
    /// Bitmask of SLVideoFormat values the client can decode.
    int32_t supportedVideoFormats;
    SLColorSpace colorSpace;
    bool fullColorRange;

    /// The `rikey` and `rikeyid` sent with /launch or /resume.
    uint8_t remoteInputKey[16];
    uint32_t remoteInputKeyID;
} SLStreamConfiguration;

#pragma mark - Callbacks

/// Motion sensors, matching moonlight-common-c's LI_MOTION_TYPE_* values.
typedef CF_ENUM(uint8_t, SLMotionType) {
    SLMotionTypeAccelerometer = 0x01,
    SLMotionTypeGyroscope = 0x02,
};

/// Which DualSense triggers an adaptive trigger event programs, matching
/// moonlight-common-c's DS_EFFECT_* values.
typedef CF_OPTIONS(uint8_t, SLAdaptiveTriggers) {
    SLAdaptiveTriggerRight = 0x04,
    SLAdaptiveTriggerLeft = 0x08,
};

/// Length of a DualSense trigger effect's parameters.
#define SL_ADAPTIVE_TRIGGER_EFFECT_SIZE 10

typedef CF_ENUM(int32_t, SLVideoBufferType) {
    SLVideoBufferTypeSPS = 1,
    SLVideoBufferTypePPS = 2,
    SLVideoBufferTypeVPS = 3,
};

typedef struct {
    /// NAL unit without its start code.
    const uint8_t* data;
    int32_t length;
    SLVideoBufferType type;
} SLParameterSet;

typedef struct {
    bool isKeyFrame;
    /// Increases by one per frame the host sent, so gaps are frames lost on the way.
    int32_t frameNumber;
    /// Time the host took to capture and encode the frame in milliseconds, or 0 when unknown.
    float hostProcessingLatencyMs;

    /// H.264 and HEVC parameter sets, only present on key frames.
    const SLParameterSet* parameterSets;
    int32_t parameterSetCount;

    /// The frame as 4-byte length prefixed NAL units for H.264 and HEVC, or
    /// as OBUs for AV1. Only valid for the duration of the callback.
    const uint8_t* data;
    int32_t length;
} SLVideoFrame;

typedef CF_ENUM(int32_t, SLDecodeResult) {
    SLDecodeResultOK = 0,
    SLDecodeResultNeedKeyFrame = -1,
};

/// Callbacks run on moonlight-common-c's threads and must not stop the stream
/// themselves.
typedef struct {
    void* context;

    void (*stageStarting)(void* context, int32_t stage, const char* name);
    void (*stageFailed)(void* context, int32_t stage, const char* name, int32_t errorCode, uint32_t portFlags);
    void (*connectionStarted)(void* context);
    /// `errorCode` is 0 when the host ended the session normally.
    void (*connectionTerminated)(void* context, int32_t errorCode, uint32_t portFlags);
    void (*connectionStatusChanged)(void* context, bool isPoor);
    void (*hdrModeChanged)(void* context, bool enabled);
    void (*log)(void* context, const char* message);

    /// Returns 0 on success.
    int32_t (*videoSetup)(void* context, SLVideoFormat format, int32_t width, int32_t height, int32_t fps);
    void (*videoCleanup)(void* context);
    SLDecodeResult (*videoSubmitFrame)(void* context, const SLVideoFrame* frame);

    /// Called once decoded audio is available through SLStreamRenderAudio().
    /// Returns 0 on success.
    int32_t (*audioSetup)(void* context, int32_t channelCount, int32_t sampleRate);
    /// SLStreamRenderAudio() must not be called anymore once this returns.
    void (*audioCleanup)(void* context);

    // Gamepad feedback from the host. It may name gamepads that aren't there.

    /// Motor strengths are 0...65535 and last until changed, 0 turning them off.
    void (*gamepadRumble)(void* context, uint16_t gamepad, uint16_t lowFrequencyMotor, uint16_t highFrequencyMotor);
    void (*gamepadTriggerRumble)(void* context, uint16_t gamepad, uint16_t leftTriggerMotor, uint16_t rightTriggerMotor);
    /// The host wants the sensor reported at about `reportRateHz`, or stopped when 0.
    void (*gamepadMotionRequested)(void* context, uint16_t gamepad, SLMotionType type, uint16_t reportRateHz);
    void (*gamepadLightChanged)(void* context, uint16_t gamepad, uint8_t red, uint8_t green, uint8_t blue);
    /// DualSense trigger effects for the `triggers` given, each a type byte
    /// followed by SL_ADAPTIVE_TRIGGER_EFFECT_SIZE bytes of parameters, as
    /// the DualSense takes them. The parameters are only valid during the call.
    void (*gamepadAdaptiveTriggers)(void* context, uint16_t gamepad, SLAdaptiveTriggers triggers,
                                    uint8_t leftType, const uint8_t* left, uint8_t rightType, const uint8_t* right);
} SLStreamCallbacks;

#pragma mark - Session

/// Starts a session, blocking until it's established or has failed. Returns 0
/// on success. The callbacks stay in use until SLStreamStop() returns.
int32_t SLStreamStart(const SLStreamConfiguration* configuration, const SLStreamCallbacks* callbacks);

/// Tears down the session, blocking until all of its threads have exited.
/// Makes a pending SLStreamStart() return early. Must not be called from a
/// callback.
void SLStreamStop(void);

/// Extra parameters to append to the /launch and /resume query.
const char* SLStreamLaunchQueryParameters(void);

/// The `surroundAudioInfo` value for /launch and /resume.
int32_t SLStreamSurroundAudioInfo(int32_t channelCount);

/// Human readable list of the ports in `portFlags`, e.g. "UDP 47998, UDP 48000".
void SLStreamDescribePorts(uint32_t portFlags, char* buffer, int32_t bufferLength);

void SLStreamRequestKeyFrame(void);

/// The estimated round trip time to the host in milliseconds. Returns false
/// when there's no connection to measure. Can be called from any thread.
bool SLStreamGetRoundTripTime(uint32_t* roundTripTimeMs, uint32_t* varianceMs);

typedef struct {
    /// Big-endian `mdcv` box contents for kCMFormatDescriptionExtension_MasteringDisplayColorVolume.
    bool hasMasteringDisplayColorVolume;
    uint8_t masteringDisplayColorVolume[24];
    /// Big-endian `clli` box contents for kCMFormatDescriptionExtension_ContentLightLevelInfo.
    bool hasContentLightLevelInfo;
    uint8_t contentLightLevelInfo[4];
} SLHDRMetadata;

/// HDR metadata of the host display, returns false if HDR isn't active.
bool SLStreamGetHDRMetadata(SLHDRMetadata* metadata);

#pragma mark - Audio

/// Fills non-interleaved float buffers with decoded audio, padding with
/// silence when not enough is buffered. Real-time safe.
void SLStreamRenderAudio(float* const* channels, int32_t channelCount, int32_t frameCount);

#pragma mark - Input

// Input is dropped unless a session is established. These functions only
// queue the event and can be called from any thread.

/// Touch event types, matching moonlight-common-c's LI_TOUCH_EVENT_* values.
typedef CF_ENUM(uint8_t, SLTouchEventType) {
    SLTouchEventTypeDown = 0x01,
    SLTouchEventTypeUp = 0x02,
    SLTouchEventTypeMove = 0x03,
    SLTouchEventTypeCancel = 0x04,
    SLTouchEventTypeCancelAll = 0x07,
};

/// Mouse buttons, matching moonlight-common-c's BUTTON_* values.
typedef CF_ENUM(int32_t, SLMouseButton) {
    SLMouseButtonLeft = 0x01,
    SLMouseButtonMiddle = 0x02,
    SLMouseButtonRight = 0x03,
    SLMouseButtonX1 = 0x04,
    SLMouseButtonX2 = 0x05,
};

/// Keyboard modifiers, matching moonlight-common-c's MODIFIER_* values.
typedef CF_OPTIONS(uint8_t, SLKeyModifiers) {
    SLKeyModifierShift = 0x01,
    SLKeyModifierControl = 0x02,
    SLKeyModifierAlt = 0x04,
    SLKeyModifierMeta = 0x08,
    /// The key has an 0xE0 scancode prefix, like the right Control key.
    SLKeyModifierExtended = 0x10,
};

/// Only Sunshine hosts accept touches. `x` and `y` are normalized to the video area, (0, 0) being the top left.
/// `pressure` is 0...1, or 0 when unknown. Contact area axes are normalized
/// like the coordinates, or 0 when unknown.
void SLInputSendTouch(SLTouchEventType type, uint32_t pointerID, float x, float y,
                      float pressure, float contactAreaMajor, float contactAreaMinor);

/// Relative motion, positive `deltaY` moving down.
void SLInputSendMouseMove(int16_t deltaX, int16_t deltaY);

/// Absolute position within a `referenceWidth` by `referenceHeight` plane
/// covering the video.
void SLInputSendMousePosition(int16_t x, int16_t y, int16_t referenceWidth, int16_t referenceHeight);

void SLInputSendMouseButton(SLMouseButton button, bool pressed);

/// 120 is one wheel notch. Positive values scroll up and right.
void SLInputSendScroll(int16_t vertical, int16_t horizontal);

/// `keyCode` is a Windows virtual key code on a US layout. Keys missing from
/// that layout, like the JIS Yen key, are sent `nonNormalized` so that the
/// host doesn't translate them.
void SLInputSendKey(int16_t keyCode, bool pressed, SLKeyModifiers modifiers, bool nonNormalized);

/// Types `length` bytes of UTF-8 text on the host, whatever its layout.
void SLInputSendText(const char *text, uint32_t length);

#pragma mark - Gamepads

/// Gamepads are numbered 0...15, and every event carries a mask with the bit
/// of each one present.
#define SL_MAX_GAMEPADS 16

/// Gamepad buttons, matching moonlight-common-c's *_FLAG values.
typedef CF_OPTIONS(uint32_t, SLGamepadButtons) {
    SLGamepadButtonUp = 0x0001,
    SLGamepadButtonDown = 0x0002,
    SLGamepadButtonLeft = 0x0004,
    SLGamepadButtonRight = 0x0008,
    SLGamepadButtonStart = 0x0010,
    SLGamepadButtonBack = 0x0020,
    SLGamepadButtonLeftStick = 0x0040,
    SLGamepadButtonRightStick = 0x0080,
    SLGamepadButtonLeftShoulder = 0x0100,
    SLGamepadButtonRightShoulder = 0x0200,
    SLGamepadButtonGuide = 0x0400,
    SLGamepadButtonA = 0x1000,
    SLGamepadButtonB = 0x2000,
    SLGamepadButtonX = 0x4000,
    SLGamepadButtonY = 0x8000,
    SLGamepadButtonPaddle1 = 0x010000,
    SLGamepadButtonPaddle2 = 0x020000,
    SLGamepadButtonPaddle3 = 0x040000,
    SLGamepadButtonPaddle4 = 0x080000,
    /// The touchpad click on Sony gamepads.
    SLGamepadButtonTouchpad = 0x100000,
    /// Share, capture or mute.
    SLGamepadButtonMisc = 0x200000,
};

/// Matching moonlight-common-c's LI_CTYPE_* values.
typedef CF_ENUM(uint8_t, SLGamepadType) {
    SLGamepadTypeUnknown = 0x00,
    SLGamepadTypeXbox = 0x01,
    SLGamepadTypePlayStation = 0x02,
    SLGamepadTypeNintendo = 0x03,
};

/// Matching moonlight-common-c's LI_CCAP_* values.
typedef CF_OPTIONS(uint16_t, SLGamepadCapabilities) {
    SLGamepadCapabilityAnalogTriggers = 0x01,
    SLGamepadCapabilityRumble = 0x02,
    SLGamepadCapabilityTriggerRumble = 0x04,
    SLGamepadCapabilityTouchpad = 0x08,
    SLGamepadCapabilityAccelerometer = 0x10,
    SLGamepadCapabilityGyroscope = 0x20,
    SLGamepadCapabilityBattery = 0x40,
    SLGamepadCapabilityLight = 0x80,
};

/// Matching moonlight-common-c's LI_BATTERY_STATE_* values.
typedef CF_ENUM(uint8_t, SLBatteryState) {
    SLBatteryStateUnknown = 0x00,
    SLBatteryStateNotPresent = 0x01,
    SLBatteryStateDischarging = 0x02,
    SLBatteryStateCharging = 0x03,
    SLBatteryStateNotCharging = 0x04,
    SLBatteryStateFull = 0x05,
};

/// Tells the host about a new gamepad, so it can pick a matching virtual one.
/// Returns false when it couldn't be sent, e.g. before the input stream is up.
bool SLInputSendGamepadArrival(uint8_t gamepad, uint16_t activeGamepadMask, SLGamepadType type,
                               SLGamepadButtons supportedButtons, SLGamepadCapabilities capabilities);

/// The full state of a gamepad. Triggers are 0...255, sticks -32767...32767
/// with positive `y` up. A gamepad is removed by sending it zeroed, with its
/// bit cleared in `activeGamepadMask`.
void SLInputSendGamepadState(uint8_t gamepad, uint16_t activeGamepadMask, SLGamepadButtons buttons,
                             uint8_t leftTrigger, uint8_t rightTrigger,
                             int16_t leftStickX, int16_t leftStickY, int16_t rightStickX, int16_t rightStickY);

/// Accelerometer readings in m/s² including gravity, gyroscope readings in
/// deg/s, along SDL's axes.
void SLInputSendGamepadMotion(uint8_t gamepad, SLMotionType type, float x, float y, float z);

/// `percentage` is 0...100, or 255 when unknown.
void SLInputSendGamepadBattery(uint8_t gamepad, SLBatteryState state, uint8_t percentage);

/// A finger on the gamepad's touchpad, with `x` and `y` normalized like
/// SLInputSendTouch(). Returns false if the host doesn't support it.
bool SLInputSendGamepadTouch(uint8_t gamepad, SLTouchEventType type, uint32_t pointerID,
                             float x, float y, float pressure);

#ifdef __cplusplus
}
#endif
