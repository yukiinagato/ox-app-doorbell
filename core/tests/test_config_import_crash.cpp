#include "doctest.h"
#include "test_env.h"
#include "node/node.h"
#include "util/json.h"
#include <sqlite3.h>

#if !defined(_WIN32)
#include <cerrno>
#include <csignal>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <vector>
#include <filesystem>
#include <fstream>
#include <poll.h>
#include <spawn.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif

extern char** environ;
using namespace db;
namespace {
constexpr const char* kOperation = "12ab12ab12ab12ab12ab12ab12ab12ab";
int barrier_fd = -1;
std::string crash_phase;

void save(const std::string& path, const std::string& text) {
  std::ofstream stream(path, std::ios::binary); REQUIRE(stream.good());
  stream << text; stream.close(); REQUIRE(stream.good());
}
std::string load(const std::string& path) {
  std::ifstream stream(path, std::ios::binary); REQUIRE(stream.good());
  return {std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()};
}
int scalar(sqlite3* db, const char* query) {
  sqlite3_stmt* statement = nullptr;
  if (sqlite3_prepare_v2(db, query, -1, &statement, nullptr) != SQLITE_OK) return -1;
  const int result = sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : -1;
  sqlite3_finalize(statement); return result;
}
[[noreturn]] void barrier(const std::string& message) {
  const std::string line = message + "\n";
  if (::write(barrier_fd, line.data(), line.size()) != static_cast<ssize_t>(line.size())) _exit(91);
  // Only the parent can advance this point, by SIGKILL. No Node/Store destructor runs.
  for (;;) ::pause();
}
std::string diskState(sqlite3* db, const std::string& phase) {
  auto state = json::obj(); json::set(state.get(), "phase", phase);
  json::set(state.get(), "autocommit", static_cast<int64_t>(sqlite3_get_autocommit(db)));
  json::set(state.get(), "new_rows", static_cast<int64_t>(scalar(db,
      "SELECT count(*) FROM config WHERE key GLOB 'import_crash_*' AND deleted=0 "
      "AND value_json LIKE '%new-generation-%'")));
  json::set(state.get(), "receipt_rows", static_cast<int64_t>(scalar(db,
      "SELECT count(*) FROM meta WHERE key='config_import_receipts_v1'")));
  return json::dump(state.get());
}
void transactionBarrier(sqlite3_context* context, int count, sqlite3_value** values) {
  if (count != 1) { sqlite3_result_error(context, "invalid barrier", -1); return; }
  const auto* raw = sqlite3_value_text(values[0]);
  const std::string point = raw ? reinterpret_cast<const char*>(raw) : "";
  if (point != crash_phase) { sqlite3_result_int(context, 0); return; }
  sqlite3* db = sqlite3_context_db_handle(context);
  barrier(diskState(db, point));
}
int installBarrier(sqlite3* db, char**, const sqlite3_api_routines*) {
  return sqlite3_create_function_v2(db, "t29_crash_barrier", 1, SQLITE_UTF8, nullptr,
                                    transactionBarrier, nullptr, nullptr, nullptr);
}

struct CrashNode {
  SimClock clock;
  NodeOptions options;
  std::unique_ptr<Node> node;
  std::string session, csrf;
  explicit CrashNode(const std::string& directory) {
    options.data_dir = directory; options.enable_beacon = false;
    options.listen_addr = "127.0.0.1:" + std::to_string(testing::freeListenPort());
    options.http_port = testing::freeListenPort();
    NodeDeps deps; deps.clock = &clock;
    node.reset(new Node(options, std::move(deps))); REQUIRE(node->start());
    auto response = post("/api/login", R"({"password":"testpw"})", false);
    REQUIRE(response.find("HTTP/1.1 200") == 0);
    const auto begin = response.find("dbsess="); REQUIRE(begin != std::string::npos);
    session = response.substr(begin + 7, response.find(';', begin) - begin - 7);
    csrf = json::getString(body(response).get(), "csrf_token"); REQUIRE_FALSE(csrf.empty());
  }
  ~CrashNode() { node->stop(); }
  std::string post(const std::string& path, const std::string& body, bool authenticated = true) {
    const int fd = ::socket(AF_INET, SOCK_STREAM, 0); REQUIRE(fd >= 0);
    sockaddr_in address{}; address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK); address.sin_port = htons(options.http_port);
    REQUIRE(::connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
    const std::string origin = "http://127.0.0.1:" + std::to_string(options.http_port);
    std::string request = "POST " + path + " HTTP/1.1\r\nHost: 127.0.0.1:" +
        std::to_string(options.http_port) + "\r\nOrigin: " + origin + "\r\n";
    if (authenticated) request += "Cookie: dbsess=" + session + "\r\nX-Doorbell-CSRF: " + csrf + "\r\n";
    request += "Content-Type: application/json\r\nContent-Length: " + std::to_string(body.size()) +
        "\r\nConnection: close\r\n\r\n" + body;
    size_t sent = 0;
    while (sent < request.size()) {
      const auto count = ::send(fd, request.data() + sent, request.size() - sent, 0);
      REQUIRE(count > 0); sent += static_cast<size_t>(count);
    }
    timeval timeout{10, 0}; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    std::string response; char bytes[8192];
    for (;;) { const auto n = ::recv(fd, bytes, sizeof(bytes), 0); if (n <= 0) break; response.append(bytes, n); }
    ::close(fd); return response;
  }
  static json::Doc body(const std::string& response) {
    const auto split = response.find("\r\n\r\n");
    return json::parse(split == std::string::npos ? "" : response.substr(split + 4));
  }
  json::Doc publicConfig() {
    auto snapshot = json::parse(node->configSnapshotJson());
    return json::Doc(cJSON_Duplicate(json::get(snapshot.get(), "config"), 1));
  }
};
json::Doc section(const std::string& generation, int entity) {
  auto object = json::obj();
  for (int leaf = 0; leaf < 20; ++leaf)
    json::set(object.get(), ("leaf_" + std::to_string(leaf)).c_str(),
        generation + "-generation-" + std::to_string(entity) + ":" + std::to_string(leaf) + std::string(256, 'x'));
  return object;
}
std::string receipt(sqlite3* db) {
  sqlite3_stmt* statement = nullptr;
  REQUIRE(sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key='config_import_receipts_v1'",
                            -1, &statement, nullptr) == SQLITE_OK);
  std::string result;
  if (sqlite3_step(statement) == SQLITE_ROW)
    result = reinterpret_cast<const char*>(sqlite3_column_text(statement, 0));
  sqlite3_finalize(statement); return result;
}

