




#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <cstdlib>
#include <random>
#include <string>
#include <vector>

#include "doctest.h"
#include "test_env.h"
#include "media/frame_bus.h"
#include "node/node.h"

// The implementation lives in third_party/stb/stb_image_impl.c so the whole build shares one
// decoder. A second copy here would win the link and silently narrow the test binary to the
// formats this file happened to enable.
#define STBI_NO_STDIO
#include "stb_image.h"

using namespace db;

namespace {




RawFrame makeBgra(int w, int h) {
  RawFrame f;
  f.format = 3;
  f.w = w;
  f.h = h;
  f.stride = w * 4;
  f.data.resize(static_cast<size_t>(w) * h * 4);
  for (int r = 0; r < h; r++) {
    for (int c = 0; c < w; c++) {
      uint8_t* p = f.data.data() + (static_cast<size_t>(r) * w + c) * 4;
      p[0] = static_cast<uint8_t>(255 - 255 * c / (w - 1));  // B
      p[1] = static_cast<uint8_t>(255 * r / (h - 1));        // G
      p[2] = static_cast<uint8_t>(255 * c / (w - 1));        // R
      p[3] = 255;                                            // A
    }
  }
  return f;
}


RawFrame makeNv12(int w, int h, uint8_t y, uint8_t u, uint8_t v) {
  RawFrame f;
  f.format = 1;
  f.w = w;
  f.h = h;
  f.stride = w;
  f.data.resize(static_cast<size_t>(w) * h + static_cast<size_t>(w) * ((h + 1) / 2));
  std::fill(f.data.begin(), f.data.begin() + static_cast<size_t>(w) * h, y);
  for (size_t i = static_cast<size_t>(w) * h; i + 1 < f.data.size(); i += 2) {
    f.data[i] = u;
    f.data[i + 1] = v;
  }
  return f;
}


void expectRgb(int y, int u, int v, int* rgb) {
  auto cl = [](int x) { return x < 0 ? 0 : (x > 255 ? 255 : x); };
  int c = y - 16, d = u - 128, e = v - 128;
  rgb[0] = cl((298 * c + 409 * e + 128) >> 8);
  rgb[1] = cl((298 * c - 100 * d - 208 * e + 128) >> 8);
  rgb[2] = cl((298 * c + 516 * d + 128) >> 8);
}

struct Decoded {
  int w = 0, h = 0;
  std::vector<uint8_t> rgb;  // w*h*3
  const uint8_t* at(int x, int y) const { return rgb.data() + (static_cast<size_t>(y) * w + x) * 3; }
};

Decoded decodeJpeg(const Bytes& jpeg) {
  Decoded d;
  int comp = 0;
  uint8_t* p = stbi_load_from_memory(jpeg.data(), static_cast<int>(jpeg.size()), &d.w, &d.h,
                                     &comp, 3);
  REQUIRE(p != nullptr);
  d.rgb.assign(p, p + static_cast<size_t>(d.w) * d.h * 3);
  stbi_image_free(p);
  return d;
}

bool near3(const uint8_t* got, const int* want, int tol) {
  for (int k = 0; k < 3; k++)
    if (std::abs(static_cast<int>(got[k]) - want[k]) > tol) return false;
  return true;
}

}  // namespace

TEST_CASE("media: converts BGRA to a valid JPEG with expected dimensions and color") {
  FrameBus bus;
  bus.setJpegParams(90, 0);
  bus.push(makeBgra(64, 48));
  Bytes jpeg = bus.latestJpeg();
  REQUIRE(!jpeg.empty());
  REQUIRE(jpeg.size() >= 4);
  CHECK(jpeg[0] == 0xff);  // SOI
  CHECK(jpeg[1] == 0xd8);

  Decoded d = decodeJpeg(jpeg);
  CHECK(d.w == 64);
  CHECK(d.h == 48);

  int blue[3] = {0, 0, 255}, red[3] = {255, 0, 0}, yellow[3] = {255, 255, 0};
  CHECK(near3(d.at(1, 1), blue, 40));
  CHECK(near3(d.at(62, 1), red, 40));
  CHECK(near3(d.at(62, 46), yellow, 40));
}

