#include <nall/nall.hpp>
#include <nall/decode/gzip.hpp>
using namespace nall;

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  //decompress() allocates the ISIZE trailer (last 4 bytes, little endian) unchecked; cap it so the harness does not just report OOM
  if(size >= 4) {
    uint32_t isize = data[size - 4] | data[size - 3] << 8 | data[size - 2] << 16 | (uint32_t)data[size - 1] << 24;
    if(isize > (1u << 24)) return -1;
  }
  Decode::GZIP gzip;
  if(!gzip.decompress(data, (u32)size)) return -1;
  return 0;
}