void childWork(const std::string& directory) {
  REQUIRE(sqlite3_auto_extension(reinterpret_cast<void (*)()>(installBarrier)) == SQLITE_OK);
  CrashNode fixture(directory);
  auto initial = json::arr();
  for (int i = 0; i < 16; ++i) {
    auto* op = json::pushObj(initial.get()); json::set(op, "op", "set");
    json::set(op, "key", "import_crash_" + std::to_string(i));
    json::setItem(op, "value", section("old", i));
  }
  REQUIRE(json::getBool(json::parse(fixture.node->configBatchJson(json::dump(initial.get()))).get(), "ok"));
  auto before = fixture.publicConfig(); save(directory + "/before.json", json::dump(before.get()));
  auto expected = json::Doc(cJSON_Duplicate(before.get(), 1));
  for (int i = 0; i < 16; ++i)
    json::setItem(expected.get(), ("import_crash_" + std::to_string(i)).c_str(), section("new", i));
  save(directory + "/expected.json", json::dump(expected.get()));
  auto snapshot = json::parse(fixture.node->configSnapshotJson()); auto request = json::obj();
  json::set(request.get(), "schema_version", int64_t{2});
  json::set(request.get(), "expected_revision", json::getString(snapshot.get(), "revision"));
  auto document = json::obj(); json::set(document.get(), "schema_version", int64_t{2});
  json::setItem(document.get(), "config", std::move(expected));
  json::setItem(request.get(), "document", std::move(document));
  auto staged = CrashNode::body(fixture.post("/api/config/import/stage", json::dump(request.get())));
  REQUIRE(json::getBool(staged.get(), "ok"));
  auto action = json::obj(); json::set(action.get(), "schema_version", int64_t{2});
  json::set(action.get(), "stage_token", json::getString(staged.get(), "stage_token"));
  json::set(action.get(), "digest", json::getString(staged.get(), "digest"));
  auto preflight = CrashNode::body(fixture.post("/api/config/import/preflight", json::dump(action.get())));
  INFO(json::dump(preflight.get()));
  REQUIRE(json::getBool(preflight.get(), "can_commit"));
  REQUIRE(json::getInt(preflight.get(), "expanded_leaf_mutations") == 320);
  REQUIRE(json::getInt(preflight.get(), "mutation_records") == 16);
  json::set(action.get(), "operation_id", kOperation);
  save(directory + "/request.json", json::dump(action.get()));
  sqlite3* db = nullptr;
  REQUIRE(sqlite3_open((directory + "/doorbell.db").c_str(), &db) == SQLITE_OK);
  REQUIRE(sqlite3_exec(db,
      "CREATE TRIGGER crash_before_receipt BEFORE INSERT ON meta "
      "WHEN NEW.key='config_import_receipts_v1' BEGIN SELECT t29_crash_barrier('before_receipt'); END;"
      "CREATE TRIGGER crash_after_receipt AFTER INSERT ON meta "
      "WHEN NEW.key='config_import_receipts_v1' BEGIN SELECT t29_crash_barrier('after_receipt'); END;",
      nullptr, nullptr, nullptr) == SQLITE_OK);
  if (crash_phase == "before_commit") barrier(diskState(db, crash_phase));
  sqlite3_close(db);
  auto response = fixture.post("/api/config/import/commit", json::dump(action.get()));
  REQUIRE(response.find("HTTP/1.1 200") == 0);
  auto result = CrashNode::body(response); REQUIRE(json::getBool(result.get(), "ok"));
  save(directory + "/result.json", json::dump(result.get()));
  REQUIRE(sqlite3_open((directory + "/doorbell.db").c_str(), &db) == SQLITE_OK);
  REQUIRE(scalar(db, "SELECT count(*) FROM meta WHERE key='config_import_receipts_v1'") == 1);
  auto committed = receipt(db);
  REQUIRE(json::getBool(json::get(json::get(json::parse(committed).get(), kOperation), "result"), "ok"));
  barrier(diskState(db, "after_commit"));
}

