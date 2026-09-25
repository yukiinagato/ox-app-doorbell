  struct MediaAuthorization {
    std::string door, call_id, owner, session, generation;
    int stage_revision = -1;
    int64_t deadline_mono = 0;
    uint64_t last_sequence = 0;
    // session exists only on the current browser-origin node and is never serialized.
    std::string source_node, target_node, authorization_request;
    PanelPrincipal principal;
    uint64_t peer_epoch = 0;
    uint64_t highest_submitted = 0;
    int64_t issued_mono = 0;
    int64_t ttl_ms = 0;
  };
