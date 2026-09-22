#include <atomic>
#include <cstdio>
#include <cstring>
#include <fstream>

#include "doctest.h"
#include "sqlite3.h"
#include "store/store.h"
#include "test_env.h"

using namespace db;

namespace {

// Inject SQLITE_FULL at the real SQLite VFS write boundary. The ledger still runs its actual
// transaction, WAL and COMMIT paths; no Store result or dispatch state is replaced by a mock.
struct FullFile {
  sqlite3_file file;
  sqlite3_file* real;
  bool controlled;
  std::atomic<bool>* full;
  std::atomic<int>* rejected;
};
FullFile* wrapped(sqlite3_file* file) { return reinterpret_cast<FullFile*>(file); }
sqlite3_file* real(sqlite3_file* file) { return wrapped(file)->real; }
const sqlite3_io_methods io = {
    3,
    [](sqlite3_file* f) {
      const int result = real(f)->pMethods->xClose(real(f));
      sqlite3_free(real(f));
      f->pMethods = nullptr;
      return result;
    },
    [](sqlite3_file* f, void* p, int n, sqlite3_int64 offset) { return real(f)->pMethods->xRead(real(f), p, n, offset); },
    [](sqlite3_file* f, const void* p, int n, sqlite3_int64 offset) {
      auto* value = wrapped(f);
      if (value->controlled && value->full->load()) {
        value->rejected->fetch_add(1);
        return SQLITE_FULL;
      }
      return real(f)->pMethods->xWrite(real(f), p, n, offset);
    },
    [](sqlite3_file* f, sqlite3_int64 n) { return real(f)->pMethods->xTruncate(real(f), n); },
    [](sqlite3_file* f, int flags) { return real(f)->pMethods->xSync(real(f), flags); },
    [](sqlite3_file* f, sqlite3_int64* n) { return real(f)->pMethods->xFileSize(real(f), n); },
    [](sqlite3_file* f, int level) { return real(f)->pMethods->xLock(real(f), level); },
    [](sqlite3_file* f, int level) { return real(f)->pMethods->xUnlock(real(f), level); },
    [](sqlite3_file* f, int* result) { return real(f)->pMethods->xCheckReservedLock(real(f), result); },
    [](sqlite3_file* f, int code, void* p) { return real(f)->pMethods->xFileControl(real(f), code, p); },
    [](sqlite3_file* f) { return real(f)->pMethods->xSectorSize(real(f)); },
    [](sqlite3_file* f) { return real(f)->pMethods->xDeviceCharacteristics(real(f)); },
    [](sqlite3_file* f, int region, int size, int extend, void volatile** p) {
      return real(f)->pMethods->xShmMap(real(f), region, size, extend, p);
    },
    [](sqlite3_file* f, int offset, int n, int flags) { return real(f)->pMethods->xShmLock(real(f), offset, n, flags); },
    [](sqlite3_file* f) { real(f)->pMethods->xShmBarrier(real(f)); },
    [](sqlite3_file* f, int remove) { return real(f)->pMethods->xShmUnmap(real(f), remove); },
    [](sqlite3_file* f, sqlite3_int64 offset, int n, void** p) {
      if (real(f)->pMethods->iVersion >= 3 && real(f)->pMethods->xFetch)
        return real(f)->pMethods->xFetch(real(f), offset, n, p);
      *p = nullptr;
      return SQLITE_OK;
    },
    [](sqlite3_file* f, sqlite3_int64 offset, void* p) {
      return real(f)->pMethods->iVersion >= 3 && real(f)->pMethods->xUnfetch
          ? real(f)->pMethods->xUnfetch(real(f), offset, p) : SQLITE_OK;
    }};

class FullVfs {
 public:
  explicit FullVfs(const std::string& path) : path_(path.substr(path.find_last_of("/\\") + 1)) {
    original_ = sqlite3_vfs_find(nullptr);
    REQUIRE(original_ != nullptr);
    proxy_ = *original_;
    proxy_.zName = "doorbell-operation-full";
    proxy_.szOsFile = sizeof(FullFile);
    proxy_.xOpen = [](sqlite3_vfs*, const char* name, sqlite3_file* file, int flags, int* output_flags) {
      auto* context = active_;
      auto* value = wrapped(file);
      value->real = static_cast<sqlite3_file*>(sqlite3_malloc(context->original_->szOsFile));
      if (!value->real) return SQLITE_NOMEM;
      std::memset(value->real, 0, context->original_->szOsFile);
      const int result = context->original_->xOpen(context->original_, name, value->real, flags, output_flags);
      if (result != SQLITE_OK) {
        if (value->real->pMethods) value->real->pMethods->xClose(value->real);
        sqlite3_free(value->real);
        return result;
      }
      value->file.pMethods = &io;
      value->controlled = name && std::strstr(name, context->path_.c_str()) != nullptr;
      value->full = &context->full;
      value->rejected = &context->rejected;
      return SQLITE_OK;
    };
    active_ = this;
    REQUIRE(sqlite3_vfs_register(&proxy_, 1) == SQLITE_OK);
  }
  ~FullVfs() {
    sqlite3_vfs_register(original_, 1);
    sqlite3_vfs_unregister(&proxy_);
    active_ = nullptr;
  }
  std::atomic<bool> full{false};
  std::atomic<int> rejected{0};
 private:
  std::string path_;
  sqlite3_vfs* original_ = nullptr;
  sqlite3_vfs proxy_{};
  static FullVfs* active_;
};
FullVfs* FullVfs::active_ = nullptr;

struct DiskFiles {
  std::string path = testing::uniqueTempPath("doorbell_operations_full", ".sqlite");
  ~DiskFiles() { for (const auto* suffix : {"", "-wal", "-shm"}) std::remove((path + suffix).c_str()); }
};
int64_t fileBytes(const std::string& path) {
  std::ifstream stream(path, std::ios::binary | std::ios::ate);
  return stream ? static_cast<int64_t>(stream.tellg()) : 0;
}
}

