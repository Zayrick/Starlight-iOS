//
//  MoonlightBridge.c
//  MoonlightCore
//

#include "MoonlightBridge.h"

#include <MoonlightCommon.h>
#include <opus_multistream.h>

#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(SLVideoFormatH264 == VIDEO_FORMAT_H264, "Video formats must match");
_Static_assert(SLVideoFormatH265Main10 == VIDEO_FORMAT_H265_MAIN10, "Video formats must match");
_Static_assert(SLVideoFormatAV1High10_444 == VIDEO_FORMAT_AV1_HIGH10_444, "Video formats must match");
_Static_assert(SL_VIDEO_FORMAT_MASK_10BIT == VIDEO_FORMAT_MASK_10BIT, "Video formats must match");
_Static_assert(SLColorSpaceRec2020 == COLORSPACE_REC_2020, "Color spaces must match");
_Static_assert(SLVideoBufferTypeVPS == BUFFER_TYPE_VPS, "Buffer types must match");
_Static_assert(SLDecodeResultNeedKeyFrame == DR_NEED_IDR, "Decode results must match");
_Static_assert(SLTouchEventTypeCancelAll == LI_TOUCH_EVENT_CANCEL_ALL, "Touch event types must match");
_Static_assert(SLMouseButtonX2 == BUTTON_X2, "Mouse buttons must match");
_Static_assert(SLKeyModifierExtended == MODIFIER_EXTENDED, "Key modifiers must match");

// Serializes starting and stopping sessions
static pthread_mutex_t sessionLock = PTHREAD_MUTEX_INITIALIZER;
static SLStreamCallbacks callbacks;
// Held for reading while sending input, and for writing while the connection
// is torn down, since input can arrive from any thread
static pthread_rwlock_t inputLock = PTHREAD_RWLOCK_INITIALIZER;

#pragma mark - Connection listener

static void clStageStarting(int stage) {
    if (callbacks.stageStarting) {
        callbacks.stageStarting(callbacks.context, stage, LiGetStageName(stage));
    }
}

static void clStageFailed(int stage, int errorCode) {
    if (callbacks.stageFailed) {
        callbacks.stageFailed(callbacks.context, stage, LiGetStageName(stage), errorCode,
                              LiGetPortFlagsFromStage(stage));
    }
}

static void clConnectionStarted(void) {
    if (callbacks.connectionStarted) {
        callbacks.connectionStarted(callbacks.context);
    }
}

static void clConnectionTerminated(int errorCode) {
    if (callbacks.connectionTerminated) {
        callbacks.connectionTerminated(callbacks.context, errorCode,
                                       LiGetPortFlagsFromTerminationErrorCode(errorCode));
    }
}

static void clConnectionStatusUpdate(int status) {
    if (callbacks.connectionStatusChanged) {
        callbacks.connectionStatusChanged(callbacks.context, status == CONN_STATUS_POOR);
    }
}

static void clSetHdrMode(bool enabled) {
    if (callbacks.hdrModeChanged) {
        callbacks.hdrModeChanged(callbacks.context, enabled);
    }
}

