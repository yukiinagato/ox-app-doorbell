#pragma once

#include <algorithm>
#include <set>
#include <string>

#include "monocypher-ed25519.h"
#include "util/common.h"
#include "util/json.h"

namespace db {
inline bool operationAckHex(const std::string& value, size_t size) {
  return value.size() == size && std::all_of(value.begin(), value.end(), [](char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
  });
}
inline bool operationAckIdentifier(const std::string& value, size_t maximum) {
  return !value.empty() && value.size() <= maximum &&
      std::all_of(value.begin(), value.end(), [](char c) {
        return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') ||
               (c >= 'A' && c <= 'Z') || c == '_' || c == '-';
      });
}
inline bool operationAckPublicKeyValid(const std::string& text) {
  Bytes key;
  if (!operationAckHex(text, 64) || !hexDecode(text, key)) return false;
  key[31] &= 0x7f;
  // Ed25519 encodes y little-endian and the x sign in the high bit. Require y < 2^255-19.
  Bytes prime(32, 0xff);
  prime[0] = 0xed;
  prime[31] = 0x7f;
  if (!std::lexicographical_compare(key.rbegin(), key.rend(), prime.rbegin(), prime.rend())) return false;
  const std::string y = hexEncode(key);
  // The five y coordinates cover all eight low-order Edwards points and both sign encodings.
  // The bundled cofactored verifier intentionally accepts these keys; they cannot authenticate.
  return y != std::string(64, '0') && y != "01" + std::string(62, '0') &&
      y != "ec" + std::string(60, 'f') + "7f" &&
      y != "26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05" &&
      y != "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a";
}
inline bool operationAckConfigField(const std::string& key, const cJSON* value) {
  if (!cJSON_IsString(value)) return false;
  const std::string text = value->valuestring;
  if (key == "protocol") return text == "ed25519-v1";
  if (key == "actuator_id") return operationAckIdentifier(text, 64);
  if (key == "public_key") return operationAckPublicKeyValid(text);
  return false;
}
inline bool operationAckConfigValid(const cJSON* value, bool complete = true) {
  if (!cJSON_IsObject(value)) return false;
  std::set<std::string> seen;
  const cJSON* field = nullptr;
  cJSON_ArrayForEach(field, value) {
    const std::string key = field->string ? field->string : "";
    if (!seen.insert(key).second || !operationAckConfigField(key, field)) return false;
  }
  return !complete || seen.size() == 3;
}
inline std::string operationCommandDigest(const std::string& door, const std::string& command,
                                           const std::string& binding) {
  if (!operationAckIdentifier(door, 128) || !operationAckIdentifier(command, 32) ||
      !operationAckHex(binding, 64)) return {};
  return sha256Hex(toBytes("ox-doorbell/operation-command/v1\n" + door + "\n" + command + "\n" + binding + "\n"));
}
struct OperationAck {
  std::string operation_id, authority, actuator, door, command_digest, signature;
};
inline bool operationAckParse(const std::string& text, OperationAck* output) {
  if (text.empty() || text.size() > 2048 || text.find('\0') != std::string::npos ||
      text.find("\\u0000") != std::string::npos) return false;
  json::Doc body(cJSON_ParseWithOpts(text.c_str(), nullptr, 1));
  if (!body || !cJSON_IsObject(body.get())) return false;
  const std::set<std::string> expected{"protocol", "operation_id", "authority_node", "actuator_id",
      "door", "command_digest", "result", "signature"};
  std::set<std::string> seen;
  const cJSON* field = nullptr;
  cJSON_ArrayForEach(field, body.get()) {
    const std::string key = field->string ? field->string : "";
    if (!cJSON_IsString(field) || !expected.count(key) || !seen.insert(key).second) return false;
  }
  if (seen != expected || json::getString(body.get(), "protocol") != "ed25519-v1" ||
      json::getString(body.get(), "result") != "command_processed") return false;
  OperationAck ack{json::getString(body.get(), "operation_id"), json::getString(body.get(), "authority_node"),
      json::getString(body.get(), "actuator_id"), json::getString(body.get(), "door"),
      json::getString(body.get(), "command_digest"), json::getString(body.get(), "signature")};
  if (!operationAckHex(ack.operation_id, 32) || !operationAckHex(ack.authority, 32) ||
      !operationAckIdentifier(ack.actuator, 64) || !operationAckIdentifier(ack.door, 128) ||
      !operationAckHex(ack.command_digest, 64) || !operationAckHex(ack.signature, 128)) return false;
  *output = std::move(ack);
  return true;
}
inline bool operationAckVerify(const OperationAck& ack, const std::string& public_key) {
  Bytes signature, key;
  if (!operationAckPublicKeyValid(public_key) || !hexDecode(public_key, key) ||
      !hexDecode(ack.signature, signature) || signature.size() != 64) return false;
  const std::string bytes = "ox-doorbell/operation-ack/v1\n" + ack.operation_id + "\n" + ack.authority +
      "\n" + ack.actuator + "\n" + ack.door + "\n" + ack.command_digest + "\ncommand_processed\n";
  return crypto_ed25519_check(signature.data(), key.data(),
      reinterpret_cast<const uint8_t*>(bytes.data()), bytes.size()) == 0;
}
}  // namespace db
