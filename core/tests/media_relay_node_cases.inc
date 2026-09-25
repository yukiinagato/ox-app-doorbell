// Included after the existing media publishing test so the production HTTP/JPEG helpers are reused.
// This is a real TCP/Node test, not an HTTPS/browser or physical-device qualification.
TEST_CASE("T16 real two-node HTTP to authenticated Mesh return-frame relay") {
  NodeOptions source_options, target_options;
  source_options.data_dir = target_options.data_dir = ":memory:";
  source_options.role = "indoor_panel"; target_options.role = "door_station";
  target_options.door = "front";
  source_options.enable_beacon = target_options.enable_beacon = false;
  source_options.psk.fill(0x39); target_options.psk.fill(0x39);
  source_options.listen_addr = "127.0.0.1:" + std::to_string(db::testing::freeListenPort());
  target_options.listen_addr = "127.0.0.1:" + std::to_string(db::testing::freeListenPort());
  source_options.advertise_addr = source_options.listen_addr;
  target_options.advertise_addr = target_options.listen_addr;
  target_options.seed_peers = {source_options.listen_addr};
  source_options.http_port = db::testing::freeListenPort();
  target_options.http_port = db::testing::freeListenPort();
  Node source(source_options), target(target_options);
  source.setSecureStore([](const std::string& key) {
    return key == "media.test" ? std::string("media-test-credential") : std::string();
  }, [](const std::string&, const std::string&) { return true; });
  // B cannot bootstrap the browser's credential; it must verify the public delegated principal.
  target.setSecureStore([](const std::string&) { return std::string(); },
                        [](const std::string&, const std::string&) { return true; });
  REQUIRE(source.start()); REQUIRE(target.start());
  const std::string panel_id(32, 'c');
  const std::string identity_record =
      R"({"credential_ref":"secret:media.test","credential_generation":"dddddddddddddddddddddddddddddddd","revoked":false,"door_scope":["front"],"grants":["view","call.answer","media.publish"]})";
  for (Node* node : {&source, &target}) {
    const std::pair<std::string, std::string> entries[] = {
      {"doors.front", R"({"label":{"en":"Front"}})"},
      {"devices." + source.nodeId() + ".role", "\"indoor_panel\""},
      {"devices." + target.nodeId() + ".role", "\"door_station\""},
      {"devices." + target.nodeId() + ".door", "\"front\""},
      {"panel.identities." + panel_id, identity_record}
    };
    for (const auto& entry : entries) {
      const auto result_text = node->setConfigJson(entry.first, entry.second);
      INFO(entry.first << ": " << result_text);
      const auto result = json::parse(result_text);
      REQUIRE(json::getBool(result.get(), "ok"));
    }
  }
  const auto wait_until = [](const std::function<bool()>& predicate, int milliseconds) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(milliseconds);
    do {
      if (predicate()) return true;
      std::this_thread::sleep_for(std::chrono::milliseconds(20));
    } while (std::chrono::steady_clock::now() < deadline);
    return predicate();
  };
  const auto owner = loginMediaSession(source_options.http_port);
  const auto stranger = loginMediaSession(source_options.http_port);
  const auto session = mediaRequest(source_options.http_port, "GET", "/api/panel/session", "", owner);
  REQUIRE(session.status == 200);
  const auto session_json = json::parse(session.body);
  REQUIRE(json::getString(session_json.get(), "panel_id") == panel_id);
  const auto call = target.pressV2("front", ""); REQUIRE(!call.empty());
  REQUIRE(wait_until([&] { return source.statusJson().find(call) != std::string::npos; }, 15000));
  const auto answered = mediaRequest(source_options.http_port, "POST", "/api/panel/call-lifecycle",
      mediaIdentity(call) + "&state=answered&dialog_id=0123456789abcdef0123456789abcdef", owner,
      "application/x-www-form-urlencoded");
  INFO(answered.body); REQUIRE(answered.status == 200);
  const auto answer_json = json::parse(answered.body);
  const auto dialog_owner = json::getString(answer_json.get(), "dialog_owner");
  REQUIRE(!dialog_owner.empty());
  REQUIRE(wait_until([&] {
    const auto status = target.statusJson();
    return status.find(call) != std::string::npos && status.find(dialog_owner) != std::string::npos;
  }, 4000));
  const auto authorized = mediaRequest(source_options.http_port, "POST", "/api/panel/media-authorize",
      mediaIdentity(call), owner, "application/x-www-form-urlencoded");
  INFO(authorized.body); REQUIRE(authorized.status == 200);
  const auto authority = json::parse(authorized.body);
  const auto generation = json::getString(authority.get(), "media_generation");
  REQUIRE(generation.size() == 32);
  CHECK(json::getString(authority.get(), "upload_path") == "/call-frame");
  CHECK(json::getInt(authority.get(), "publish_remaining_ms") <= 7500);
  CHECK(authorized.headers.count("Access-Control-Allow-Origin") == 0);
  const auto upload = "/call-frame?" + mediaIdentity(call) + "&media_generation=" + generation + "&frame_sequence=";
  const auto read = "/peer-frame.jpg?" + mediaIdentity(call);
  const auto jpeg = testJpeg(); REQUIRE(jpeg.size() > 100);
  CHECK(mediaRequest(source_options.http_port, "POST", upload + "1", jpeg, stranger, "image/jpeg").status == 403);
  const auto sent = mediaRequest(source_options.http_port, "POST", upload + "1", jpeg, owner, "image/jpeg");
  INFO(sent.body); REQUIRE(sent.status == 200);
  const auto accepted = json::parse(sent.body);
  CHECK(json::getString(accepted.get(), "acceptance") == "remote_core_accepted");
  const auto received = mediaRequest(target_options.http_port, "GET", read);
  CHECK(received.status == 200); CHECK(received.body == jpeg);
  CHECK(received.headers.at("X-Doorbell-Media-Generation") == generation);
  CHECK(mediaRequest(source_options.http_port, "POST", upload + "1", jpeg, owner, "image/jpeg").status == 409);
  const auto end = mediaRequest(source_options.http_port, "POST", "/api/panel/call-lifecycle",
      mediaIdentity(call) + "&state=ended&dialog_id=0123456789abcdef0123456789abcdef", owner,
      "application/x-www-form-urlencoded");
  REQUIRE(end.status == 200);
  CHECK(mediaRequest(source_options.http_port, "POST", upload + "2", jpeg, owner, "image/jpeg").status == 409);
  REQUIRE(wait_until([&] { return mediaRequest(target_options.http_port, "GET", read).status == 404; }, 3000));
  source.stop(); target.stop();
}