static void clLogMessage(const char* format, ...) {
    if (!callbacks.log) {
        return;
    }

    char message[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(message, sizeof(message), format, args);
    va_end(args);

    callbacks.log(callbacks.context, message);
}

#pragma mark - Video

// Growable buffers, only touched by the decoder thread
static uint8_t* annexBBuffer;
static size_t annexBCapacity;
static uint8_t* frameBuffer;
static size_t frameCapacity;
static int activeVideoFormat;

#define MAX_PARAMETER_SETS 16

static bool reserve(uint8_t** buffer, size_t* capacity, size_t length) {
    if (*capacity >= length) {
        return true;
    }

    size_t newCapacity = length + length / 2;
    uint8_t* newBuffer = realloc(*buffer, newCapacity);
    if (newBuffer == NULL) {
        return false;
    }
    *buffer = newBuffer;
    *capacity = newCapacity;
    return true;
}

static int startCodeLength(const uint8_t* data, int length) {
    if (length >= 4 && data[0] == 0 && data[1] == 0 && data[2] == 0 && data[3] == 1) {
        return 4;
    }
    if (length >= 3 && data[0] == 0 && data[1] == 0 && data[2] == 1) {
        return 3;
    }
    return 0;
}

static void appendLengthPrefixedNAL(const uint8_t* nal, size_t length, size_t* offset) {
    // NAL units never end in a zero byte, those belong to a 4-byte start code
    while (length > 0 && nal[length - 1] == 0) {
        length--;
    }
    if (length == 0) {
        return;
    }

    uint8_t* out = &frameBuffer[*offset];
    out[0] = (uint8_t)(length >> 24);
    out[1] = (uint8_t)(length >> 16);
    out[2] = (uint8_t)(length >> 8);
    out[3] = (uint8_t)length;
    memcpy(&out[4], nal, length);
    *offset += 4 + length;
}

// Converts an Annex B byte stream into 4-byte length prefixed NAL units,
// returning the converted length
static size_t convertAnnexB(const uint8_t* data, size_t length) {
    size_t offset = 0;
    size_t nalStart = SIZE_MAX;

    for (size_t i = 0; i + 3 <= length; i++) {
        if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) {
            if (nalStart != SIZE_MAX) {
                appendLengthPrefixedNAL(&data[nalStart], i - nalStart, &offset);
            }
            nalStart = i + 3;
            i += 2;
        }
    }

    if (nalStart != SIZE_MAX && nalStart < length) {
        appendLengthPrefixedNAL(&data[nalStart], length - nalStart, &offset);
    }
    return offset;
}

static int drSetup(int videoFormat, int width, int height, int redrawRate, void* context, int drFlags) {
    (void)context;
    (void)drFlags;

    activeVideoFormat = videoFormat;
    if (!callbacks.videoSetup) {
        return -1;
    }
    return callbacks.videoSetup(callbacks.context, (SLVideoFormat)videoFormat, width, height, redrawRate);
}

static void drCleanup(void) {
    if (callbacks.videoCleanup) {
        callbacks.videoCleanup(callbacks.context);
    }

    free(annexBBuffer);
    annexBBuffer = NULL;
    annexBCapacity = 0;
    free(frameBuffer);
    frameBuffer = NULL;
    frameCapacity = 0;
}

static int drSubmitDecodeUnit(PDECODE_UNIT decodeUnit) {
    if (!callbacks.videoSubmitFrame) {
        return DR_OK;
    }

    SLParameterSet parameterSets[MAX_PARAMETER_SETS];
    int parameterSetCount = 0;
    size_t pictureLength = 0;

    // Parameter sets are referenced in place, picture data is gathered into one buffer
    if (!reserve(&annexBBuffer, &annexBCapacity, (size_t)decodeUnit->fullLength)) {
        return DR_NEED_IDR;
    }
    for (PLENTRY entry = decodeUnit->bufferList; entry != NULL; entry = entry->next) {
        if (entry->bufferType == BUFFER_TYPE_PICDATA) {
            memcpy(&annexBBuffer[pictureLength], entry->data, (size_t)entry->length);
            pictureLength += (size_t)entry->length;
        }
        else if (parameterSetCount < MAX_PARAMETER_SETS) {
            const uint8_t* data = (const uint8_t*)entry->data;
            int prefix = startCodeLength(data, entry->length);
            parameterSets[parameterSetCount++] = (SLParameterSet){
                .data = data + prefix,
                .length = entry->length - prefix,
                .type = (SLVideoBufferType)entry->bufferType,
            };
        }
    }

    const uint8_t* frameData;
    size_t frameLength;
    if (activeVideoFormat & (VIDEO_FORMAT_MASK_H264 | VIDEO_FORMAT_MASK_H265)) {
        // Each 3-byte start code grows by at most one byte
        if (!reserve(&frameBuffer, &frameCapacity, pictureLength + pictureLength / 3 + 4)) {
            return DR_NEED_IDR;
        }
        frameLength = convertAnnexB(annexBBuffer, pictureLength);
        frameData = frameBuffer;
    }
    else {
        frameLength = pictureLength;
        frameData = annexBBuffer;
    }

    SLVideoFrame frame = {
        .isKeyFrame = decodeUnit->frameType == FRAME_TYPE_IDR,
        .parameterSets = parameterSets,
        .parameterSetCount = parameterSetCount,
        .data = frameData,
        .length = (int32_t)frameLength,
    };
    return callbacks.videoSubmitFrame(callbacks.context, &frame);
}

