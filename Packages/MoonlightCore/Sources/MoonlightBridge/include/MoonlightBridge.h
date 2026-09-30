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

#ifdef __cplusplus
}
#endif
