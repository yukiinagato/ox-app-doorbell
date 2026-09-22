#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace db {

struct OperationRequest {
  std::string action;
  std::string door;
  std::string parameters_json = "{}";
};

// Trusted Core input, never a request-selected principal or permission bit. Core must resolve
// current door/action permissions and the fixed authority before calling the ledger.
struct OperationAuthorization {
  std::string principal;
  std::string credential_version;
  std::string grant_version;
  std::string config_generation;
  bool allowed = false;
  bool administrator = false;
};

struct OperationIntent {
  OperationRequest request;
  std::string actuator_id;
  // Validated, secret-free adapter command/configuration. Execute cannot replace this target.
  std::string target_json = "{}";
};

struct OperationRecord {
  std::string authority_node;
  std::string operation_id;
  std::string boot_generation;
  std::string principal;
  std::string credential_version;
  std::string grant_version;
  std::string config_generation;
  OperationIntent intent;
  std::string fingerprint;
  std::string state;
  std::string result_json = "{}";
  int64_t created_wall_ms = 0;
  int64_t accepted_wall_ms = 0;
  int64_t updated_wall_ms = 0;
  int64_t terminal_wall_ms = 0;
  int64_t expires_mono_ms = 0;
  bool dispatch_acquired = false;
};

struct OperationResult {
  std::string error_code;
  std::optional<OperationRecord> record;
  // A one-time local qualification, not proof of physical execution. Only true after COMMIT.
  bool dispatch_acquired = false;
};

struct OperationPage {
  std::string error_code;
  std::vector<OperationRecord> records;
};

constexpr int64_t kOperationPreparedMs = 30000;
constexpr int64_t kOperationRetentionMs = 24 * 60 * 60 * int64_t{1000};
constexpr size_t kOperationPreparedLimit = 128;
constexpr size_t kOperationActiveLimit = 2048;
constexpr size_t kOperationRowLimit = 4096;
constexpr size_t kOperationReservationBytes = 12 * 1024;

}  // namespace db
