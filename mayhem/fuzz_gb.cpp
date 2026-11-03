#include <mia/mia.hpp>
#include <gb/gb.hpp>
#include <unistd.h>
#include <cstring>
#include <vector>

namespace {

struct Host : ares::Platform {
  std::shared_ptr<vfs::directory> system;
  std::shared_ptr<vfs::directory> game;

  auto pak(ares::Node::Object node) -> std::shared_ptr<vfs::directory> override {
    if(node->name() == "Game Boy") return system;
    if(node->name() == "Game Boy Cartridge") return game;
    return {};
  }
} host;

}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  const char* tmp = getenv("TMPDIR");
  string path = {tmp && *tmp ? tmp : "/tmp", "/fuzz_gb_XXXXXX.gb"};
  int fd = mkstemps(path.get(), 3);
  if(fd < 0) return 0;
  // mia rejects ROMs under 0x4000 bytes and Mayhem caps inputs at 8 KiB, so lay the input over a zero-filled 32 KiB image (header at 0x100 stays fuzzable).
  std::vector<uint8_t> rom(size > 0x8000 ? size : 0x8000, 0);
  if(size) memcpy(rom.data(), data, size);
  bool written = write(fd, rom.data(), rom.size()) == (ssize_t)rom.size();
  close(fd);

  auto medium = mia::Medium::create("Game Boy");
  bool loaded = written && medium->load(path) == successful;
  unlink(path);
  if(!loaded) return -1;

  host.game = medium->pak;
  host.system = std::make_shared<vfs::directory>();
  host.system->append("boot.rom", Resource::GameBoy::BootDMG1);

  ares::platform = &host;
  ares::Node::System root;
  if(!ares::GameBoy::load(root, "[Nintendo] Game Boy")) return -1;
  if(auto port = root->find<ares::Node::Port>("Cartridge Slot")) {
    port->allocate();
    port->connect();
  }
  if(auto fastBoot = root->find<ares::Node::Setting::Boolean>("Fast Boot")) {
    fastBoot->setValue(true);
  }
  root->power();
  for(u32 frame = 0; frame < 4; frame++) root->run();
  root->unload();
  host.game.reset();
  host.system.reset();
  return 0;
}