#pragma mark - Audio

// Upper bound of a single Opus packet, 120 ms at 48 kHz
#define MAX_OPUS_FRAME_SIZE 5760

static OpusMSDecoder* opusDecoder;
static float* decodeBuffer;
static int audioChannelCount;

// Single producer (decoder thread), single consumer (render thread) ring
// buffer of interleaved samples
static float* ringBuffer;
static uint32_t ringCapacity;
static _Atomic uint64_t ringWritePosition;
static _Atomic uint64_t ringReadPosition;
static _Atomic bool audioActive;
// Frames kept buffered at most, anything beyond is dropped to bound latency
static uint32_t maxBufferedFrames;
// Frames to accumulate after an underrun before playing again
static uint32_t primingFrames;
static bool isPriming;

static void freeAudio(void) {
    if (opusDecoder != NULL) {
        opus_multistream_decoder_destroy(opusDecoder);
        opusDecoder = NULL;
    }
    free(decodeBuffer);
    decodeBuffer = NULL;
    free(ringBuffer);
    ringBuffer = NULL;
}

static int arInit(int audioConfiguration, const POPUS_MULTISTREAM_CONFIGURATION opusConfig, void* context, int arFlags) {
    (void)audioConfiguration;
    (void)context;
    (void)arFlags;

    int error = 0;
    opusDecoder = opus_multistream_decoder_create(opusConfig->sampleRate,
                                                  opusConfig->channelCount,
                                                  opusConfig->streams,
                                                  opusConfig->coupledStreams,
                                                  opusConfig->mapping,
                                                  &error);
    if (opusDecoder == NULL) {
        clLogMessage("Failed to create Opus decoder: %d\n", error);
        return -1;
    }

    audioChannelCount = opusConfig->channelCount;
    decodeBuffer = malloc(sizeof(float) * MAX_OPUS_FRAME_SIZE * (size_t)audioChannelCount);

    // Room for half a second, far more than will ever be kept
    ringCapacity = (uint32_t)opusConfig->sampleRate / 2;
    ringBuffer = calloc(ringCapacity * (size_t)audioChannelCount, sizeof(float));
    maxBufferedFrames = (uint32_t)opusConfig->sampleRate * 60 / 1000;
    primingFrames = (uint32_t)opusConfig->samplesPerFrame * 2;
    if (primingFrames < (uint32_t)opusConfig->sampleRate / 100) {
        primingFrames = (uint32_t)opusConfig->sampleRate / 100;
    }
    isPriming = true;
    atomic_store(&ringWritePosition, 0);
    atomic_store(&ringReadPosition, 0);

    if (decodeBuffer == NULL || ringBuffer == NULL) {
        freeAudio();
        return -1;
    }

    atomic_store_explicit(&audioActive, true, memory_order_release);
    if (!callbacks.audioSetup ||
        callbacks.audioSetup(callbacks.context, opusConfig->channelCount, opusConfig->sampleRate) != 0) {
        atomic_store(&audioActive, false);
        freeAudio();
        return -1;
    }
    return 0;
}

static void arCleanup(void) {
    if (callbacks.audioCleanup) {
        callbacks.audioCleanup(callbacks.context);
    }
    atomic_store(&audioActive, false);
    freeAudio();
}

