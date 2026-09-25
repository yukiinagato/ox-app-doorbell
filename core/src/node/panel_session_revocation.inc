// Included inside Node::Impl after media_relay_service.inc. Runs only on Core's loop.
  void revokePanelSessionsForSecretRef(const std::string& ref) {
    // A successful provisioning write is a revocation event even for an identical value.
    // Scope it to the saved binding, not the currently configured fleet-wide reference list.
    std::set<std::string> revoked;
    {
      std::lock_guard<std::mutex> lock(sess_mu);
      for (auto it = panel_sessions.begin(); it != panel_sessions.end();) {
        const auto& refs = it->second.credential.refs;
        if (std::find(refs.begin(), refs.end(), ref) == refs.end()) {
          ++it;
          continue;
        }
        revoked.insert(it->first);
        it = panel_sessions.erase(it);
      }
    }

    // Do not hold sess_mu while pruning: the media binding checks acquire it themselves.
    // Existing pruning clears cached frames, both queue slots and in-flight frame RPCs.
    invalidatePanelSessions();

    // An authorization RPC has no installed generation yet, so generation pruning alone
    // cannot remove it. Remove correlation before completing to make late replies inert.
    std::vector<MediaWorkPtr> cancelled;
    for (auto it = media_rpcs.begin(); it != media_rpcs.end();) {
      const auto& authority = it->second->authority;
      if (authority.source_node != node_id || !revoked.count(authority.session)) {
        ++it;
        continue;
      }
      cancelled.push_back(it->second);
      it = media_rpcs.erase(it);
    }
    for (const auto& work : cancelled) {
      mediaSendRevoke(work->authority);
      mediaComplete(work, mediaFailure(403, "permission_denied"));
    }
  }
