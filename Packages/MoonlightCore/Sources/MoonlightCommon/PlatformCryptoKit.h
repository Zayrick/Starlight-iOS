#pragma once

#include <stdbool.h>
#include <stdint.h>

// Implemented by the MoonlightCrypto Swift target (Sources/MoonlightCrypto/AESGCM.swift).
// Keep these signatures in sync with its @_cdecl functions.
void* SLGCMCreateKey(const uint8_t* key, int32_t keyLength);
void SLGCMDestroyKey(void* context);
bool SLGCMCrypt(void* context, bool encrypt,
                const uint8_t* iv, int32_t ivLength,
                uint8_t* tag, int32_t tagLength,
                const uint8_t* input, int32_t inputLength, uint8_t* output);