TEST_CASE("media: converts NV12, NV21, and YUY2 colors using BT.601") {

  int gray[3], red[3];
  expectRgb(126, 128, 128, gray);
  expectRgb(81, 90, 240, red);

  SUBCASE("uniform gray NV12") {
    FrameBus bus;
    bus.setJpegParams(90, 0);
    bus.push(makeNv12(32, 32, 126, 128, 128));
    Decoded d = decodeJpeg(bus.latestJpeg());
    CHECK(d.w == 32);
    CHECK(d.h == 32);
    CHECK(near3(d.at(16, 16), gray, 8));
  }
  SUBCASE("red NV12") {
    FrameBus bus;
    bus.setJpegParams(90, 0);
    bus.push(makeNv12(32, 32, 81, 90, 240));
    Decoded d = decodeJpeg(bus.latestJpeg());
    CHECK(near3(d.at(16, 16), red, 12));
  }
  SUBCASE("NV21 reverses UV order and produces the same result after swapping") {
    FrameBus bus;
    bus.setJpegParams(90, 0);
    RawFrame f = makeNv12(32, 32, 81, 240, 90);
    f.format = 0;
    bus.push(std::move(f));
    Decoded d = decodeJpeg(bus.latestJpeg());
    CHECK(near3(d.at(16, 16), red, 12));
  }
  SUBCASE("uniform-color YUY2") {
    FrameBus bus;
    bus.setJpegParams(90, 0);
    RawFrame f;
    f.format = 2;
    f.w = 32;
    f.h = 16;
    f.stride = 64;
    f.data.resize(static_cast<size_t>(f.stride) * f.h);
    for (size_t i = 0; i + 3 < f.data.size(); i += 4) {
      f.data[i] = 81;       // Y0
      f.data[i + 1] = 90;   // U
      f.data[i + 2] = 81;   // Y1
      f.data[i + 3] = 240;  // V
    }
    bus.push(std::move(f));
    Decoded d = decodeJpeg(bus.latestJpeg());
    CHECK(d.w == 32);
    CHECK(d.h == 16);
    CHECK(near3(d.at(16, 8), red, 12));
  }
}

TEST_CASE("media: encoding is demand-driven and caches for active subscribers") {
  FrameBus bus;

  for (int i = 0; i < 20; i++) bus.push(makeBgra(64, 48));
  CHECK(bus.frameCount() == 20);
  CHECK(bus.encodeCount() == 0);


  Bytes j1 = bus.latestJpeg();
  Bytes j2 = bus.latestJpeg();
  CHECK(bus.encodeCount() == 1);
  CHECK(j1 == j2);


  bus.push(makeBgra(64, 48));
  (void)bus.latestJpeg();
  CHECK(bus.encodeCount() == 2);


  FrameBus empty;
  CHECK(empty.latestJpeg().empty());
  CHECK(empty.frameCount() == 0);
}

TEST_CASE("media: repeatedly halves frames that exceed max_width") {
  FrameBus bus;
  bus.setJpegParams(80, 640);
  bus.push(makeBgra(1280, 720));
  Decoded d = decodeJpeg(bus.latestJpeg());
  CHECK(d.w == 640);
  CHECK(d.h == 360);

  bus.setJpegParams(80, 320);
  Decoded d2 = decodeJpeg(bus.latestJpeg());
  CHECK(d2.w == 320);
  CHECK(d2.h == 180);
  CHECK(bus.encodeCount() == 2);
}

TEST_CASE("media: supports an external encoder SPI and stb fallback") {
  FrameBus bus;
  bus.setJpegParams(70, 0);
  int called = 0;
  int got_w = 0, got_h = 0, got_q = 0;
  bus.setExternalEncoder([&](const uint8_t* rgb, int w, int h, int q) {
    called++;
    got_w = w;
    got_h = h;
    got_q = q;
    (void)rgb;
    return toBytes("EXTJPEG");
  });
  bus.push(makeBgra(64, 48));
  Bytes j = bus.latestJpeg();
  CHECK(called == 1);
  CHECK(got_w == 64);
  CHECK(got_h == 48);
  CHECK(got_q == 70);
  CHECK(toString(j) == "EXTJPEG");


  bus.setExternalEncoder([&](const uint8_t*, int, int, int) {
    called++;
    return Bytes{};
  });
  j = bus.latestJpeg();
  CHECK(called == 2);
  REQUIRE(j.size() >= 2);
  CHECK(j[0] == 0xff);
  CHECK(j[1] == 0xd8);


  bus.setExternalEncoder(nullptr);
  j = bus.latestJpeg();
  CHECK(called == 2);
  CHECK(j[0] == 0xff);
}

