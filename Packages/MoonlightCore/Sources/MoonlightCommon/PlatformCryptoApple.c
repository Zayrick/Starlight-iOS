//
//  PlatformCryptoApple.c
//  MoonlightCore
//
//  Apple backend for moonlight-common-c's PlatformCrypto.h. CBC uses
//  CommonCrypto; GCM uses CryptoKit through the MoonlightCrypto Swift target.
//  Contexts retain one key and direction. CBC preserves chaining state until
//  CIPHER_FLAG_RESET_IV; GCM takes a fresh 12- or 16-byte IV per message.
//

#include "Limelight-internal.h"
#include "PlatformCryptoKit.h"

#include <CommonCrypto/CommonCryptor.h>
#include <stdlib.h>
#include <string.h>

#define AES_BLOCK_SIZE 16

// PlatformCrypto.h only forward declares this type, so we define it here.
struct evp_cipher_ctx_st {
    CCCryptorRef cbc;
    void* gcmKey;
};

// MARK: - GCM

static bool gcmCrypt(PPLT_CRYPTO_CONTEXT ctx, bool encrypt,
                     unsigned char* key, int keyLength,
                     unsigned char* iv, int ivLength,
                     unsigned char* tag, int tagLength,
                     unsigned char* inputData, int inputDataLength,
                     unsigned char* outputData, int* outputDataLength) {
    if (tag == NULL || tagLength != 16 || keyLength != 16 ||
        (ivLength != 12 && ivLength != 16) || inputDataLength < 0) {
        return false;
    }

    if (ctx->ctx->gcmKey == NULL) {
        ctx->ctx->gcmKey = SLGCMCreateKey(key, keyLength);
        if (ctx->ctx->gcmKey == NULL) {
            return false;
        }
        ctx->initialized = true;
    }

    if (!SLGCMCrypt(ctx->ctx->gcmKey, encrypt, iv, ivLength, tag, tagLength,
                    inputData, inputDataLength, outputData)) {
        return false;
    }
    *outputDataLength = inputDataLength;
    return true;
}

// MARK: - CBC

static int addPkcs7PaddingInPlace(unsigned char* plaintext, int plaintextLen) {
    int paddedLength = ROUND_TO_PKCS7_PADDED_LEN(plaintextLen);
    unsigned char paddingByte = (unsigned char)(16 - (plaintextLen % 16));

    memset(&plaintext[plaintextLen], paddingByte, paddedLength - plaintextLen);

    return paddedLength;
}

static bool cbcPrepare(PPLT_CRYPTO_CONTEXT ctx, CCOperation operation, int flags,
                       unsigned char* key, int keyLength, unsigned char* iv, int ivLength) {
    struct evp_cipher_ctx_st* state = ctx->ctx;

    if (ivLength != AES_BLOCK_SIZE) {
        return false;
    }

    if (state->cbc == NULL) {
        // Padding is handled here rather than by CommonCrypto, so that data is
        // never held back between calls
        if (CCCryptorCreate(operation, kCCAlgorithmAES, 0, key, keyLength, iv, &state->cbc) != kCCSuccess) {
            state->cbc = NULL;
            return false;
        }
        ctx->initialized = true;
    }
    else if (flags & CIPHER_FLAG_RESET_IV) {
        if (CCCryptorReset(state->cbc, iv) != kCCSuccess) {
            return false;
        }
    }

    return true;
}

static bool cbcUpdate(CCCryptorRef cbc, const unsigned char* in, int length, unsigned char* out) {
    size_t moved = 0;
    if (length % AES_BLOCK_SIZE != 0) {
        return false;
    }
    return CCCryptorUpdate(cbc, in, (size_t)length, out, (size_t)length, &moved) == kCCSuccess &&
           moved == (size_t)length;
}

static bool cbcEncrypt(PPLT_CRYPTO_CONTEXT ctx, int flags,
                       unsigned char* key, int keyLength,
                       unsigned char* iv, int ivLength,
                       unsigned char* inputData, int inputDataLength,
                       unsigned char* outputData, int* outputDataLength) {
    if (!cbcPrepare(ctx, kCCEncrypt, flags, key, keyLength, iv, ivLength)) {
        return false;
    }
    CCCryptorRef cbc = ctx->ctx->cbc;

    if (flags & CIPHER_FLAG_PAD_TO_BLOCK_SIZE) {
        inputDataLength = addPkcs7PaddingInPlace(inputData, inputDataLength);
    }

    if (flags & CIPHER_FLAG_FINISH) {
        // Encrypt the whole blocks, then a final block carrying the padding
        int fullLength = inputDataLength - (inputDataLength % AES_BLOCK_SIZE);
        if (!cbcUpdate(cbc, inputData, fullLength, outputData)) {
            return false;
        }

        // Unlike addPkcs7PaddingInPlace(), this adds a whole block of padding
        // to block-aligned input, as real PKCS #7 does
        unsigned char lastBlock[AES_BLOCK_SIZE];
        int remaining = inputDataLength - fullLength;
        memcpy(lastBlock, &inputData[fullLength], (size_t)remaining);
        memset(&lastBlock[remaining], AES_BLOCK_SIZE - remaining, (size_t)(AES_BLOCK_SIZE - remaining));
        if (!cbcUpdate(cbc, lastBlock, AES_BLOCK_SIZE, &outputData[fullLength])) {
            return false;
        }

        *outputDataLength = fullLength + AES_BLOCK_SIZE;
        return true;
    }

    if (!cbcUpdate(cbc, inputData, inputDataLength, outputData)) {
        return false;
    }
    *outputDataLength = inputDataLength;
    return true;
}

