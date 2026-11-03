#include <nall/nall.hpp>
#include <nall/decode/png.hpp>
using namespace nall;

static uint32_t be32(const uint8_t* p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  //load() sizes its allocations from the unchecked IHDR width/height and IDAT length; cap them so the harness does not just report OOM
  const uint64_t cap = 1u << 24;
  for(size_t offset = 8; offset + 8 <= size;) {
    uint64_t length = be32(data + offset);
    uint32_t fourCC = be32(data + offset + 4);
    if(fourCC == 0x49484452 && offset + 8 + 13 <= size) {
      uint64_t w = be32(data + offset + 8), h = be32(data + offset + 12);
      if(w > cap || h > cap || w * h > cap) return -1;
    }
    if(fourCC == 0x49444154 && length > cap) return -1;
    offset += 12 + length;
  }
  Decode::PNG png;
  if(!png.load(data, (u32)size)) return -1;
  return 0;
}
