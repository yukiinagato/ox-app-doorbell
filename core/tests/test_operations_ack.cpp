#include "operation_test_fixture.h"
#include "monocypher-ed25519.h"
#include "node/operation_config.h"
#include "sqlite3.h"
#include <filesystem>

namespace {
struct AckSigner {
  uint8_t secret[64]{}, public_key[32]{};
  explicit AckSigner(uint8_t marker = 0x71) {
    uint8_t seed[32];
    std::fill(std::begin(seed), std::end(seed), marker);
    crypto_ed25519_key_pair(secret, public_key, seed);
  }
  std::string config() const {
    return "{\"protocol\":\"ed25519-v1\",\"actuator_id\":\"front-lock\",\"public_key\":\"" +
        hexEncode(public_key, sizeof(public_key)) + "\"}";
  }
  std::string sign(const std::string& command_text, const std::string& override_id = "") const {
    auto command = json::parse(command_text);
    auto ack = json::obj();
    const auto id = override_id.empty() ? json::getString(command.get(), "operation_id") : override_id;
    json::set(ack.get(), "protocol", "ed25519-v1");
    json::set(ack.get(), "operation_id", id);
    for (const char* field : {"authority_node", "actuator_id", "door", "command_digest"})
      json::set(ack.get(), field, json::getString(command.get(), field));
    json::set(ack.get(), "result", "command_processed");
    // Independent implementation of the published bytes, not the Core's encoder.
    const std::string bytes = "ox-doorbell/operation-ack/v1\n" + id + "\n" +
        json::getString(command.get(), "authority_node") + "\n" +
        json::getString(command.get(), "actuator_id") + "\n" +
        json::getString(command.get(), "door") + "\n" +
        json::getString(command.get(), "command_digest") + "\ncommand_processed\n";
    uint8_t signature[64];
    crypto_ed25519_sign(signature, secret, reinterpret_cast<const uint8_t*>(bytes.data()), bytes.size());
    json::set(ack.get(), "signature", hexEncode(signature, sizeof(signature)));
    return json::dump(ack.get());
  }
};
void configureAck(OperationFleet& fleet, OperationBroker& broker, const AckSigner* signer) {
  fleet.a->setConfigKey("integrations.mqtt.host", "\"127.0.0.1\"");
  fleet.a->setConfigKey("integrations.mqtt.port", std::to_string(broker.port));
  fleet.a->setConfigKey("integrations.mqtt.base_topic", "\"operation-test\"");
  if (signer) fleet.a->setConfigKey("doors.front.operations.ack", signer->config());
  REQUIRE(operationWait([&] {
    auto status = json::parse(fleet.b->statusJson());
    return json::getString(json::get(status.get(), "bridge"), "mqtt") == "connected";
  }));
}
std::string dispatchAckOperation(OperationFleet& fleet, OperationBroker& broker) {
  const auto prepared = fleet.prepare("door_open");
  REQUIRE(prepared.status == 200);
  const auto id = operationField(prepared, "operation_id");
  const auto sent = fleet.execute("door_open", id);
  CAPTURE(sent.body);
  REQUIRE(sent.status == 202);
  REQUIRE(operationWait([&] { return broker.count(id) == 1; }));
  return id;
}
}

TEST_CASE("operations ACK: signed correlated packet settles the production ledger") {
  OperationBroker broker;
  OperationFleet fleet;
  AckSigner signer;
  configureAck(fleet, broker, &signer);
  const auto id = dispatchAckOperation(fleet, broker);
  auto command = json::parse(broker.command(id));
  CHECK(json::getString(command.get(), "ack_protocol") == "ed25519-v1");
  broker.publish(signer.sign(broker.command(id)));
  REQUIRE(operationWait([&] {
    return operationField(fleet.query("door_open", id), "execution_state") == "actuator_ack";
  }, 5000));
  CHECK(broker.count(id) == 1);
}

TEST_CASE("operations ACK: duplicate and out of order packets update only their durable IDs") {
  OperationBroker broker;
  OperationFleet fleet;
  AckSigner signer;
  configureAck(fleet, broker, &signer);
  const auto first = dispatchAckOperation(fleet, broker);
  const auto second = dispatchAckOperation(fleet, broker);
  const auto ack = signer.sign(broker.command(second));
  broker.publish(ack);
  broker.publish(ack);
  REQUIRE(operationWait([&] { return operationField(fleet.query("door_open", second), "execution_state") == "actuator_ack"; }));
  CHECK(operationField(fleet.query("door_open", first), "execution_state") == "dispatched");
  broker.publish(signer.sign(broker.command(first)));
  REQUIRE(operationWait([&] { return operationField(fleet.query("door_open", first), "execution_state") == "actuator_ack"; }));
  CHECK(fleet.execute("door_open", first).status == 200);
  CHECK(fleet.execute("door_open", second).status == 200);
  CHECK(broker.count(first) == 1);
  CHECK(broker.count(second) == 1);
  auto response = fleet.query("door_open", second);
  CHECK(operationField(response, "physical_state") == "unconfirmed");
  CHECK(operationField(response, "actuator_result") == "command_processed");
  CHECK(operationField(response, "retry_mode") == "none");
}

