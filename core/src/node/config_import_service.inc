  std::string configImportFailure(const std::string& code, int status, int* status_out) {
    if (status_out) *status_out = status;
    auto result = json::obj(); json::setBool(result.get(), "ok", false);
    json::set(result.get(), "schema_version", int64_t{2});
    json::set(result.get(), "error_code", code); json::set(result.get(), "retry_mode", "none");
    return json::dump(result.get());
  }

  void clearConfigImport() {
    import_stage = {};
    if (import_stage_timer) loop->cancel(import_stage_timer);
    import_stage_timer = 0;
  }

  void expireConfigImport() {
    if (import_stage.token.empty()) return;
    const auto now = clock->monoMs();
    if (now < import_stage.issued_mono || now - import_stage.issued_mono >= kConfigImportTtlMs ||
        import_stage.boot != snapshot_epoch || import_stage.principal != adminCredentialVersionOnLoop())
      clearConfigImport();
  }

  json::Doc configImportReceiptLedger() {
    const auto stored = store.metaGet("config_import_receipts_v1");
    if (!stored) return json::obj();
    if (stored->size() > 256 * 1024) return {};
    auto ledger = configImportParse(*stored);
    if (!cJSON_IsObject(ledger.get()) || cJSON_GetArraySize(ledger.get()) > 128) return {};
    std::set<std::string> operations;
    const cJSON* receipt = nullptr;
    cJSON_ArrayForEach(receipt, ledger.get()) {
      const std::string operation = receipt->string ? receipt->string : "";
      if (!configImportHex(operation, 32) || !operations.insert(operation).second ||
          !configImportFields(receipt, {"principal", "digest", "token_digest", "result"}) ||
          !configImportHex(json::getString(receipt, "principal"), 64) ||
          !configImportHex(json::getString(receipt, "digest"), 64) ||
          !configImportHex(json::getString(receipt, "token_digest"), 64)) return {};
      const auto* result = json::get(receipt, "result");
      const auto* schema = json::get(result, "schema_version");
      const auto* count = json::get(result, "n");
      const auto revision = json::getString(result, "committed_revision");
      if (!configImportFields(result, {"ok", "schema_version", "operation_id", "digest",
                                      "atomicity", "n", "committed_revision"}) ||
          !cJSON_IsTrue(json::get(result, "ok")) || !cJSON_IsNumber(schema) || schema->valuedouble != 2 ||
          json::getString(result, "operation_id") != operation ||
          json::getString(result, "digest") != json::getString(receipt, "digest") ||
          json::getString(result, "atomicity") != "local_persistence" ||
          !cJSON_IsNumber(count) || count->valuedouble < 0 || count->valuedouble > kConfigImportLeaves ||
          count->valuedouble != static_cast<int64_t>(count->valuedouble) ||
          revision.empty() || revision.size() > 256) return {};
    }
    return ledger;
  }

  std::string configImportPrepare(std::vector<LwwMutation>* mutations,
                                  std::vector<LwwMutation>* journal, json::Doc* report) {
    auto target = json::parse(import_stage.candidate);
    auto previous = json::parse(config->materializeJson());
    auto result = json::obj(); json::setBool(result.get(), "ok", true);
    json::set(result.get(), "schema_version", int64_t{2});
    json::set(result.get(), "stage_token", import_stage.token);
    json::set(result.get(), "digest", import_stage.digest);
    json::set(result.get(), "expected_revision", import_stage.revision);
    json::set(result.get(), "atomicity", "local_persistence");
    auto* differences = json::addArr(result.get(), "differences");
    auto* missing_secrets = json::addArr(result.get(), "missing_secret_refs");
    auto* missing_assets = json::addArr(result.get(), "missing_assets");
    auto* problems = json::addArr(result.get(), "problems");
    auto problem = [&](const std::string& code) { json::push(problems, json::Doc(cJSON_CreateString(code.c_str()))); };
    auto receipts = configImportReceiptLedger();
    if (!receipts) problem("receipt_store_invalid");
    else if (cJSON_GetArraySize(receipts.get()) >= 128) problem("receipt_capacity_exceeded");
    std::map<std::string, std::string> old_leaves, new_leaves;
    configImportLeaves(previous.get(), "", &old_leaves);
    configImportLeaves(target.get(), "", &new_leaves);
    std::set<std::string> paths;
    for (const auto& pair : old_leaves) paths.insert(pair.first);
    for (const auto& pair : new_leaves) paths.insert(pair.first);
    for (const auto& path : paths) {
      const auto old = old_leaves.find(path), next = new_leaves.find(path);
      if (old != old_leaves.end() && next != new_leaves.end() && old->second == next->second) continue;
      auto* difference = json::pushObj(differences);
      json::set(difference, "path", path);
      json::set(difference, "op", next == new_leaves.end() ? "delete" : "set");
      json::setBool(difference, "before_exists", old != old_leaves.end());
      json::setBool(difference, "after_exists", next != new_leaves.end());
      std::string sensitivity_path = path;
      std::replace(sensitivity_path.begin(), sensitivity_path.end(), '/', '.');
      if (old != old_leaves.end()) {
        auto value = json::parse(old->second);
        json::setItem(difference, "before", configEditSafeValue(value.get(), sensitivity_path));
      }
      if (next != new_leaves.end()) {
        auto value = json::parse(next->second);
        json::setItem(difference, "after", configEditSafeValue(value.get(), sensitivity_path));
      }
    }
    const int leaf_count = cJSON_GetArraySize(differences);
    json::set(result.get(), "expanded_leaf_mutations", static_cast<int64_t>(leaf_count));
    if (leaf_count > static_cast<int>(kConfigImportLeaves)) problem("capacity_exceeded");
    std::string error;
    if (!configCandidateValid(target.get(), "", &error)) problem("invalid_configuration");

    std::set<std::string> entities;
    for (const auto* root : {previous.get(), target.get()}) {
      const cJSON* section = nullptr;
      cJSON_ArrayForEach(section, root) {
        const std::string key = section->string ? section->string : "";
        if (key == "admin") continue;
        if (key == "devices") {
          if (!cJSON_IsObject(section)) { problem("invalid_device_collection"); continue; }
          const cJSON* device = nullptr;
          cJSON_ArrayForEach(device, section) {
            const std::string id = device->string ? device->string : "";
            if (!configImportHex(id, 32)) { problem("invalid_device_id"); continue; }
            entities.insert("devices." + id);
          }
        } else entities.insert(key);
      }
    }
    std::vector<LwwMutation> intents;
    for (const auto& entity : entities) {
      const auto* old = configImportAt(previous.get(), entity);
      const auto* next = configImportAt(target.get(), entity);
      if ((!old && !next) || (old && next && cJSON_Compare(old, next, 1))) continue;
      const std::string value = next ? json::dump(next) : "";
      intents.push_back({entity, value, !next});
      std::map<std::string, std::string> units;
      if (next) {
        json::Doc base(cJSON_Duplicate(next, 1));
        const auto* ui = entity.rfind("devices.", 0) == 0
            ? json::get(json::get(next, "local"), "ui") : nullptr;
        if (ui) {
          if (!configImportFields(ui, {"elements"}) || !cJSON_IsObject(json::get(ui, "elements")))
            problem("invalid_ui_override");
          cJSON_DeleteItemFromObjectCaseSensitive(json::get(base.get(), "local"), "ui");
          std::function<void(const cJSON*, const std::string&)> styles =
              [&](const cJSON* style, const std::string& key) {
            if (!cJSON_IsObject(style)) { problem("invalid_ui_override"); return; }
            std::string validation_error;
            if (configWriteValidEffective(key, style, &validation_error)) {
              units[key] = json::dump(style); return;
            }
            bool branch = style->child != nullptr;
            const cJSON* child = nullptr;
            cJSON_ArrayForEach(child, style) branch = branch && cJSON_IsObject(child);
            if (!branch) { problem("invalid_ui_override"); return; }
            cJSON_ArrayForEach(child, style) styles(child, key + "." + child->string);
          };
          const cJSON* element = nullptr;
          cJSON_ArrayForEach(element, json::get(ui, "elements"))
            styles(element, entity + ".local.ui.elements." + element->string);
        }
        units[entity] = json::dump(base.get());
        for (const auto& unit : units) mutations->push_back({unit.first, unit.second, false});
      } else mutations->push_back({entity, "", true});
      for (const auto& entry : config->byPrefix(entity + ".")) {
        if (units.count(entry.first)) continue;
        std::string covering;
        for (const auto& unit : units)
          if (entry.first.compare(0, unit.first.size() + 1, unit.first + ".") == 0 &&
              unit.first.size() > covering.size()) covering = unit.first;
        auto projected = covering.empty() ? json::Doc{} : json::parse(units.at(covering));
        const auto* desired = projected
            ? configImportAt(projected.get(), entry.first.substr(covering.size() + 1)) : nullptr;
        const std::string encoded = desired ? json::dump(desired) : "";
        if (desired && encoded == entry.second) continue;
        mutations->push_back({entry.first, encoded, !desired});
      }
    }
    // Ancestor replacement/tombstones must precede the semantic child records they contain.
    std::sort(mutations->begin(), mutations->end(), [](const LwwMutation& a, const LwwMutation& b) {
      return a.key < b.key;
    });
    if (mutations->size() > kConfigImportLeaves) problem("capacity_exceeded");
    {
      struct PreviewScope {
        json::Doc& target; json::Doc previous;
        ~PreviewScope() { target = std::move(previous); }
      } scope{cfg, std::move(cfg)};
      cfg = json::Doc(cJSON_Duplicate(target.get(), 1));
      auto assets = referencedAssets();
      const auto* ledger = json::get(cfg.get(), "assets"); const cJSON* item = nullptr;
      cJSON_ArrayForEach(item, ledger) {
        if (item->string && isSha256HexStr(item->string)) assets.insert(item->string);
        else problem("invalid_asset_id");
      }
      std::set<std::string> secrets;
      std::function<void(const cJSON*, const std::string&)> inspect = [&](const cJSON* value, const std::string& path) {
        if (cJSON_IsString(value)) {
          const std::string text = value->valuestring ? value->valuestring : "";
          if (text.rfind("secret:", 0) == 0) {
            if (!secretRefValid(text)) problem("invalid_secret_reference"); else secrets.insert(text);
          }
          if (text.rfind("asset:", 0) == 0) {
            const auto hash = text.substr(6);
            if (!isSha256HexStr(hash)) problem("invalid_asset_reference"); else assets.insert(hash);
          }
        }
        const cJSON* child = nullptr;
        cJSON_ArrayForEach(child, value)
          inspect(child, cJSON_IsObject(value) ? (path.empty() ? child->string : path + "." + child->string) : path);
      };
      inspect(cfg.get(), "");
      for (const auto& ref : secrets) if (secretValue(ref).empty())
        json::push(missing_secrets, json::Doc(cJSON_CreateString(ref.c_str())));
      for (const auto& hash : assets) if (!assetCached(hash))
        json::push(missing_assets, json::Doc(cJSON_CreateString(hash.c_str())));
    }
    for (const auto& mutation : *mutations) {
      if (mutation.deleted) continue;
      auto value = json::parse(mutation.value_json);
      if (!configWriteValidEffective(mutation.key, value.get(), &error)) problem("invalid_write_scope");
    }
    HlcClock preview_clock(*clock, node_id.substr(0, 8));
    LwwMap preview(node_id, preview_clock); preview.load(config->all()); preview.mutate(*mutations);
    auto materialized = json::parse(preview.materializeJson());
    if (!cJSON_Compare(materialized.get(), target.get(), 1)) problem("unsupported_document_shape");
    if (cJSON_GetArraySize(problems) == 0) {
      const auto journal_error = appendConfigEdits(config->all(), intents, target.get(), node_id, nullptr, journal);
      if (!journal_error.empty()) problem(journal_error);
    }
    const bool ready = cJSON_GetArraySize(problems) == 0 && cJSON_GetArraySize(missing_secrets) == 0 &&
                       cJSON_GetArraySize(missing_assets) == 0;
    json::setBool(result.get(), "can_commit", ready);
    json::set(result.get(), "mutation_records", static_cast<int64_t>(mutations->size()));
    json::set(result.get(), "expires_in_ms", std::max<int64_t>(0,
        kConfigImportTtlMs - (clock->monoMs() - import_stage.issued_mono)));
    *report = std::move(result);
    return ready ? "" : "preflight_failed";
  }

  std::string configImportJsonOnLoop(const std::string& action, const std::string& request_json,
                                     const std::string& session, const std::string& csrf,
                                     int* status_out) {
    auto fail = [&](const std::string& code, int status) { return configImportFailure(code, status, status_out); };
    expireConfigImport();
    if (!started || !config) return fail("not_started", 503);
    const auto expected_csrf = sessions.csrfToken(session, clock->monoMs());
    if (csrf.empty() || expected_csrf.empty() || !constantTimeEquals(csrf, expected_csrf))
      return fail("permission_denied", 403);
    if (request_json.size() > kConfigImportBytes) return fail("capacity_exceeded", 413);
    auto request = configImportParse(request_json);
    if (!request) return fail("invalid_request", 400);
    const auto* schema = json::get(request.get(), "schema_version");
    if (!cJSON_IsNumber(schema) || schema->valuedouble != 2) return fail("unsupported_schema", 400);
    const auto principal = adminCredentialVersionOnLoop();
    const auto session_id = sha256Hex(toBytes(session));
    if (action == "stage") {
      if (!configImportFields(request.get(), {"schema_version", "expected_revision", "document"}))
        return fail("invalid_request", 400);
      const auto expected = json::getString(request.get(), "expected_revision");
      if (expected.empty() || expected.size() > 256) return fail("revision_required", 400);
      if (expected != configurationRevisionOnLoop()) return fail("config_conflict", 409);
      if (!import_stage.token.empty()) return fail("stage_capacity_exceeded", 429);
      const auto* document = json::get(request.get(), "document");
      if (!configImportFields(document, {"schema_version", "config"})) return fail("invalid_document", 400);
      const auto* target_schema = json::get(document, "schema_version");
      if (!cJSON_IsNumber(target_schema) || target_schema->valuedouble != 2) return fail("unsupported_schema", 400);
      const auto* input = json::get(document, "config"); size_t nodes = 0;
      if (!cJSON_IsObject(input) || !configImportTreeValid(input, 0, &nodes)) return fail("invalid_document", 400);
      const cJSON* member = nullptr;
      cJSON_ArrayForEach(member, input) {
        const std::string key = member->string;
        if (key.find('.') != std::string::npos || configEditReserved(key)) return fail("reserved_config_key", 400);
      }
      const auto* incoming_admin = json::get(input, "admin");
      if (json::get(incoming_admin, "password_hash")) return fail("admin_read_only", 400);
      auto previous = json::parse(config->materializeJson());
      auto public_admin = json::Doc(cJSON_Duplicate(json::get(previous.get(), "admin"), 1));
      if (public_admin) cJSON_DeleteItemFromObjectCaseSensitive(public_admin.get(), "password_hash");
      if (incoming_admin && (!public_admin || !cJSON_Compare(incoming_admin, public_admin.get(), 1)))
        return fail("admin_read_only", 400);
      json::Doc candidate(cJSON_Duplicate(input, 1));
      const auto* admin = json::get(previous.get(), "admin");
      if (admin) json::setItem(candidate.get(), "admin", json::Doc(cJSON_Duplicate(admin, 1)));
      import_stage = {genTokenHex(16), sha256Hex(toBytes(request_json)), principal,
          session_id, snapshot_epoch, expected, json::dump(candidate.get()), clock->monoMs()};
      const std::weak_ptr<char> weak = alive;
      import_stage_timer = loop->postDelayed(kConfigImportTtlMs, [this, weak] {
        if (weak.expired()) return;
        import_stage_timer = 0; expireConfigImport();
      });
      auto result = json::obj(); json::setBool(result.get(), "ok", true);
      json::set(result.get(), "schema_version", int64_t{2});
      json::set(result.get(), "stage_token", import_stage.token); json::set(result.get(), "digest", import_stage.digest);
      json::set(result.get(), "expected_revision", expected); json::set(result.get(), "expires_in_ms", kConfigImportTtlMs);
      if (status_out) *status_out = 200;
      return json::dump(result.get());
    }
    if (action != "preflight" && action != "commit" && action != "cancel" && action != "query")
      return fail("invalid_action", 400);
    auto fields = std::set<std::string>{"schema_version", "stage_token", "digest"};
    if (action == "commit" || action == "query") fields.insert("operation_id");
    if (!configImportFields(request.get(), fields)) return fail("invalid_request", 400);
    const auto token = json::getString(request.get(), "stage_token"), digest = json::getString(request.get(), "digest");
    if (!configImportHex(token, 32) || !configImportHex(digest, 64)) return fail("invalid_request", 400);
    const auto operation = json::getString(request.get(), "operation_id");
    json::Doc receipts;
    if (action == "commit" || action == "query") {
      if (!configImportHex(operation, 32)) return fail("invalid_operation_id", 400);
      receipts = configImportReceiptLedger();
      if (!receipts) return fail("receipt_store_invalid", 503);
      const auto* receipt = json::get(receipts.get(), operation.c_str());
      if (receipt) {
        if (json::getString(receipt, "principal") != principal || json::getString(receipt, "digest") != digest ||
            json::getString(receipt, "token_digest") != sha256Hex(toBytes(token)))
          return fail("operation_conflict", 409);
        if (status_out) *status_out = 200;
        if (action == "query") {
          auto result = json::obj(); json::setBool(result.get(), "ok", true);
          json::set(result.get(), "schema_version", int64_t{2}); json::set(result.get(), "state", "committed");
          json::setItem(result.get(), "result", json::Doc(cJSON_Duplicate(json::get(receipt, "result"), 1)));
          return json::dump(result.get());
        }
        return json::dump(json::get(receipt, "result"));
      }
      if (action == "query") return fail("operation_not_found", 404);
    }
    if (import_stage.token.empty() || import_stage.token != token) return fail("stage_expired", 410);
    if (import_stage.principal != principal || import_stage.session != session_id) return fail("permission_denied", 403);
    if (import_stage.digest != digest) return fail("stage_mismatch", 409);
    if (action == "cancel") {
      clearConfigImport(); if (status_out) *status_out = 200;
      return "{\"ok\":true,\"schema_version\":2}";
    }
    if (import_stage.revision != configurationRevisionOnLoop()) return fail("config_conflict", 409);
    std::vector<LwwMutation> mutations, journal; json::Doc report;
    const auto error = configImportPrepare(&mutations, &journal, &report);
    if (action == "preflight") {
      if (status_out) *status_out = 200;
      return json::dump(report.get());
    }
    if (cJSON_GetArraySize(receipts.get()) >= 128) return fail("receipt_capacity_exceeded", 429);
    if (!error.empty()) return fail(error, 422);
    auto receipt = json::obj();
    json::set(receipt.get(), "principal", principal); json::set(receipt.get(), "digest", digest);
    json::set(receipt.get(), "token_digest", sha256Hex(toBytes(token)));
    auto result = json::obj(); json::setBool(result.get(), "ok", true);
    json::set(result.get(), "schema_version", int64_t{2}); json::set(result.get(), "operation_id", operation);
    json::set(result.get(), "digest", digest); json::set(result.get(), "atomicity", "local_persistence");
    json::set(result.get(), "n", json::getInt(report.get(), "expanded_leaf_mutations"));
    json::setItem(receipt.get(), "result", std::move(result));
    json::setItem(receipts.get(), operation.c_str(), std::move(receipt));
    pending_import_receipts = json::dump(receipts.get()); pending_import_operation = operation;
    bool committed = store.configWriteTransaction([&] {
      if (import_stage.revision != configurationRevisionOnLoop()) return false;
      if (mutations.empty()) return store.configPutBatchWithMeta({}, configImportReceiptMetadata());
      mutations.insert(mutations.end(), journal.begin(), journal.end());
      config->mutate(mutations); return config->lastMutationCommitted();
    });
    pending_import_receipts.clear(); pending_import_operation.clear();
    if (!committed) return fail("config_persistence_failed", 500);
    clearConfigImport();
    receipts = configImportReceiptLedger();
    if (!receipts) return fail("receipt_store_invalid", 503);
    if (status_out) *status_out = 200;
    return json::dump(json::get(json::get(receipts.get(), operation.c_str()), "result"));
  }

  std::vector<std::pair<std::string, std::string>> configImportReceiptMetadata() {
    if (pending_import_operation.empty()) return {};
    auto receipts = json::parse(pending_import_receipts);
    auto* result = json::get(json::get(receipts.get(), pending_import_operation.c_str()), "result");
    json::set(result, "committed_revision", configurationRevisionOnLoop());
    return {{"config_import_receipts_v1", json::dump(receipts.get())}};
  }
