#include <nall/nall.hpp>
#include <nall/decode/zip.hpp>
using namespace nall;

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  Decode::ZIP zip;
  if(!zip.open(data, size)) return -1;
  for(auto& entry : zip.file) {
    //extract() sizes its buffer from the (untrusted) header; cap it so the harness does not just report OOM
    if(entry.size > (1u << 24)) continue;
    auto buffer = zip.extract(entry);
    (void)buffer;
  }
  return 0;
}
