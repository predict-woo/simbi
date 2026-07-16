/* Simbi addition (not part of vendored opus): non-variadic wrappers for
 * opus_*_ctl, which Swift cannot call directly. */

#ifndef OPUS_SWIFT_CTL_H
#define OPUS_SWIFT_CTL_H

#include "opus.h"

static inline int opus_encoder_ctl_set(OpusEncoder *st, int request, opus_int32 value) {
    return opus_encoder_ctl(st, request, value);
}

static inline int opus_encoder_ctl_get(OpusEncoder *st, int request, opus_int32 *value) {
    return opus_encoder_ctl(st, request, value);
}

static inline int opus_decoder_ctl_set(OpusDecoder *st, int request, opus_int32 value) {
    return opus_decoder_ctl(st, request, value);
}

static inline int opus_decoder_ctl_get(OpusDecoder *st, int request, opus_int32 *value) {
    return opus_decoder_ctl(st, request, value);
}

#endif /* OPUS_SWIFT_CTL_H */
