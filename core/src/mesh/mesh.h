
// Self-healing authenticated mesh. It combines discovery, encrypted transport, membership,
// deterministic leader leases, replicated config/event anti-entropy, and PIN-based pairing.
// All methods and callbacks run on Runloop. Snapshot responses are capped at 300 KiB and shared
// asset responses at 3 MiB; callers verify asset hashes before persistence.
#pragma once

#include <array>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "crdt/lww_map.h"
#include "events/events.h"
#include "mesh/transport.h"
#include "util/clock.h"
#include "util/hlc.h"
#include "util/runloop.h"

namespace db {

class Store;

struct MeshSettings {
  std::string node_id;         // 32 hex
  uint64_t epoch = 1;
  std::string listen_addr;
  std::string advertise_addr;
  std::vector<std::string> advertise_addrs;  // All interface candidates; primary comes first.
  std::vector<std::string> seed_peers;
  std::array<uint8_t, 32> psk{};  // An all-zero key means the node is unpaired.
  std::string psk_id = "k1";
  std::string role = "door_station";  // door_station | indoor_panel
  std::string door;                  // Operational door identity; empty for indoor panels.
  std::string sw_version = "0.0.1";
  std::string model = "unknown";     // Device-card hardware model announced while unpaired.
  std::string platform = "unknown";  // Device-card platform announced while unpaired.
  std::string caps_json = "{}";  // {"tls12":bool,"wan":bool,"mains_power":bool,
                                 //  "mqtt_reachable":bool,"wall_clock_sane":bool,"cpu_score":int}
  std::string ui_manifest_json = "{}";
  std::string runtime_json = "{}";  // Bounded, allowlisted peer-visible runtime projection.

  // Timing is configurable for deterministic tests.
  int64_t heartbeat_ms = 3000;
  int64_t suspect_ms = 9000;
  int64_t dead_ms = 15000;
  int64_t gossip_ms = 10000;
  int64_t sync_ms = 10000;
  int64_t claim_ttl_ms = 30000;   // leader lease
  int64_t reconnect_ms = 5000;
  int max_neighbors = 4;
};

struct PeerInfo {
  std::string id;
  std::vector<std::string> addrs;
  uint64_t epoch = 0;
  uint64_t hb_seq = 0;
  std::string hb_hlc;
  std::string status;          // alive | suspect | dead
  std::string caps_json;
  std::string role;
  std::string door;
  std::string sw_version;
  std::string ui_manifest_json;
  std::string runtime_json = "{}";
  int64_t last_seen_mono = 0;
  bool connected = false;
};

// Projects platform runtime into a bounded peer-visible contract. Recovery/component health,
// per-channel alert outcomes, and semantic UI results are allowlisted; device identity,
// fingerprints, paths, arbitrary errors, credentials, and unknown sections are discarded.
bool projectMeshRuntimeJson(const std::string& runtime_json, std::string* projected_json);

// duty: "telegram" | "mqtt_bridge" | "web_push"
class Mesh {
 public:
  struct Callbacks {
    std::function<void()> on_peers_changed;

    std::function<void(const std::string&, const std::string&)> on_leader_changed;

    std::function<void(const std::string& node_id, bool alive)> on_peer_alive_changed;

    std::function<void(const EventRecord&)> on_event;

    std::function<void(const std::string& from, const std::string& cmd_json)> on_command;

    std::function<void()> on_pending_changed;

    std::function<void()> on_paired;

    // Result of one manual invitation: ok after the invitee acknowledges the join frame,
    // otherwise err is "no_ack" or a transport reason.
    std::function<void(const std::string& id, bool ok, const std::string& err)> on_invite_result;

    // A formerly pending device finished its secure handshake and is now a cluster member.
    std::function<void(const std::string& id, const std::string& name, const std::string& role)>
        on_device_joined;

    std::function<void(bool active, int64_t left_s, int auto_added_count)> on_pairing_mode_changed;

    std::function<void(bool active, int64_t expires_s, int attempts_left)> on_join_token_changed;

    // The local (unpaired) node refused an invitation; reason is a stable error code.
    std::function<void(const std::string& reason)> on_invite_rejected;

    std::function<void()> on_unpaired;
  };

  Mesh(Runloop& loop, IClock& clock, HlcClock& hlc, ITransport& transport,
       IDiscovery* discovery /*nullable*/, Store& store, LwwMap& config, EventLog& events,
       MeshSettings settings, Callbacks cbs);
  ~Mesh();

  void start();
  void stop();


  std::vector<PeerInfo> peers() const;  // Includes the local node.
  std::string leaderFor(const std::string& duty) const;  // Empty without an eligible leader.
  bool isLeader(const std::string& duty) const;
  void setCaps(const std::string& caps_json);
  void setUiManifest(const std::string& manifest_json);
  void setRuntime(const std::string& runtime_json);



  // Push local changes immediately instead of waiting for anti-entropy.
  void broadcastEvent(const EventRecord& ev);

  void pushConfigDelta(const std::vector<LwwEntry>& entries);
  void sendCommand(const std::string& node_id, const std::string& cmd_json);
  void broadcastCommand(const std::string& cmd_json);




  // Snapshot callbacks receive empty bytes when unavailable, oversized, or timed out.
  void setSnapshotProvider(std::function<Bytes()> provider);


  void fetchSnapshot(const std::string& node_id, std::function<void(Bytes jpeg)> cb);




  // Blob retrieval checks local storage first and then connected peers in order.
  void setBlobProvider(std::function<Bytes(const std::string& hash)> provider);




  void fetchBlob(const std::string& hash, std::function<void(Bytes data)> cb);


  struct JoinToken {
    std::string pin;
    int64_t expires_mono = 0;
  };
  JoinToken createJoinToken();


  // Valid only while unpaired; applies PSK, seeds, and config before completion.
  void joinCluster(const std::string& host_addr, const std::string& pin,
                   std::function<void(bool ok, const std::string& err)> done);


  bool isPaired() const;
  bool foundCluster();  // Generates a new cluster key only while unpaired.
  // True when this node created the cluster rather than joining one. Node persists it in store
  // metadata so the badge survives a restart.
  bool isFounder() const;
  std::string pairingSelfJson();
  std::string pendingJson();
  // {"active":bool,"expires_s":int,"attempts_left":int,"host":"<addr>","pin":"<6>"}.
  // pin appears only while the token is active.
  std::string tokenJson();
  void inviteDevice(const std::string& id);

  void inviteDeviceDirect(const std::string& addr, const std::string& pk);
  // Drop one pending device and ignore its announcements for a short while.
  void denyDevice(const std::string& id);
  void setPairingMode(int64_t ttl_ms);
  // Leave the cluster: zero the PSK, drop cluster state, and start announcing for pairing again.
  void unpair();

  const MeshSettings& settings() const { return settings_; }


  struct Impl;

 private:
  MeshSettings settings_;
  std::unique_ptr<Impl> impl_;
};
// Deterministic in-memory transport and discovery used for partition and packet-loss tests.

class InMemNet {
 public:
  explicit InMemNet(Runloop& loop);
  ~InMemNet();

  std::unique_ptr<ITransport> makeTransport(const std::string& addr);
  std::unique_ptr<IDiscovery> makeDiscovery(const std::string& addr);


  void partition(const std::vector<std::vector<std::string>>& groups);
  void heal();
  void setDrop(double probability, uint32_t seed);
  void setDelayMs(int64_t delay_ms);
  void killNode(const std::string& addr);
  struct Impl;

 private:
  std::unique_ptr<Impl> impl_;
};

}  // namespace db