std::string executablePath() {
#if defined(__APPLE__)
  uint32_t size = 0; _NSGetExecutablePath(nullptr, &size);
  std::string path(size, '\0'); REQUIRE(_NSGetExecutablePath(&path[0], &size) == 0);
  path.resize(std::strlen(path.c_str())); return std::filesystem::canonical(path).string();
#else
  char path[8192]; const auto length = ::readlink("/proc/self/exe", path, sizeof(path) - 1);
  REQUIRE(length > 0); return std::string(path, static_cast<size_t>(length));
#endif
}
struct Child {
  pid_t pid = -1;
  int read_fd = -1;
  explicit Child(const std::string& phase, const std::string& directory) {
    int descriptors[2]; REQUIRE(::pipe(descriptors) == 0); read_fd = descriptors[0];
    const auto executable = executablePath();
    std::vector<std::string> args{executable, "--test-case=config import crash worker", "--no-skip=true", "--no-colors=true"};
    std::vector<char*> argv; for (auto& arg : args) argv.push_back(&arg[0]); argv.push_back(nullptr);
    std::vector<std::string> vars;
    for (char** entry = environ; *entry; ++entry) {
      if (std::string(*entry).rfind("DB_TEST_IMPORT_CRASH_", 0) != 0) vars.emplace_back(*entry);
    }
    vars.push_back("DB_TEST_IMPORT_CRASH_PHASE=" + phase);
    vars.push_back("DB_TEST_IMPORT_CRASH_DIRECTORY=" + directory);
    vars.push_back("DB_TEST_IMPORT_CRASH_FD=" + std::to_string(descriptors[1]));
    std::vector<char*> env; for (auto& var : vars) env.push_back(&var[0]); env.push_back(nullptr);
    posix_spawn_file_actions_t actions; REQUIRE(posix_spawn_file_actions_init(&actions) == 0);
    REQUIRE(posix_spawn_file_actions_addclose(&actions, read_fd) == 0);
    const auto error = posix_spawn(&pid, executable.c_str(), &actions, nullptr, argv.data(), env.data());
    posix_spawn_file_actions_destroy(&actions); ::close(descriptors[1]); REQUIRE(error == 0);
  }
  ~Child() {
    if (pid > 0) { ::kill(pid, SIGKILL); int status = 0; ::waitpid(pid, &status, 0); }
    if (read_fd >= 0) ::close(read_fd);
  }
  std::string awaitBarrier() {
    pollfd descriptor{read_fd, POLLIN, 0}; REQUIRE(::poll(&descriptor, 1, 45000) == 1);
    char bytes[4096]; const auto count = ::read(read_fd, bytes, sizeof(bytes)); REQUIRE(count > 0);
    return {bytes, static_cast<size_t>(count)};
  }
  void terminate() {
    REQUIRE(::kill(pid, SIGKILL) == 0); int status = 0;
    REQUIRE(::waitpid(pid, &status, 0) == pid); pid = -1;
    REQUIRE(WIFSIGNALED(status)); REQUIRE(WTERMSIG(status) == SIGKILL);
  }
};
struct FixtureDirectory {
  std::string path = testing::uniqueTempPath("doorbell_import_crash", "");
  ~FixtureDirectory() { std::filesystem::remove_all(path); }
};
}