TEST_CASE("operations ACK: unsigned retained forged and mismatched packets cannot confirm") {
  OperationBroker broker;
  OperationFleet fleet;
  AckSigner signer, stranger(0x72);
  configureAck(fleet, broker, &signer);
  const auto target = dispatchAckOperation(fleet, broker);
  const auto barrier = dispatchAckOperation(fleet, broker);
  const auto command = broker.command(target);
  broker.publish("{\"door\":\"front\",\"state\":\"open\"}");
  broker.publish(stranger.sign(command));
  broker.publish(signer.sign(command), true);
  for (const auto& entry : std::vector<std::pair<std::string, std::string>>{
      {"operation_id", std::string(32, 'a')}, {"authority_node", std::string(32, 'a')},
      {"door", "rear"}, {"actuator_id", "rear-lock"}, {"command_digest", std::string(64, 'a')}}) {
    auto wrong = json::parse(command);
    json::set(wrong.get(), entry.first.c_str(), entry.second);
    broker.publish(signer.sign(json::dump(wrong.get())));
  }
  auto unknown = json::parse(signer.sign(command));
  json::set(unknown.get(), "extra", "reject");
  broker.publish(json::dump(unknown.get()));
  auto duplicate = signer.sign(command);
  duplicate.insert(1, "\"result\":\"command_processed\",");
  broker.publish(duplicate);
  broker.publish(std::string(2049, 'x'));
  broker.publish(signer.sign(broker.command(barrier)));
  REQUIRE(operationWait([&] { return operationField(fleet.query("door_open", barrier), "execution_state") == "actuator_ack"; }));
  CHECK(operationField(fleet.query("door_open", target), "execution_state") == "dispatched");
  broker.publish(signer.sign(command));
  REQUIRE(operationWait([&] { return operationField(fleet.query("door_open", target), "execution_state") == "actuator_ack"; }));
  CHECK(broker.count(target) == 1);
}

TEST_CASE("operations ACK: timeout remains queryable and a late authentic result reconciles once") {
  OperationBroker broker;
  OperationFleet fleet;
  AckSigner signer;
  configureAck(fleet, broker, &signer);
  const auto id = dispatchAckOperation(fleet, broker);
  REQUIRE(operationWait([&] { return operationField(fleet.query("door_open", id), "execution_state") == "unknown_after_dispatch"; }, 6000));
  CHECK(operationField(fleet.query("door_open", id), "unknown_reason") == "ack_unavailable");
  CHECK(fleet.execute("door_open", id).status == 202);
  CHECK(broker.count(id) == 1);
  broker.publish(signer.sign(broker.command(id)));
  REQUIRE(operationWait([&] { return operationField(fleet.query("door_open", id), "execution_state") == "actuator_ack"; }));
  CHECK(broker.count(id) == 1);
}

TEST_CASE("operations ACK: no commissioned feedback stays sent and reconnect never resends") {
  OperationBroker broker;
  OperationFleet fleet;
  configureAck(fleet, broker, nullptr);
  const auto id = dispatchAckOperation(fleet, broker);
  const auto sent = fleet.query("door_open", id);
  CHECK(operationField(sent, "execution_state") == "dispatched");
  CHECK(operationField(sent, "unknown_reason") == "ack_unavailable");
  CHECK(operationField(sent, "physical_state") == "unconfirmed");
  broker.publish("{\"operation_id\":\"" + id + "\",\"result\":\"success\"}");
  broker.disconnect();
  REQUIRE(operationWait([&] { return operationField(fleet.query("door_open", id), "execution_state") == "unknown_after_dispatch"; }));
  REQUIRE(operationWait([&] {
    auto status = json::parse(fleet.b->statusJson());
    return json::getString(json::get(status.get(), "bridge"), "mqtt") == "connected";
  }));
  CHECK(operationField(fleet.query("door_open", id), "unknown_reason") == "transport_ambiguous");
  for (int i = 0; i < 3; ++i) CHECK(fleet.execute("door_open", id).status == 202);
  CHECK(broker.count(id) == 1);
}