static bool cbcDecrypt(PPLT_CRYPTO_CONTEXT ctx, int flags,
                       unsigned char* key, int keyLength,
                       unsigned char* iv, int ivLength,
                       unsigned char* inputData, int inputDataLength,
                       unsigned char* outputData, int* outputDataLength) {
    if (!cbcPrepare(ctx, kCCDecrypt, flags, key, keyLength, iv, ivLength)) {
        return false;
    }

    if (!cbcUpdate(ctx->ctx->cbc, inputData, inputDataLength, outputData)) {
        return false;
    }

    if (flags & CIPHER_FLAG_FINISH) {
        // Validate and strip the PKCS #7 padding
        if (inputDataLength == 0) {
            return false;
        }

        unsigned char padding = outputData[inputDataLength - 1];
        if (padding == 0 || padding > AES_BLOCK_SIZE) {
            return false;
        }

        unsigned char difference = 0;
        for (int i = 0; i < padding; i++) {
            difference |= outputData[inputDataLength - 1 - i] ^ padding;
        }
        if (difference != 0) {
            return false;
        }

        *outputDataLength = inputDataLength - padding;
        return true;
    }

    *outputDataLength = inputDataLength;
    return true;
}

// MARK: - PlatformCrypto.h

bool PltEncryptMessage(PPLT_CRYPTO_CONTEXT ctx, int algorithm, int flags,
                       unsigned char* key, int keyLength,
                       unsigned char* iv, int ivLength,
                       unsigned char* tag, int tagLength,
                       unsigned char* inputData, int inputDataLength,
                       unsigned char* outputData, int* outputDataLength) {
    LC_ASSERT(keyLength == 16);

    switch (algorithm) {
    case ALGORITHM_AES_GCM:
        return gcmCrypt(ctx, true, key, keyLength, iv, ivLength, tag, tagLength,
                        inputData, inputDataLength, outputData, outputDataLength);
    case ALGORITHM_AES_CBC:
        LC_ASSERT(tag == NULL);
        LC_ASSERT(tagLength == 0);
        return cbcEncrypt(ctx, flags, key, keyLength, iv, ivLength,
                          inputData, inputDataLength, outputData, outputDataLength);
    default:
        LC_ASSERT(false);
        return false;
    }
}

bool PltDecryptMessage(PPLT_CRYPTO_CONTEXT ctx, int algorithm, int flags,
                       unsigned char* key, int keyLength,
                       unsigned char* iv, int ivLength,
                       unsigned char* tag, int tagLength,
                       unsigned char* inputData, int inputDataLength,
                       unsigned char* outputData, int* outputDataLength) {
    LC_ASSERT(keyLength == 16);

    switch (algorithm) {
    case ALGORITHM_AES_GCM:
        return gcmCrypt(ctx, false, key, keyLength, iv, ivLength, tag, tagLength,
                        inputData, inputDataLength, outputData, outputDataLength);
    case ALGORITHM_AES_CBC:
        LC_ASSERT(tag == NULL);
        LC_ASSERT(tagLength == 0);
        return cbcDecrypt(ctx, flags, key, keyLength, iv, ivLength,
                          inputData, inputDataLength, outputData, outputDataLength);
    default:
        LC_ASSERT(false);
        return false;
    }
}

PPLT_CRYPTO_CONTEXT PltCreateCryptoContext(void) {
    PPLT_CRYPTO_CONTEXT ctx = malloc(sizeof(*ctx));
    if (ctx == NULL) {
        return NULL;
    }

    ctx->initialized = false;
    ctx->ctx = calloc(1, sizeof(*ctx->ctx));
    if (ctx->ctx == NULL) {
        free(ctx);
        return NULL;
    }

    return ctx;
}

void PltDestroyCryptoContext(PPLT_CRYPTO_CONTEXT ctx) {
    if (ctx == NULL) {
        return;
    }

    if (ctx->ctx->gcmKey != NULL) {
        SLGCMDestroyKey(ctx->ctx->gcmKey);
    }
    if (ctx->ctx->cbc != NULL) {
        CCCryptorRelease(ctx->ctx->cbc);
    }

    free(ctx->ctx);
    free(ctx);
}

void PltGenerateRandomData(unsigned char* data, int length) {
    arc4random_buf(data, (size_t)length);
}
