#include <nall/nall.hpp>
#include <nall/decode/bmp.hpp>
using namespace nall;

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  //load() allocates width*height pixels unchecked; cap that size so the harness does not just report OOM.
  //Dimensions whose product overflows s32 are passed through: that is the decoder's own integer-overflow bug.
  if(size >= 26) {
    int32_t w, h;
    memcpy(&w, data + 18, 4);
    memcpy(&h, data + 22, 4);
    uint64_t pixels = (uint64_t)(w < 0 ? -(int64_t)w : w) * (uint64_t)(h < 0 ? -(int64_t)h : h);
    if(pixels > (1u << 24) && pixels <= INT32_MAX) return -1;
  }
  Decode::BMP bmp;
  if(!bmp.load(data, (u32)size)) return -1;
  return 0;
}