TEST_CASE("operations ACK: revoked key and changed frozen command cannot settle old sends") {
  OperationBroker broker;
  OperationFleet fleet;
  AckSigner signer, replacement(0x73);
  configureAck(fleet, broker, &signer);
  const auto id = dispatchAckOperation(fleet, broker);
  const auto command = broker.command(id);
  fleet.a->setConfigKey("doors.front.operations.ack", replacement.config());
  const auto replacement_key = hexEncode(replacement.public_key, 32);
  REQUIRE(operationWait([&] { return fleet.b->configJson().find(replacement_key) != std::string::npos; }));
  broker.publish(signer.sign(command));
  broker.publish(replacement.sign(command));
  const auto barrier = dispatchAckOperation(fleet, broker);
  broker.publish(replacement.sign(broker.command(barrier)));
  REQUIRE(operationWait([&] { return operationField(fleet.query("door_open", barrier), "execution_state") == "actuator_ack"; }));
  CHECK(operationField(fleet.query("door_open", id), "execution_state") == "dispatched");
  fleet.a->setConfigKey("doors.front.unlock.command", "\"replacement\"");
  REQUIRE(operationWait([&] { return fleet.b->configJson().find("replacement\"}") != std::string::npos; }));
  fleet.a->setConfigKey("doors.front.operations.ack", signer.config());
  const auto original_key = hexEncode(signer.public_key, 32);
  REQUIRE(operationWait([&] { return fleet.b->configJson().find(original_key) != std::string::npos; }));
  broker.publish(signer.sign(command));
  REQUIRE(operationWait([&] { return operationField(fleet.query("door_open", id), "execution_state") == "unknown_after_dispatch"; }, 6000));
  CHECK(broker.count(id) == 1);
}

TEST_CASE("operations ACK: late front result cannot replace the rear operation after a door switch") {
  OperationBroker broker;
  OperationFleet fleet;
  AckSigner signer;
  configureAck(fleet, broker, &signer);
  const auto front = dispatchAckOperation(fleet, broker);
  fleet.a->setConfigKey("devices." + fleet.a->nodeId() + ".operations.doors", "[\"front\",\"rear\"]");
  fleet.a->setConfigKey("doors.rear.unlock.command", "\"unlock\"");
  fleet.a->setConfigKey("doors.rear.operations.authority_node", "\"" + fleet.b->nodeId() + "\"");
  fleet.a->setConfigKey("doors.rear.operations.ack", signer.config());
  REQUIRE(operationWait([&] { return fleet.b->configJson().find("rear") != std::string::npos; }));
  auto request = json::parse(fleet.request("door_open"));
  json::set(request.get(), "door", "rear");
  OperationHttpResult prepared;
  REQUIRE(operationWait([&] {
    prepared = operationHttp(fleet.a_opts.http_port, "POST", "/api/operations/prepare", json::dump(request.get()), fleet.cookie, fleet.csrf);
    return prepared.status == 200;
  }));
  const auto rear = operationField(prepared, "operation_id");
  json::set(request.get(), "operation_id", rear);
  json::set(request.get(), "authority_node", fleet.b->nodeId());
  REQUIRE(operationHttp(fleet.a_opts.http_port, "POST", "/api/operations/" + rear + "/execute", json::dump(request.get()), fleet.cookie, fleet.csrf).status == 202);
  REQUIRE(operationWait([&] { return broker.count(rear) == 1; }));
  broker.publish(signer.sign(broker.command(front)));
  REQUIRE(operationWait([&] { return operationField(fleet.query("door_open", front), "execution_state") == "actuator_ack"; }));
  auto rear_result = operationHttp(fleet.a_opts.http_port, "GET", "/api/operations/" + rear +
      "?authority_node=" + fleet.b->nodeId() + "&action=door_open&door=rear", "", fleet.cookie);
  CHECK(operationField(rear_result, "operation_id") == rear);
  CHECK(operationField(rear_result, "execution_state") == "dispatched");
  CHECK(fleet.query("door_open", rear).status == 409);
  CHECK(broker.count(front) == 1);
  CHECK(broker.count(rear) == 1);
}

