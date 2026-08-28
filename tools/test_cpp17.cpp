// Phase A0 gate verification: exercise the C++17 library features `core` needs
// (std::optional / variant / string_view / function / thread / mutex / map /
// string), compiled against the freshly-built armv7/iOS5.1 libc++ and linked
// statically. Cannot be *run* (no iPad); success == compiles + links + is armv7.
#include <cstdio>
#include <functional>
#include <map>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <thread>
#include <variant>
#include <vector>

static std::optional<int> parse(std::string_view sv) {
  if (sv == "42") return 42;
  return std::nullopt;
}

int main() {
  // string / map
  std::map<std::string, int> m;
  m["doorbell"] = 1;
  m.emplace("sip", 2);

  // string_view + optional
  auto o = parse("42");
  int base = o.value_or(-1);

  // variant
  std::variant<int, std::string> v = std::string("ring");
  std::string tag = std::holds_alternative<std::string>(v)
                        ? std::get<std::string>(v)
                        : std::to_string(std::get<int>(v));

  // function
  std::function<int(int)> f = [base](int x) { return x + base; };

  // thread + mutex (exercise the pthread-backed threading path)
  std::mutex mu;
  int total = 0;
  std::vector<std::thread> ts;
  for (auto& kv : m) {
    ts.emplace_back([&] {
      std::lock_guard<std::mutex> lk(mu);
      total += f(kv.second);
    });
  }
  for (auto& t : ts) t.join();

  std::printf("total=%d tag=%s\n", total, tag.c_str());
  return 0;
}