static void arDecodeAndPlaySample(char* sampleData, int sampleLength) {
    // Don't let audio build up in moonlight-common-c's queue either
    if (LiGetPendingAudioDuration() > 30) {
        return;
    }

    // A NULL packet asks Opus to conceal a lost one
    int frames = opus_multistream_decode_float(opusDecoder, (const unsigned char*)sampleData, sampleLength,
                                               decodeBuffer, MAX_OPUS_FRAME_SIZE, 0);
    if (frames <= 0) {
        return;
    }

    uint64_t write = atomic_load_explicit(&ringWritePosition, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&ringReadPosition, memory_order_acquire);
    if (write - read + (uint64_t)frames > maxBufferedFrames) {
        return;
    }

    for (int i = 0; i < frames; i++) {
        uint32_t index = (uint32_t)((write + (uint64_t)i) % ringCapacity);
        memcpy(&ringBuffer[index * (uint32_t)audioChannelCount],
               &decodeBuffer[i * audioChannelCount],
               sizeof(float) * (size_t)audioChannelCount);
    }
    atomic_store_explicit(&ringWritePosition, write + (uint64_t)frames, memory_order_release);
}

void SLStreamRenderAudio(float* const* channels, int32_t channelCount, int32_t frameCount) {
    int32_t rendered = 0;

    if (atomic_load_explicit(&audioActive, memory_order_acquire) && channelCount == audioChannelCount) {
        uint64_t read = atomic_load_explicit(&ringReadPosition, memory_order_relaxed);
        uint64_t write = atomic_load_explicit(&ringWritePosition, memory_order_acquire);
        uint64_t available = write - read;

        if (isPriming && available >= primingFrames) {
            isPriming = false;
        }

        if (!isPriming) {
            rendered = available < (uint64_t)frameCount ? (int32_t)available : frameCount;
            for (int32_t i = 0; i < rendered; i++) {
                const float* frame = &ringBuffer[(uint32_t)((read + (uint64_t)i) % ringCapacity) * (uint32_t)channelCount];
                for (int32_t channel = 0; channel < channelCount; channel++) {
                    channels[channel][i] = frame[channel];
                }
            }
            atomic_store_explicit(&ringReadPosition, read + (uint64_t)rendered, memory_order_release);

            if (rendered < frameCount) {
                // Underrun, build up a little again before resuming
                isPriming = true;
            }
        }
    }

    for (int32_t channel = 0; channel < channelCount; channel++) {
        memset(&channels[channel][rendered], 0, sizeof(float) * (size_t)(frameCount - rendered));
    }
}

#pragma mark - Session