TEST_CASE("operations ACK: strict configuration and degenerate verification keys fail closed") {
  AckSigner signer;
  auto config = json::parse(signer.config());
  std::string error;
  CHECK(operationConfigValid("doors.front.operations.ack", config.get(), &error));
  CHECK(operationAckConfigValid(config.get()));
  for (const auto& y : std::vector<std::string>{std::string(64, '0'), "01" + std::string(62, '0'),
      "ec" + std::string(60, 'f') + "7f", "ed" + std::string(60, 'f') + "7f",
      "ee" + std::string(60, 'f') + "7f",
      "26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05",
      "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a"}) {
    for (int sign = 0; sign < 2; ++sign) {
      Bytes bytes;
      REQUIRE(hexDecode(y, bytes));
      bytes[31] |= sign ? 0x80 : 0;
      json::set(config.get(), "public_key", hexEncode(bytes));
      CHECK_FALSE(operationConfigValid("doors.front.operations.ack", config.get(), &error));
    }
  }
  uint8_t key[32] = {1}, signature[64] = {1};
  const std::string message = "unauthenticated";
  // Demonstrate why rejecting weak commissioned keys is needed with this actual library.
  CHECK(crypto_ed25519_check(signature, key,
      reinterpret_cast<const uint8_t*>(message.data()), message.size()) == 0);
  OperationAck weak{std::string(32, 'a'), std::string(32, 'b'), "front-lock", "front",
      std::string(64, 'c'), hexEncode(signature, 64)};
  CHECK_FALSE(operationAckVerify(weak, hexEncode(key, 32)));
  config = json::parse(signer.config());
  json::set(config.get(), "unexpected", "deny");
  CHECK_FALSE(operationConfigValid("doors.front.operations.ack", config.get(), &error));
  config = json::parse("{\"protocol\":\"ed25519-v1\"}");
  CHECK(operationConfigValid("doors.front.operations.ack", config.get(), &error));
  CHECK_FALSE(operationAckConfigValid(config.get()));
  for (const auto& bad : {"{\"protocol\":\"other\"}", "{\"actuator_id\":\"bad/name\"}",
      "{\"protocol\":\"ed25519-v1\",\"protocol\":\"ed25519-v1\"}", "{\"public_key\":true}"}) {
    auto value = json::parse(bad);
    CHECK_FALSE(operationConfigValid("doors.front.operations.ack", value.get(), &error));
  }
}

TEST_CASE("operations ACK: restart recovers unknown and accepts only the original signed record") {
  const auto directory = testing::uniqueTempPath("doorbell-operation-ack", "");
  std::filesystem::create_directories(directory);
  struct Cleanup {
    std::string directory;
    ~Cleanup() { std::filesystem::remove_all(directory); }
  } cleanup{directory};
  OperationBroker broker;
  OperationFleet fleet(directory);
  AckSigner signer;
  configureAck(fleet, broker, &signer);
  const auto id = dispatchAckOperation(fleet, broker);
  const auto command = broker.command(id);
  const auto authority = fleet.b->nodeId();
  fleet.b->stop();
  fleet.b.reset(new Node(fleet.b_opts));
  REQUIRE(fleet.b->start());
  REQUIRE(fleet.b->nodeId() == authority);
  REQUIRE(operationWait([&] {
    auto status = json::parse(fleet.b->statusJson());
    return json::getString(json::get(status.get(), "bridge"), "mqtt") == "connected";
  }));
  REQUIRE(operationWait([&] { return operationField(fleet.query("door_open", id), "execution_state") == "unknown_after_dispatch"; }));
  CHECK(fleet.execute("door_open", id).status == 202);
  CHECK(broker.count(id) == 1);
  broker.publish(signer.sign(command));
  REQUIRE(operationWait([&] { return operationField(fleet.query("door_open", id), "execution_state") == "actuator_ack"; }));
  CHECK(broker.count(id) == 1);
}

TEST_CASE("operations ACK: a prepared record cannot be promoted by an authentic unsolicited ACK") {
  OperationBroker broker;
  OperationFleet fleet;
  AckSigner signer;
  configureAck(fleet, broker, &signer);
  const auto prepared = fleet.prepare("door_open");
  REQUIRE(prepared.status == 200);
  const auto id = operationField(prepared, "operation_id");
  const auto barrier = dispatchAckOperation(fleet, broker);
  broker.publish(signer.sign(broker.command(barrier), id));
  broker.publish(signer.sign(broker.command(barrier)));
  REQUIRE(operationWait([&] { return operationField(fleet.query("door_open", barrier), "execution_state") == "actuator_ack"; }));
  CHECK(operationField(fleet.query("door_open", id), "execution_state") == "prepared");
  CHECK(broker.count(id) == 0);
}

