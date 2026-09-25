#pragma once
#include "opus_multistream.h"
/* Swift can't call Opus's variadic ctl() macros, so these wrap the ones we need. */
int copus_ms_set_bitrate(OpusMSEncoder *enc, int bitrate);
int copus_ms_set_complexity(OpusMSEncoder *enc, int complexity);
int copus_ms_set_vbr(OpusMSEncoder *enc, int vbr);
int copus_ms_get_lookahead(OpusMSEncoder *enc);
