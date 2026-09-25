  SUBCASE("T16 fixed identity forbids proxy targets duplicate keys and mixed inputs") {
    for (const auto* extra : {"&url=https://example.invalid/", "&host=localhost", "&port=80",
                             "&path=/admin", "&door=other", "&%64oor=other"}) {
      CHECK(mediaRequest(port, "POST", "/api/panel/media-authorize", mediaIdentity(call_a) + extra,
          owner, "application/x-www-form-urlencoded").status == 400);
      CHECK(mediaRequest(port, "POST", upload + "1" + extra, jpeg, owner, "image/jpeg").status == 400);
    }
    CHECK(mediaRequest(port, "POST", "/api/panel/media-authorize?" + mediaIdentity(call_a),
        mediaIdentity(call_a), owner, "application/x-www-form-urlencoded").status == 400);
    CHECK(mediaRequest(port, "POST", "/api/panel/media-authorize", mediaIdentity(call_a),
        owner, "application/json").status == 400);
    const auto renewed = mediaRequest(port, "POST", "/api/panel/media-authorize", mediaIdentity(call_a),
        owner, "application/x-www-form-urlencoded;charset=UTF-8");
    REQUIRE(renewed.status == 200);
    const auto body = json::parse(renewed.body);
    CHECK(json::getString(body.get(), "upload_path") == "/call-frame");
    CHECK(renewed.headers.count("Access-Control-Allow-Origin") == 0);
  }
  SUBCASE("T16 malformed JPEG never replaces a valid peer slot") {
    REQUIRE(mediaRequest(port, "POST", upload + "1", jpeg, owner, "image/jpeg").status == 200);
    auto damaged = jpeg; damaged.resize(damaged.size() - 2);
    CHECK(mediaRequest(port, "POST", upload + "2", damaged, owner, "image/jpeg").status == 400);
    CHECK(mediaRequest(port, "POST", upload + "3", jpeg + "trailing bytes", owner, "image/jpeg").status == 400);
    CHECK(mediaRequest(port, "POST", upload + "4", "not an image", owner, "image/jpeg").status == 400);
    const auto current = mediaRequest(port, "GET", read);
    CHECK(current.body == jpeg);
    CHECK(current.headers.at("X-Doorbell-Frame-Sequence") == "1");
  }
  SUBCASE("T16 same-value secret write revokes publisher session grant and cached frame") {
    REQUIRE(mediaRequest(port, "POST", upload + "1", jpeg, owner, "image/jpeg").status == 200);
    REQUIRE(mediaRequest(port, "GET", read).body == jpeg);
    const auto login = mediaRequest(port, "POST", "/api/login", R"({"password":"testpw"})");
    REQUIRE(login.status == 200);
    const auto cookie = login.headers.find("Set-Cookie");
    REQUIRE(cookie != login.headers.end());
    const auto body = json::parse(login.body);
    MediaSession admin;
    admin.cookie = cookie->second.substr(0, cookie->second.find(';'));
    admin.csrf = json::getString(body.get(), "csrf_token");
    const auto rewrite = mediaRequest(port, "POST", "/api/secrets",
        R"({"secret_ref":"secret:media.test","value":"media-test-credential"})", admin);
    INFO(rewrite.body);
    REQUIRE(rewrite.status == 200);
    CHECK(mediaRequest(port, "GET", "/api/panel/session", "", owner).status == 403);
    CHECK(mediaRequest(port, "POST", upload + "2", jpeg, owner, "image/jpeg").status == 403);
    CHECK(mediaRequest(port, "GET", read).status == 404);
    const auto fresh = loginMediaSession(port);
    CHECK(mediaRequest(port, "GET", "/api/panel/session", "", fresh).status == 200);
    // Re-authentication does not make a new session the old call's publisher.
    CHECK(mediaRequest(port, "POST", "/api/panel/media-authorize", mediaIdentity(call_a),
        fresh, "application/x-www-form-urlencoded").status == 403);
  }
  SUBCASE("T16 unrelated secret write preserves publisher session grant and cached frame") {
    REQUIRE(mediaRequest(port, "POST", upload + "1", jpeg, owner, "image/jpeg").status == 200);
    const auto login = mediaRequest(port, "POST", "/api/login", R"({"password":"testpw"})");
    REQUIRE(login.status == 200);
    const auto cookie = login.headers.find("Set-Cookie");
    REQUIRE(cookie != login.headers.end());
    const auto body = json::parse(login.body);
    MediaSession admin;
    admin.cookie = cookie->second.substr(0, cookie->second.find(';'));
    admin.csrf = json::getString(body.get(), "csrf_token");
    const auto rewrite = mediaRequest(port, "POST", "/api/secrets",
        R"({"secret_ref":"secret:unrelated.test","value":"unrelated-value"})", admin);
    INFO(rewrite.body);
    REQUIRE(rewrite.status == 200);
    CHECK(mediaRequest(port, "GET", "/api/panel/session", "", owner).status == 200);
    CHECK(mediaRequest(port, "GET", read).body == jpeg);
    CHECK(mediaRequest(port, "POST", upload + "2", jpeg, owner, "image/jpeg").status == 200);
  }