TEST_CASE("operations ACK: reference executor persists bounded deduplication before its simulated action") {
  const auto file = testing::uniqueTempPath("doorbell-reference-actuator", ".db");
  struct Cleanup {
    std::string file;
    ~Cleanup() { std::filesystem::remove(file); }
  } cleanup{file};
  struct ReferenceExecutor {
    sqlite3* db = nullptr;
    AckSigner signer;
    int simulated_actions = 0;
    explicit ReferenceExecutor(const std::string& file) {
      REQUIRE(sqlite3_open(file.c_str(), &db) == SQLITE_OK);
      REQUIRE(sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS seen(id TEXT PRIMARY KEY,digest TEXT NOT NULL,state TEXT NOT NULL)", nullptr, nullptr, nullptr) == SQLITE_OK);
    }
    ~ReferenceExecutor() { sqlite3_close(db); }
    std::string receive(const std::string& command) {
      auto body = json::parse(command);
      const auto id = json::getString(body.get(), "operation_id");
      const auto digest = json::getString(body.get(), "command_digest");
      REQUIRE(sqlite3_exec(db, "BEGIN IMMEDIATE", nullptr, nullptr, nullptr) == SQLITE_OK);
      sqlite3_stmt* statement = nullptr;
      REQUIRE(sqlite3_prepare_v2(db, "SELECT digest,state FROM seen WHERE id=?", -1, &statement, nullptr) == SQLITE_OK);
      sqlite3_bind_text(statement, 1, id.c_str(), -1, SQLITE_TRANSIENT);
      const bool exists = sqlite3_step(statement) == SQLITE_ROW;
      bool same = !exists || digest == reinterpret_cast<const char*>(sqlite3_column_text(statement, 0));
      const bool completed = exists && std::string(reinterpret_cast<const char*>(sqlite3_column_text(statement, 1))) == "completed";
      sqlite3_finalize(statement);
      if (!same || (exists && !completed)) {
        sqlite3_exec(db, "ROLLBACK", nullptr, nullptr, nullptr);
        return {};
      }
      if (!exists) {
        REQUIRE(sqlite3_prepare_v2(db, "INSERT INTO seen SELECT ?,?,'pending' WHERE (SELECT COUNT(*) FROM seen)<128", -1, &statement, nullptr) == SQLITE_OK);
        sqlite3_bind_text(statement, 1, id.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(statement, 2, digest.c_str(), -1, SQLITE_TRANSIENT);
        REQUIRE(sqlite3_step(statement) == SQLITE_DONE);
        const bool inserted = sqlite3_changes(db) == 1;
        sqlite3_finalize(statement);
        if (!inserted) { sqlite3_exec(db, "ROLLBACK", nullptr, nullptr, nullptr); return {}; }
      }
      REQUIRE(sqlite3_exec(db, "COMMIT", nullptr, nullptr, nullptr) == SQLITE_OK);
      if (!exists) {
        ++simulated_actions;
        REQUIRE(sqlite3_prepare_v2(db, "UPDATE seen SET state='completed' WHERE id=?", -1, &statement, nullptr) == SQLITE_OK);
        sqlite3_bind_text(statement, 1, id.c_str(), -1, SQLITE_TRANSIENT);
        REQUIRE(sqlite3_step(statement) == SQLITE_DONE);
        sqlite3_finalize(statement);
      }
      return signer.sign(command);
    }
  };
  OperationBroker broker;
  OperationFleet fleet;
  AckSigner signer;
  configureAck(fleet, broker, &signer);
  const auto id = dispatchAckOperation(fleet, broker);
  const auto command = broker.command(id);
  {
    ReferenceExecutor executor(file);
    broker.publish(executor.receive(command));
    broker.publish(executor.receive(command));
    CHECK(executor.simulated_actions == 1);
  }
  {
    ReferenceExecutor reopened(file);
    broker.publish(reopened.receive(command));
    CHECK(reopened.simulated_actions == 0);
    auto conflict = json::parse(command);
    json::set(conflict.get(), "command_digest", std::string(64, 'a'));
    CHECK(reopened.receive(json::dump(conflict.get())).empty());
    const auto pending = std::string(32, 'a');
    auto incomplete = json::parse(command);
    json::set(incomplete.get(), "operation_id", pending);
    const auto insert = "INSERT INTO seen VALUES('" + pending + "','" +
        json::getString(incomplete.get(), "command_digest") + "','pending')";
    REQUIRE(sqlite3_exec(reopened.db, insert.c_str(), nullptr, nullptr, nullptr) == SQLITE_OK);
    CHECK(reopened.receive(json::dump(incomplete.get())).empty());
    CHECK(reopened.simulated_actions == 0);
  }
  REQUIRE(operationWait([&] { return operationField(fleet.query("door_open", id), "execution_state") == "actuator_ack"; }));
  CHECK(broker.count(id) == 1);
}