TEST_CASE("media: discards undersized and invalid frames") {
  FrameBus bus;
  RawFrame f = makeBgra(64, 48);
  f.data.resize(f.data.size() / 2);
  bus.push(std::move(f));
  CHECK(bus.frameCount() == 0);

  RawFrame g = makeBgra(64, 48);
  g.format = 99;
  bus.push(std::move(g));
  CHECK(bus.frameCount() == 0);
  CHECK(bus.latestJpeg().empty());
}



namespace {

int freePort(std::mt19937& /*rng*/) {
  // Ports come from one process-wide allocator; see core/tests/test_ports.h.
  return db::testing::freeListenPort();
}

int connectTo(int port) {
  int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  sockaddr_in sa{};
  sa.sin_family = AF_INET;
  sa.sin_port = htons(static_cast<uint16_t>(port));
  sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (::connect(fd, reinterpret_cast<sockaddr*>(&sa), sizeof(sa)) != 0) {
    ::close(fd);
    return -1;
  }
  timeval tv{5, 0};
  ::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  return fd;
}


std::string httpGet(int port, const std::string& path) {
  int fd = connectTo(port);
  REQUIRE(fd >= 0);
  std::string req = "GET " + path + " HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
  REQUIRE(::send(fd, req.data(), req.size(), 0) == static_cast<ssize_t>(req.size()));
  std::string resp;
  char buf[4096];
  for (;;) {
    ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
    if (n <= 0) break;
    resp.append(buf, static_cast<size_t>(n));
  }
  ::close(fd);
  return resp;
}

}  // namespace

TEST_CASE("media: Node serves pushed camera frames as snapshots and MJPEG") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0x6d65u);
  int mesh_port = freePort(rng);
  int http_port = freePort(rng);
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);

  NodeOptions o;
  o.data_dir = ":memory:";
  o.name = "cam";
  o.role = "door_station";
  o.door = "d_front";
  o.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  o.psk.fill(0x5a);
  o.enable_beacon = false;
  o.http_port = http_port;
  Node node(o);
  REQUIRE(node.start());


  CHECK(httpGet(http_port, "/snapshot.jpg").rfind("HTTP/1.1 503", 0) == 0);


  RawFrame f = makeBgra(64, 48);
  node.pushCameraFrame(f.data.data(), f.format, f.w, f.h, f.stride, 12345);

  std::string snap = httpGet(http_port, "/snapshot.jpg");
  REQUIRE(snap.rfind("HTTP/1.1 200", 0) == 0);
  CHECK(snap.find("Content-Type: image/jpeg") != std::string::npos);
  size_t body = snap.find("\r\n\r\n");
  REQUIRE(body != std::string::npos);
  REQUIRE(snap.size() >= body + 6);
  CHECK(static_cast<uint8_t>(snap[body + 4]) == 0xff);  // SOI
  CHECK(static_cast<uint8_t>(snap[body + 5]) == 0xd8);


  int fd = connectTo(http_port);
  REQUIRE(fd >= 0);
  std::string req =
      "GET /stream.mjpeg HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
  REQUIRE(::send(fd, req.data(), req.size(), 0) == static_cast<ssize_t>(req.size()));
  std::string got;
  char buf[4096];
  while (got.find("--frame") == std::string::npos ||
         got.find("Content-Type: image/jpeg") == std::string::npos ||
         got.find("\xff\xd8") == std::string::npos) {
    ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
    REQUIRE(n > 0);
    got.append(buf, static_cast<size_t>(n));
  }
  CHECK(got.find("multipart/x-mixed-replace; boundary=frame") != std::string::npos);
  ::close(fd);

  node.stop();
}