TEST_CASE("operations: disk full during real WAL commit grants no dispatch and preserves accepted record") {
  DiskFiles files;
  FullVfs injection(files.path);
  Store store;
  REQUIRE(store.open(files.path));
  REQUIRE(store.operationStart("authority-a", 100000));
  const OperationAuthorization auth{"resident:alice", "credential:1", "grant:1", "config:1", true, false};
  const OperationIntent intent{{"door_open", "d_front", "{}"}, "lock:front", "{\"command\":\"open\"}"};
  const auto prepared = store.operationPrepare(intent, auth, 1000, 100000);
  REQUIRE(prepared.record.has_value());
  const auto id = prepared.record->operation_id;
  REQUIRE(store.operationAccept(id, auth, 1001, 100001).error_code.empty());
  injection.full = true;
  const auto failed = store.operationAcquireDispatch(id, auth, 1002, 100002);
  injection.full = false;
  CHECK(injection.rejected.load() > 0);
  CHECK(failed.error_code == "storage_error");
  CHECK_FALSE(failed.dispatch_acquired);
  const auto unchanged = store.operationQuery(id, auth, 1003, 100003);
  REQUIRE(unchanged.record.has_value());
  CHECK(unchanged.record->state == "accepted");
  CHECK_FALSE(unchanged.record->dispatch_acquired);
  CHECK(store.operationAcquireDispatch(id, auth, 1004, 100004).dispatch_acquired);
  CHECK_FALSE(store.operationAcquireDispatch(id, auth, 1005, 100005).dispatch_acquired);
  std::printf("[operation-storage] rows=1 reserved_bytes=%zu database_bytes=%lld wal_bytes=%lld full_writes=%d\n",
              kOperationReservationBytes, static_cast<long long>(fileBytes(files.path)),
              static_cast<long long>(fileBytes(files.path + "-wal")), injection.rejected.load());
  store.close();
  REQUIRE(store.open(files.path));
  REQUIRE(store.operationStart("authority-a", 100006));
  const auto recovered = store.operationQuery(id, auth, 1, 100006);
  REQUIRE(recovered.record.has_value());
  CHECK(recovered.record->state == "unknown_after_dispatch");
  CHECK_FALSE(store.operationAcquireDispatch(id, auth, 1, 100006).dispatch_acquired);
}
