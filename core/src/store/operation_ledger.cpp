#include "store/store.h"

#include <algorithm>
#include <limits>

#include "sqlite3.h"
#include "util/json.h"

namespace db {
namespace {

class Statement {
 public:
  Statement(sqlite3* db, const std::string& sql) {
    valid_ = db && sqlite3_prepare_v2(db, sql.c_str(), -1, &value_, nullptr) == SQLITE_OK;
  }
  ~Statement() { if (value_) sqlite3_finalize(value_); }
  void bind(int index, const std::string& value) {
    valid_ = valid_ && sqlite3_bind_text(value_, index, value.data(),
                                        static_cast<int>(value.size()), SQLITE_TRANSIENT) == SQLITE_OK;
  }
  void bind(int index, int64_t value) {
    valid_ = valid_ && sqlite3_bind_int64(value_, index, value) == SQLITE_OK;
  }
  int step() { return valid_ ? sqlite3_step(value_) : SQLITE_ERROR; }
  std::string text(int column) const {
    const auto* value = sqlite3_column_text(value_, column);
    return value ? std::string(reinterpret_cast<const char*>(value),
                               static_cast<size_t>(sqlite3_column_bytes(value_, column))) : "";
  }
  int64_t number(int column) const { return sqlite3_column_int64(value_, column); }
 private:
  sqlite3_stmt* value_ = nullptr;
  bool valid_ = false;
};

class Transaction {
 public:
  explicit Transaction(sqlite3* db) : db_(db) {
    active_ = db_ && sqlite3_exec(db_, "BEGIN IMMEDIATE", nullptr, nullptr, nullptr) == SQLITE_OK;
  }
  ~Transaction() { if (active_) sqlite3_exec(db_, "ROLLBACK", nullptr, nullptr, nullptr); }
  bool active() const { return active_; }
  bool commit() {
    if (!active_ || sqlite3_exec(db_, "COMMIT", nullptr, nullptr, nullptr) != SQLITE_OK) return false;
    active_ = false;
    return true;
  }
 private:
  sqlite3* db_;
  bool active_ = false;
};

bool textBounded(const std::string& value, size_t maximum, bool empty = false) {
  return (empty || !value.empty()) && value.size() <= maximum && value.find('\0') == std::string::npos;
}

bool validOperationId(const std::string& value) {
  return value.size() == 32 && std::all_of(value.begin(), value.end(), [](char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
  });
}

json::Doc boundedObject(const std::string& value) {
  if (!textBounded(value, 4096)) return {};
  int depth = 0;
  bool quoted = false, escaped = false;
  for (char character : value) {
    if (quoted) {
      if (escaped) escaped = false;
      else if (character == '\\') escaped = true;
      else if (character == '"') quoted = false;
    } else if (character == '"') quoted = true;
    else if (character == '{' || character == '[') { if (++depth > 8) return {}; }
    else if (character == '}' || character == ']') --depth;
  }
  json::Doc result(cJSON_ParseWithOpts(value.c_str(), nullptr, 1));
  if (!result || !cJSON_IsObject(result.get())) return {};
  return result;
}

bool normalizeRequest(const OperationRequest& request, OperationRequest* normalized) {
  if (request.action != "door_open" && request.action != "sos_start" && request.action != "sos_clear")
    return false;
  if (!textBounded(request.door, 128, request.action != "door_open")) return false;
  if (request.action != "door_open" && !request.door.empty()) return false;
  auto parameters = boundedObject(request.parameters_json);
  // Protocol version 1 has no caller parameters for these actions.
  if (!parameters || parameters->child) return false;
  *normalized = request;
  normalized->parameters_json = "{}";
  return true;
}

bool validAuthorization(const OperationAuthorization& authorization) {
  return authorization.allowed && textBounded(authorization.principal, 128) &&
      textBounded(authorization.credential_version, 256) &&
      textBounded(authorization.grant_version, 256) &&
      textBounded(authorization.config_generation, 256);
}

std::string fingerprint(const OperationRequest& request) {
  auto value = json::obj();
  json::set(value.get(), "action", request.action);
  json::set(value.get(), "door", request.door);
  json::setItem(value.get(), "parameters", json::obj());
  return sha256Hex(toBytes(json::dump(value.get())));
}

std::string metadata(const OperationRecord& record) {
  auto value = json::obj();
  json::set(value.get(), "action", record.intent.request.action);
  json::set(value.get(), "door", record.intent.request.door);
  json::set(value.get(), "actuator_id", record.intent.actuator_id);
  json::set(value.get(), "target", record.intent.target_json);
  json::set(value.get(), "credential_version", record.credential_version);
  json::set(value.get(), "grant_version", record.grant_version);
  json::set(value.get(), "config_generation", record.config_generation);
  json::set(value.get(), "fingerprint", record.fingerprint);
  return json::dump(value.get());
}

bool terminal(const std::string& state) {
  return state == "actuator_ack" || state == "rejected_not_started" ||
      state == "expired_not_started" || state == "failed_before_dispatch";
}

bool validState(const std::string& state) {
  return terminal(state) || state == "prepared" || state == "accepted" ||
      state == "dispatching" || state == "dispatched" || state == "unknown_after_dispatch";
}

const char* kColumns = "authority,operation_id,boot,principal,state,parameters,metadata,result,"
    "created_wall,accepted_wall,updated_wall,terminal_wall,expires_mono,dispatch_acquired";

bool readRecord(Statement& statement, OperationRecord* record) {
  record->authority_node = statement.text(0);
  record->operation_id = statement.text(1);
  record->boot_generation = statement.text(2);
  record->principal = statement.text(3);
  record->state = statement.text(4);
  record->intent.request.parameters_json = statement.text(5);
  auto value = boundedObject(statement.text(6));
  if (!value || !validState(record->state)) return false;
  record->intent.request.action = json::getString(value.get(), "action");
  record->intent.request.door = json::getString(value.get(), "door");
  record->intent.actuator_id = json::getString(value.get(), "actuator_id");
  record->intent.target_json = json::getString(value.get(), "target");
  record->credential_version = json::getString(value.get(), "credential_version");
  record->grant_version = json::getString(value.get(), "grant_version");
  record->config_generation = json::getString(value.get(), "config_generation");
  record->fingerprint = json::getString(value.get(), "fingerprint");
  record->result_json = statement.text(7);
  record->created_wall_ms = statement.number(8);
  record->accepted_wall_ms = statement.number(9);
  record->updated_wall_ms = statement.number(10);
  record->terminal_wall_ms = statement.number(11);
  record->expires_mono_ms = statement.number(12);
  record->dispatch_acquired = statement.number(13) != 0;
  return true;
}

OperationResult load(sqlite3* db, const std::string& authority, const std::string& id) {
  Statement statement(db, std::string("SELECT ") + kColumns +
      " FROM operation_ledger WHERE authority=?1 AND operation_id=?2");
  statement.bind(1, authority);
  statement.bind(2, id);
  const int step = statement.step();
  if (step == SQLITE_DONE) return {"unknown_operation", std::nullopt, false};
  if (step != SQLITE_ROW) return {"storage_error", std::nullopt, false};
  OperationRecord record;
  if (!readRecord(statement, &record)) return {"storage_error", std::nullopt, false};
  return {"", std::move(record), false};
}

bool update(sqlite3* db, const OperationRecord& record) {
  Statement statement(db, "UPDATE operation_ledger SET state=?3,result=?4,accepted_wall=?5,"
      "updated_wall=?6,terminal_wall=?7,dispatch_acquired=?8 WHERE authority=?1 AND operation_id=?2");
  statement.bind(1, record.authority_node);
  statement.bind(2, record.operation_id);
  statement.bind(3, record.state);
  statement.bind(4, record.result_json);
  statement.bind(5, record.accepted_wall_ms);
  statement.bind(6, record.updated_wall_ms);
  statement.bind(7, record.terminal_wall_ms);
  statement.bind(8, int64_t{record.dispatch_acquired ? 1 : 0});
  return statement.step() == SQLITE_DONE && sqlite3_changes(db) == 1;
}

int64_t count(sqlite3* db, const std::string& authority, const std::string& states = "") {
  const std::string sql = "SELECT count(*) FROM operation_ledger" +
      (authority.empty() ? "" : " WHERE authority=?1" + states);
  Statement statement(db, sql);
  if (!authority.empty()) statement.bind(1, authority);
  return statement.step() == SQLITE_ROW ? statement.number(0) : -1;
}

const char* kActiveStates = " AND state IN ('accepted','dispatching','dispatched','unknown_after_dispatch')";

std::string errorJson(const std::string& error) {
  auto value = json::obj();
  json::set(value.get(), "error_code", error);
  return json::dump(value.get());
}

bool validTime(int64_t mono, int64_t wall) { return mono >= 0 && wall >= 0; }

}  // namespace

bool Store::migrateOperationsLocked() {
  return exec("CREATE TABLE IF NOT EXISTS operation_ledger("
      "authority TEXT NOT NULL,operation_id TEXT NOT NULL,boot TEXT NOT NULL,principal TEXT NOT NULL,"
      "state TEXT NOT NULL,parameters TEXT NOT NULL CHECK(length(CAST(parameters AS BLOB))<=4096),"
      "metadata TEXT NOT NULL CHECK(length(CAST(metadata AS BLOB))<=4096),"
      "result TEXT NOT NULL CHECK(length(CAST(result AS BLOB))<=4096),"
      "created_wall INTEGER NOT NULL,accepted_wall INTEGER NOT NULL,updated_wall INTEGER NOT NULL,"
      "terminal_wall INTEGER NOT NULL,expires_mono INTEGER NOT NULL,dispatch_acquired INTEGER NOT NULL,"
      "PRIMARY KEY(authority,operation_id));"
      "CREATE INDEX IF NOT EXISTS idx_operation_state ON operation_ledger(authority,state);"
      "CREATE INDEX IF NOT EXISTS idx_operation_retention ON operation_ledger(state,terminal_wall);");
}

bool Store::operationStart(const std::string& authority_node, int64_t now_wall_ms) {
  if (!textBounded(authority_node, 128) || now_wall_ms < 0) return false;
  std::lock_guard<std::recursive_mutex> lock(mu_);
  if (!operation_boot_.empty()) return authority_node == operation_authority_ && operationReadyLocked();
  std::string boot;
  try { boot = hexEncode(randomBytes(32)); } catch (...) { return false; }
  if (boot.size() != 64) return false;
  Transaction transaction(db_);
  if (!transaction.active()) return false;
  Statement recover(db_, "UPDATE operation_ledger SET state=CASE state "
      "WHEN 'prepared' THEN 'expired_not_started' WHEN 'accepted' THEN 'failed_before_dispatch' "
      "ELSE 'unknown_after_dispatch' END,updated_wall=?2,terminal_wall=CASE "
      "WHEN state IN ('prepared','accepted') THEN ?2 ELSE 0 END,"
      "result=CASE WHEN state IN ('prepared','accepted') THEN '{\"error_code\":\"boot_changed\"}' "
      "ELSE '{\"error_code\":\"outcome_unknown\"}' END "
      "WHERE authority=?1 AND state IN ('prepared','accepted','dispatching','dispatched')");
  recover.bind(1, authority_node);
  recover.bind(2, now_wall_ms);
  if (recover.step() != SQLITE_DONE || !metaSetLocked("operation.authority", authority_node) ||
      !metaSetLocked("operation.boot", boot) ||
      !transaction.commit()) return false;
  operation_authority_ = authority_node;
  operation_boot_ = boot;
  return true;
}

bool Store::operationReadyLocked() {
  if (!db_ || operation_authority_.empty() || operation_boot_.empty()) return false;
  const auto authority = metaGetLocked("operation.authority");
  const auto boot = metaGetLocked("operation.boot");
  return authority && *authority == operation_authority_ && boot && *boot == operation_boot_;
}

bool Store::operationExpireLocked(int64_t now_mono_ms, int64_t now_wall_ms) {
  Statement expire(db_, "UPDATE operation_ledger SET state='expired_not_started',updated_wall=?3,"
      "terminal_wall=?3,result='{\"error_code\":\"prepared_expired\"}' "
      "WHERE authority=?1 AND state='prepared' AND (boot<>?2 OR expires_mono<=?4)");
  expire.bind(1, operation_authority_);
  expire.bind(2, operation_boot_);
  expire.bind(3, now_wall_ms);
  expire.bind(4, now_mono_ms);
  return expire.step() == SQLITE_DONE;
}

OperationResult Store::operationPrepare(const OperationIntent& intent,
    const OperationAuthorization& authorization, int64_t now_mono_ms, int64_t now_wall_ms) {
  if (!validAuthorization(authorization)) return {"forbidden", std::nullopt, false};
  OperationRecord record;
  if (!validTime(now_mono_ms, now_wall_ms) ||
      now_mono_ms > std::numeric_limits<int64_t>::max() - kOperationPreparedMs ||
      !normalizeRequest(intent.request, &record.intent.request) ||
      !textBounded(intent.actuator_id, 256, intent.request.action != "door_open"))
    return {"invalid_request", std::nullopt, false};
  auto target = boundedObject(intent.target_json);
  if (!target) return {"invalid_request", std::nullopt, false};
  record.intent.actuator_id = intent.actuator_id;
  record.intent.target_json = json::dump(target.get());
  record.principal = authorization.principal;
  record.credential_version = authorization.credential_version;
  record.grant_version = authorization.grant_version;
  record.config_generation = authorization.config_generation;
  record.fingerprint = fingerprint(record.intent.request);
  record.state = "prepared";
  record.created_wall_ms = record.updated_wall_ms = now_wall_ms;
  record.expires_mono_ms = now_mono_ms + kOperationPreparedMs;
  std::lock_guard<std::recursive_mutex> lock(mu_);
  Transaction transaction(db_);
  if (!transaction.active() || !operationReadyLocked()) return {"storage_unavailable", std::nullopt, false};
  if (!operationExpireLocked(now_mono_ms, now_wall_ms)) return {"storage_error", std::nullopt, false};
  const auto rows = count(db_, "");
  const auto prepared = count(db_, operation_authority_, " AND state='prepared'");
  const auto active = count(db_, operation_authority_, kActiveStates);
  if (rows < 0 || prepared < 0 || active < 0) return {"storage_error", std::nullopt, false};
  if (rows >= static_cast<int64_t>(kOperationRowLimit) ||
      prepared >= static_cast<int64_t>(kOperationPreparedLimit) ||
      active >= static_cast<int64_t>(kOperationActiveLimit)) {
    if (!transaction.commit()) return {"storage_error", std::nullopt, false};
    return {"operation_capacity", std::nullopt, false};
  }
  record.authority_node = operation_authority_;
  record.boot_generation = operation_boot_;
  const auto frozen = metadata(record);
  // Reserve 4 KiB each for parameters, result and all metadata, including the indexed identity.
  const size_t metadata_bytes = frozen.size() + record.authority_node.size() +
      record.boot_generation.size() + record.principal.size() + 64 + 128;
  if (metadata_bytes > 4096) return {"invalid_request", std::nullopt, false};
  for (int attempt = 0; attempt < 3; ++attempt) {
    try { record.operation_id = hexEncode(randomBytes(16)); }
    catch (...) { return {"storage_unavailable", std::nullopt, false}; }
    if (!validOperationId(record.operation_id)) return {"storage_unavailable", std::nullopt, false};
    Statement insert(db_, "INSERT INTO operation_ledger(" + std::string(kColumns) +
        ") VALUES(?1,?2,?3,?4,'prepared',?5,?6,'{}',?7,0,?7,0,?8,0)");
    insert.bind(1, record.authority_node);
    insert.bind(2, record.operation_id);
    insert.bind(3, record.boot_generation);
    insert.bind(4, record.principal);
    insert.bind(5, record.intent.request.parameters_json);
    insert.bind(6, frozen);
    insert.bind(7, now_wall_ms);
    insert.bind(8, record.expires_mono_ms);
    if (insert.step() == SQLITE_DONE) {
      if (!transaction.commit()) return {"storage_error", std::nullopt, false};
      return {"", record, false};
    }
    if (sqlite3_extended_errcode(db_) != SQLITE_CONSTRAINT_PRIMARYKEY)
      return {"storage_error", std::nullopt, false};
  }
  return {"storage_error", std::nullopt, false};
}

OperationResult Store::operationAdvanceLocked(const std::string& operation_id,
    const OperationAuthorization& authorization, int64_t now_mono_ms, int64_t now_wall_ms,
    const std::optional<OperationRequest>& expected, bool acquire) {
  if (!validAuthorization(authorization)) return {"forbidden", std::nullopt, false};
  if (!validTime(now_mono_ms, now_wall_ms) || !validOperationId(operation_id))
    return {"invalid_request", std::nullopt, false};
  Transaction transaction(db_);
  if (!transaction.active() || !operationReadyLocked()) return {"storage_unavailable", std::nullopt, false};
  if (!operationExpireLocked(now_mono_ms, now_wall_ms)) return {"storage_error", std::nullopt, false};
  auto result = load(db_, operation_authority_, operation_id);
  if (!result.record) return result;
  auto& record = *result.record;
  if (authorization.principal != record.principal) return {"forbidden", std::nullopt, false};
  if (expected) {
    OperationRequest request;
    if (!normalizeRequest(*expected, &request)) return {"invalid_request", std::nullopt, false};
    if (fingerprint(request) != record.fingerprint) return {"idempotency_conflict", record, false};
  }
  if (record.state == "prepared" || record.state == "accepted") {
    if (record.boot_generation != operation_boot_ ||
        authorization.credential_version != record.credential_version ||
        authorization.grant_version != record.grant_version ||
        authorization.config_generation != record.config_generation) {
      record.state = "rejected_not_started";
      record.result_json = errorJson("authorization_or_configuration_changed");
      record.updated_wall_ms = record.terminal_wall_ms = now_wall_ms;
      result.error_code = "authorization_or_configuration_changed";
      if (!update(db_, record)) return {"storage_error", std::nullopt, false};
    } else if (acquire && record.state == "prepared") {
      result.error_code = "not_accepted";
    } else if (acquire && record.state == "accepted" && !record.dispatch_acquired) {
      record.state = "dispatching";
      record.dispatch_acquired = true;
      record.updated_wall_ms = now_wall_ms;
      if (!update(db_, record)) return {"storage_error", std::nullopt, false};
      result.dispatch_acquired = true;
    } else if (!acquire && record.state == "prepared") {
      const auto active = count(db_, operation_authority_, kActiveStates);
      if (active < 0) return {"storage_error", std::nullopt, false};
      if (active >= static_cast<int64_t>(kOperationActiveLimit)) {
        record.state = "rejected_not_started";
        record.result_json = errorJson("operation_capacity");
        record.terminal_wall_ms = now_wall_ms;
        result.error_code = "operation_capacity";
      } else {
        record.state = "accepted";
        record.accepted_wall_ms = now_wall_ms;
      }
      record.updated_wall_ms = now_wall_ms;
      if (!update(db_, record)) return {"storage_error", std::nullopt, false};
    }
  }
  if (!transaction.commit()) return {"storage_error", std::nullopt, false};
  return result;
}

OperationResult Store::operationAccept(const std::string& operation_id,
    const OperationAuthorization& authorization, int64_t mono, int64_t wall,
    const std::optional<OperationRequest>& expected) {
  std::lock_guard<std::recursive_mutex> lock(mu_);
  return operationAdvanceLocked(operation_id, authorization, mono, wall, expected, false);
}

OperationResult Store::operationAcquireDispatch(const std::string& operation_id,
    const OperationAuthorization& authorization, int64_t mono, int64_t wall,
    const std::optional<OperationRequest>& expected) {
  std::lock_guard<std::recursive_mutex> lock(mu_);
  return operationAdvanceLocked(operation_id, authorization, mono, wall, expected, true);
}

OperationResult Store::operationQuery(const std::string& operation_id,
    const OperationAuthorization& authorization, int64_t mono, int64_t wall) {
  if (!validAuthorization(authorization)) return {"forbidden", std::nullopt, false};
  if (!validTime(mono, wall) || !validOperationId(operation_id))
    return {"invalid_request", std::nullopt, false};
  std::lock_guard<std::recursive_mutex> lock(mu_);
  Transaction transaction(db_);
  if (!transaction.active() || !operationReadyLocked()) return {"storage_unavailable", std::nullopt, false};
  if (!operationExpireLocked(mono, wall)) return {"storage_error", std::nullopt, false};
  auto result = load(db_, operation_authority_, operation_id);
  if (result.record && result.record->principal != authorization.principal && !authorization.administrator)
    return {"forbidden", std::nullopt, false};
  if (!transaction.commit()) return {"storage_error", std::nullopt, false};
  return result;
}

OperationPage Store::operationList(const OperationAuthorization& authorization,
    const std::string& after_id, size_t limit, int64_t mono, int64_t wall) {
  if (!validAuthorization(authorization)) return {"forbidden", {}};
  if (!validTime(mono, wall) || (!after_id.empty() && !validOperationId(after_id))) return {"invalid_request", {}};
  std::lock_guard<std::recursive_mutex> lock(mu_);
  Transaction transaction(db_);
  if (!transaction.active() || !operationReadyLocked()) return {"storage_unavailable", {}};
  if (!operationExpireLocked(mono, wall)) return {"storage_error", {}};
  Statement statement(db_, std::string("SELECT ") + kColumns +
      " FROM operation_ledger WHERE authority=?1 AND operation_id>?2 AND (?3=1 OR principal=?4)"
      " ORDER BY operation_id LIMIT ?5");
  statement.bind(1, operation_authority_);
  statement.bind(2, after_id);
  statement.bind(3, int64_t{authorization.administrator ? 1 : 0});
  statement.bind(4, authorization.principal);
  statement.bind(5, static_cast<int64_t>(std::min(limit, size_t{32})));
  OperationPage result;
  int step;
  while ((step = statement.step()) == SQLITE_ROW) {
    OperationRecord record;
    if (!readRecord(statement, &record)) return {"storage_error", {}};
    result.records.push_back(std::move(record));
  }
  if (step != SQLITE_DONE || !transaction.commit()) return {"storage_error", {}};
  return result;
}

OperationResult Store::operationFinishLocked(const std::string& operation_id,
    const std::string& state, const std::string& result_json, int64_t wall) {
  auto value = boundedObject(result_json);
  if (!value || wall < 0 || !validOperationId(operation_id))
    return {"invalid_request", std::nullopt, false};
  Transaction transaction(db_);
  if (!transaction.active() || !operationReadyLocked()) return {"storage_unavailable", std::nullopt, false};
  auto result = load(db_, operation_authority_, operation_id);
  if (!result.record) return result;
  auto& record = *result.record;
  if (record.state == state || terminal(record.state)) return result;
  const bool unstarted = record.state == "prepared" || record.state == "accepted";
  if ((state == "rejected_not_started" && (!unstarted || record.dispatch_acquired)) ||
      (state == "dispatched" && (record.state != "dispatching" || record.boot_generation != operation_boot_)) ||
      (state == "unknown_after_dispatch" && !record.dispatch_acquired))
    return {"invalid_transition", record, false};
  record.state = state;
  record.result_json = json::dump(value.get());
  record.updated_wall_ms = wall;
  if (terminal(state)) record.terminal_wall_ms = wall;
  if (!update(db_, record) || !transaction.commit()) return {"storage_error", std::nullopt, false};
  return result;
}

OperationResult Store::operationMarkDispatched(const std::string& id, const std::string& result, int64_t wall) {
  std::lock_guard<std::recursive_mutex> lock(mu_);
  return operationFinishLocked(id, "dispatched", result, wall);
}

OperationResult Store::operationMarkUnknown(const std::string& id, const std::string& result, int64_t wall) {
  std::lock_guard<std::recursive_mutex> lock(mu_);
  return operationFinishLocked(id, "unknown_after_dispatch", result, wall);
}

OperationResult Store::operationReject(const std::string& id, const std::string& error, int64_t wall) {
  if (!textBounded(error, 128)) return {"invalid_request", std::nullopt, false};
  std::lock_guard<std::recursive_mutex> lock(mu_);
  return operationFinishLocked(id, "rejected_not_started", errorJson(error), wall);
}

OperationResult Store::operationAcknowledge(const std::string& id, const std::string& authority,
    const std::string& actuator, bool authenticated, const std::string& result_json, int64_t wall) {
  if (!authenticated) return {"forbidden", std::nullopt, false};
  auto value = boundedObject(result_json);
  if (!value || wall < 0 || !validOperationId(id) || !textBounded(authority, 128) ||
      !textBounded(actuator, 256)) return {"invalid_request", std::nullopt, false};
  std::lock_guard<std::recursive_mutex> lock(mu_);
  Transaction transaction(db_);
  if (!transaction.active() || !operationReadyLocked()) return {"storage_unavailable", std::nullopt, false};
  auto result = load(db_, operation_authority_, id);
  if (!result.record) return result;
  auto& record = *result.record;
  if (authority != record.authority_node || actuator.empty() || actuator != record.intent.actuator_id)
    return {"ack_mismatch", std::nullopt, false};
  if (!record.dispatch_acquired) return {"not_dispatched", record, false};
  if (record.state == "actuator_ack") return result;
  record.state = "actuator_ack";
  record.result_json = json::dump(value.get());
  record.updated_wall_ms = record.terminal_wall_ms = wall;
  if (!update(db_, record) || !transaction.commit()) return {"storage_error", std::nullopt, false};
  return result;
}

size_t Store::operationPrune(int64_t wall, bool clock_trusted) {
  if (!clock_trusted || wall < kOperationRetentionMs) return 0;
  std::lock_guard<std::recursive_mutex> lock(mu_);
  Transaction transaction(db_);
  if (!transaction.active() || !operationReadyLocked()) return 0;
  Statement statement(db_, "DELETE FROM operation_ledger WHERE authority=?1 AND terminal_wall<?2 "
      "AND state IN ('actuator_ack','rejected_not_started','expired_not_started','failed_before_dispatch')");
  statement.bind(1, operation_authority_);
  statement.bind(2, wall - kOperationRetentionMs);
  if (statement.step() != SQLITE_DONE) return 0;
  const int deleted = sqlite3_changes(db_);
  return transaction.commit() ? static_cast<size_t>(deleted) : 0;
}

}  // namespace db