int32_t SLStreamStart(const SLStreamConfiguration* configuration, const SLStreamCallbacks* streamCallbacks) {
    pthread_mutex_lock(&sessionLock);
    callbacks = *streamCallbacks;

    SERVER_INFORMATION serverInfo;
    LiInitializeServerInformation(&serverInfo);
    serverInfo.address = configuration->address;
    serverInfo.serverInfoAppVersion = configuration->appVersion;
    serverInfo.serverInfoGfeVersion = configuration->gfeVersion;
    serverInfo.rtspSessionUrl = configuration->rtspSessionURL;
    serverInfo.serverCodecModeSupport = configuration->serverCodecModeSupport;

    STREAM_CONFIGURATION streamConfig;
    LiInitializeStreamConfiguration(&streamConfig);
    streamConfig.width = configuration->width;
    streamConfig.height = configuration->height;
    streamConfig.fps = configuration->fps;
    streamConfig.bitrate = configuration->bitrateKbps;
    // Detect remote streaming from the host address
    streamConfig.streamingRemotely = STREAM_CFG_AUTO;
    streamConfig.packetSize = 1392;
    switch (configuration->audioChannelCount) {
    case 8:
        streamConfig.audioConfiguration = AUDIO_CONFIGURATION_71_SURROUND;
        break;
    case 6:
        streamConfig.audioConfiguration = AUDIO_CONFIGURATION_51_SURROUND;
        break;
    default:
        streamConfig.audioConfiguration = AUDIO_CONFIGURATION_STEREO;
        break;
    }
    streamConfig.supportedVideoFormats = configuration->supportedVideoFormats;
    streamConfig.colorSpace = configuration->colorSpace;
    streamConfig.colorRange = configuration->fullColorRange ? COLOR_RANGE_FULL : COLOR_RANGE_LIMITED;
    // Every Apple device we support has hardware AES
    streamConfig.encryptionFlags = ENCFLG_ALL;

    memcpy(streamConfig.remoteInputAesKey, configuration->remoteInputKey, sizeof(streamConfig.remoteInputAesKey));
    memset(streamConfig.remoteInputAesIv, 0, sizeof(streamConfig.remoteInputAesIv));
    uint32_t keyID = configuration->remoteInputKeyID;
    uint8_t keyIDBigEndian[4] = { (uint8_t)(keyID >> 24), (uint8_t)(keyID >> 16), (uint8_t)(keyID >> 8), (uint8_t)keyID };
    memcpy(streamConfig.remoteInputAesIv, keyIDBigEndian, sizeof(keyIDBigEndian));

    CONNECTION_LISTENER_CALLBACKS listenerCallbacks;
    LiInitializeConnectionCallbacks(&listenerCallbacks);
    listenerCallbacks.stageStarting = clStageStarting;
    listenerCallbacks.stageFailed = clStageFailed;
    listenerCallbacks.connectionStarted = clConnectionStarted;
    listenerCallbacks.connectionTerminated = clConnectionTerminated;
    listenerCallbacks.connectionStatusUpdate = clConnectionStatusUpdate;
    listenerCallbacks.setHdrMode = clSetHdrMode;
    listenerCallbacks.logMessage = clLogMessage;

    DECODER_RENDERER_CALLBACKS videoCallbacks;
    LiInitializeVideoCallbacks(&videoCallbacks);
    videoCallbacks.setup = drSetup;
    videoCallbacks.cleanup = drCleanup;
    videoCallbacks.submitDecodeUnit = drSubmitDecodeUnit;
    // VideoToolbox copes with missing references in these codecs
    videoCallbacks.capabilities = CAPABILITY_REFERENCE_FRAME_INVALIDATION_HEVC |
                                  CAPABILITY_REFERENCE_FRAME_INVALIDATION_AV1;

    AUDIO_RENDERER_CALLBACKS audioCallbacks;
    LiInitializeAudioCallbacks(&audioCallbacks);
    audioCallbacks.init = arInit;
    audioCallbacks.cleanup = arCleanup;
    audioCallbacks.decodeAndPlaySample = arDecodeAndPlaySample;
    audioCallbacks.capabilities = CAPABILITY_SUPPORTS_ARBITRARY_AUDIO_DURATION;

    int result = LiStartConnection(&serverInfo, &streamConfig, &listenerCallbacks,
                                   &videoCallbacks, &audioCallbacks,
                                   NULL, 0, NULL, 0);
    pthread_mutex_unlock(&sessionLock);
    return result;
}

void SLStreamStop(void) {
    // Interrupting first makes a pending SLStreamStart() release the lock sooner
    LiInterruptConnection();

    pthread_mutex_lock(&sessionLock);
    pthread_rwlock_wrlock(&inputLock);
    LiStopConnection();
    pthread_rwlock_unlock(&inputLock);
    memset(&callbacks, 0, sizeof(callbacks));
    pthread_mutex_unlock(&sessionLock);
}

const char* SLStreamLaunchQueryParameters(void) {
    return LiGetLaunchUrlQueryParameters();
}

int32_t SLStreamSurroundAudioInfo(int32_t channelCount) {
    switch (channelCount) {
    case 8:
        return SURROUNDAUDIOINFO_FROM_AUDIO_CONFIGURATION(AUDIO_CONFIGURATION_71_SURROUND);
    case 6:
        return SURROUNDAUDIOINFO_FROM_AUDIO_CONFIGURATION(AUDIO_CONFIGURATION_51_SURROUND);
    default:
        return SURROUNDAUDIOINFO_FROM_AUDIO_CONFIGURATION(AUDIO_CONFIGURATION_STEREO);
    }
}

void SLStreamDescribePorts(uint32_t portFlags, char* buffer, int32_t bufferLength) {
    LiStringifyPortFlags(portFlags, ", ", buffer, bufferLength);
}

void SLStreamRequestKeyFrame(void) {
    LiRequestIdrFrame();
}