TEST_CASE("config import crash worker" * doctest::skip()) {
  const char* phase = std::getenv("DB_TEST_IMPORT_CRASH_PHASE");
  const char* directory = std::getenv("DB_TEST_IMPORT_CRASH_DIRECTORY");
  const char* fd = std::getenv("DB_TEST_IMPORT_CRASH_FD");
  REQUIRE(phase != nullptr); REQUIRE(directory != nullptr); REQUIRE(fd != nullptr);
  crash_phase = phase; barrier_fd = std::stoi(fd); childWork(directory);
}

TEST_CASE("config import crash: SIGKILL preserves complete configuration and matching durable receipt") {
  for (const std::string phase : {"before_commit", "before_receipt", "after_receipt", "after_commit"}) {
    CAPTURE(phase); FixtureDirectory directory;
    Child child(phase, directory.path);
    const auto observed = child.awaitBarrier(); INFO(observed);
    auto state = json::parse(observed); REQUIRE(state);
    REQUIRE(json::getString(state.get(), "phase") == phase);
    const bool in_transaction = phase == "before_receipt" || phase == "after_receipt";
    CHECK(json::getInt(state.get(), "autocommit") == (in_transaction ? 0 : 1));
    CHECK(json::getInt(state.get(), "new_rows") == (phase == "before_commit" ? 0 : 16));
    CHECK(json::getInt(state.get(), "receipt_rows") ==
          (phase == "after_receipt" || phase == "after_commit" ? 1 : 0));
    child.terminate();
    sqlite3* db = nullptr;
    REQUIRE(sqlite3_open((directory.path + "/doorbell.db").c_str(), &db) == SQLITE_OK);
    const bool committed = phase == "after_commit";
    const auto durable_receipt = receipt(db);
    CHECK(durable_receipt.empty() == !committed);
    const int new_rows = scalar(db, "SELECT count(*) FROM config WHERE key GLOB 'import_crash_*' "
                                   "AND deleted=0 AND value_json LIKE '%new-generation-%'");
    CHECK(new_rows == (committed ? 16 : 0));
    CHECK(scalar(db, "SELECT count(*) FROM config WHERE key GLOB 'import_crash_*' AND deleted=0") == 16);
    REQUIRE(sqlite3_exec(db, "DROP TRIGGER crash_before_receipt; DROP TRIGGER crash_after_receipt;",
                        nullptr, nullptr, nullptr) == SQLITE_OK);
    sqlite3_close(db);
    {
      CrashNode restarted(directory.path);
      auto old_config = json::parse(load(directory.path + "/before.json"));
      auto new_config = json::parse(load(directory.path + "/expected.json"));
      auto actual = restarted.publicConfig();
      CHECK(cJSON_Compare(actual.get(), committed ? new_config.get() : old_config.get(), 1));
      CHECK_FALSE(cJSON_Compare(actual.get(), committed ? old_config.get() : new_config.get(), 1));
      const auto replay = CrashNode::body(restarted.post("/api/config/import/commit", load(directory.path + "/request.json")));
      if (committed) {
        REQUIRE(json::getBool(replay.get(), "ok"));
        auto stored = json::parse(durable_receipt);
        CHECK(cJSON_Compare(replay.get(), json::get(json::get(stored.get(), kOperation), "result"), 1));
        CHECK(json::dump(replay.get()) == load(directory.path + "/result.json"));
      } else CHECK(json::getString(replay.get(), "error_code") == "stage_expired");
      CHECK(cJSON_Compare(restarted.publicConfig().get(), actual.get(), 1));
    }
    std::printf("[import-crash] phase=%s signal=SIGKILL barrier=%s recovered=%s new_rows=%d receipt=%s replay=%s\n",
        phase.c_str(), json::dump(state.get()).c_str(), committed ? "complete_new" : "complete_old", new_rows,
        committed ? "present" : "absent", committed ? "original_result" : "stage_expired");
    std::fflush(stdout);
  }
}
#endif
