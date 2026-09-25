#include "copus_shim.h"
int copus_ms_set_bitrate(OpusMSEncoder *enc, int bitrate) { return opus_multistream_encoder_ctl(enc, OPUS_SET_BITRATE(bitrate)); }
int copus_ms_set_complexity(OpusMSEncoder *enc, int c) { return opus_multistream_encoder_ctl(enc, OPUS_SET_COMPLEXITY(c)); }
int copus_ms_set_vbr(OpusMSEncoder *enc, int vbr) { return opus_multistream_encoder_ctl(enc, OPUS_SET_VBR(vbr)); }
int copus_ms_get_lookahead(OpusMSEncoder *enc) { opus_int32 v = 0; opus_multistream_encoder_ctl(enc, OPUS_GET_LOOKAHEAD(&v)); return (int)v; }