static void storeBE16(uint8_t* p, uint16_t v) {
    p[0] = (uint8_t)(v >> 8);
    p[1] = (uint8_t)v;
}

static void storeBE32(uint8_t* p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);
    p[3] = (uint8_t)v;
}

bool SLStreamGetHDRMetadata(SLHDRMetadata* metadata) {
    memset(metadata, 0, sizeof(*metadata));

    SS_HDR_METADATA hdr;
    if (!LiGetHdrMetadata(&hdr)) {
        return false;
    }

    if (hdr.displayPrimaries[0].x != 0 && hdr.maxDisplayLuminance != 0) {
        // mdcv lists the primaries in GBR order while SS_HDR_METADATA is RGB
        uint8_t* mdcv = metadata->masteringDisplayColorVolume;
        const int order[3] = { 1, 2, 0 };
        for (int i = 0; i < 3; i++) {
            storeBE16(&mdcv[i * 4], hdr.displayPrimaries[order[i]].x);
            storeBE16(&mdcv[i * 4 + 2], hdr.displayPrimaries[order[i]].y);
        }
        storeBE16(&mdcv[12], hdr.whitePoint.x);
        storeBE16(&mdcv[14], hdr.whitePoint.y);
        // Luminance is in 1/10000 nits
        storeBE32(&mdcv[16], (uint32_t)hdr.maxDisplayLuminance * 10000);
        storeBE32(&mdcv[20], hdr.minDisplayLuminance);
        metadata->hasMasteringDisplayColorVolume = true;
    }

    if (hdr.maxContentLightLevel != 0 && hdr.maxFrameAverageLightLevel != 0) {
        storeBE16(&metadata->contentLightLevelInfo[0], hdr.maxContentLightLevel);
        storeBE16(&metadata->contentLightLevelInfo[2], hdr.maxFrameAverageLightLevel);
        metadata->hasContentLightLevelInfo = true;
    }

    return true;
}

#pragma mark - Input

void SLInputSendTouch(SLTouchEventType type, uint32_t pointerID, float x, float y,
                      float pressure, float contactAreaMajor, float contactAreaMinor) {
    pthread_rwlock_rdlock(&inputLock);
    LiSendTouchEvent(type, pointerID, x, y, pressure, contactAreaMajor, contactAreaMinor, LI_ROT_UNKNOWN);
    pthread_rwlock_unlock(&inputLock);
}

void SLInputSendMouseMove(int16_t deltaX, int16_t deltaY) {
    pthread_rwlock_rdlock(&inputLock);
    LiSendMouseMoveEvent(deltaX, deltaY);
    pthread_rwlock_unlock(&inputLock);
}

void SLInputSendMousePosition(int16_t x, int16_t y, int16_t referenceWidth, int16_t referenceHeight) {
    pthread_rwlock_rdlock(&inputLock);
    LiSendMousePositionEvent(x, y, referenceWidth, referenceHeight);
    pthread_rwlock_unlock(&inputLock);
}

void SLInputSendMouseButton(SLMouseButton button, bool pressed) {
    pthread_rwlock_rdlock(&inputLock);
    LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, button);
    pthread_rwlock_unlock(&inputLock);
}

void SLInputSendScroll(int16_t vertical, int16_t horizontal) {
    pthread_rwlock_rdlock(&inputLock);
    if (vertical != 0) {
        LiSendHighResScrollEvent(vertical);
    }
    if (horizontal != 0) {
        LiSendHighResHScrollEvent(horizontal);
    }
    pthread_rwlock_unlock(&inputLock);
}

void SLInputSendKey(int16_t keyCode, bool pressed, SLKeyModifiers modifiers, bool nonNormalized) {
    pthread_rwlock_rdlock(&inputLock);
    // The high byte marks the key code as a virtual key
    LiSendKeyboardEvent2((short)(0x8000 | (uint16_t)keyCode), pressed ? KEY_ACTION_DOWN : KEY_ACTION_UP,
                         (char)modifiers, nonNormalized ? SS_KBE_FLAG_NON_NORMALIZED : 0);
    pthread_rwlock_unlock(&inputLock);
}
