
// Process-level composition root for storage, replicated config/events, mesh, rules, HTTP, SIP,
// and media. Public methods may be called from any thread and marshal mutable state to Runloop.
#pragma once

#include <array>
#include <functional>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "crdt/lww_map.h"
#include "events/events.h"
#include "httpd/httpd.h"
#include "mesh/mesh.h"
#include "store/store.h"
#include "util/clock.h"
#include "util/hlc.h"
#include "util/runloop.h"

namespace db {

struct NodeOptions {
  std::string data_dir;
  std::string name = "doorbell";
  std::string role = "door_station";  // door_station | indoor_panel
  std::string door;
  std::string listen_addr = "0.0.0.0:47172";
  std::string advertise_addr;
  std::vector<std::string> seed_peers;
  std::array<uint8_t, 32> psk{};
  bool enable_beacon = true;
  std::string caps_json = "{}";
  bool has_https = true;             // hard clamp for tls12 capability
  std::string sw_version = "0.1.0";
  std::string model = "unknown";     // Hardware model shown on a pairing device card.
  std::string platform = "unknown";  // Platform shown on a pairing device card.
  // Where the configured PSK came from: "secure_store" (secret reference), "boot_plaintext"
  // (psk_hex in boot.json), or "none". Reported as pairing.psk_source.
  std::string psk_source = "none";
  std::string psk_ref;               // "secret:<name>" when the PSK was read from secure storage.
  int http_port = 0;
  bool seed_default_config = true;

  std::string sip_user;
  std::string sip_pass;
  bool sip_null_audio = false;

  MeshSettings mesh_timing_template{};
  bool use_mesh_timing_template = false;
};


struct NodeDeps {
  IClock* clock = nullptr;                 // Borrowed when supplied.
  Runloop* loop = nullptr;                 // Borrowed; Node does not start or stop it.
  std::unique_ptr<ITransport> transport;   // Owned by Node.
  std::unique_ptr<IDiscovery> discovery;   // Owned by Node and may be null.
};



std::string sanitizeCaps(const std::string& caps_json, bool has_https);

class Node {
 public:

  using UiEventCb = std::function<void(const std::string& event_json)>;
  using TtsCb = std::function<void(const std::string& text, const std::string& lang)>;




  // HTTPS implementations return immediately and may invoke done on any thread.
  using HttpsFn = std::function<void(
      const std::string& method, const std::string& url, const std::string& headers_json,
      const Bytes& body, std::function<void(int status, std::string resp_body)> done)>;

  Node(NodeOptions opts, NodeDeps deps = {});
  ~Node();

  bool start();
  void stop();

  void setUiEventCb(UiEventCb cb);
  void setTtsCb(TtsCb cb);

  void setHttpsFn(HttpsFn fn);


  // Device information may block briefly and is called from the reachability worker.
  using DeviceInfoFn = std::function<std::string()>;
  void setDeviceInfoFn(DeviceInfoFn fn);
  using SecureGetFn = std::function<std::string(const std::string& key)>;
  using SecurePutFn = std::function<bool(const std::string& key, const std::string& value)>;
  // Deleting a secret is optional; a platform without it simply keeps the stale entry.
  using SecureDeleteFn = std::function<bool(const std::string& key)>;
  void setSecureStore(SecureGetFn get, SecurePutFn put);
  void setSecureDelete(SecureDeleteFn del);
  // Battery and power state, polled on the one-minute housekeeping tick. The callback returns
  // {"battery_pct":<-1..100>,"charging":bool,"mains":bool}; an empty string means "unknown this
  // time" and leaves the previous reading in place. A platform without a battery reports -1.
  using PowerStateFn = std::function<std::string()>;
  void setPowerStateFn(PowerStateFn fn);
  void setRuntimeCapabilities(const std::string& capabilities_json);
  void setRuntimeStatus(const std::string& runtime_json);
  void setUiManifest(const std::string& manifest_json);
  std::string capabilitiesJson();

  // Legacy wrappers use the most recent active call for the door.
  void press(const std::string& door_id, const std::string& purpose = "");
  void selectPurpose(const std::string& door_id, const std::string& purpose);
  void cancelCall(const std::string& door_id);
  // Versioned call flow. A 128-bit call_id scopes every update and cancellation.
  std::string pressV2(const std::string& door_id, const std::string& purpose = "");
  bool selectPurposeV2(const std::string& door_id, const std::string& call_id,
                       const std::string& purpose);
  bool cancelCallV2(const std::string& door_id, const std::string& call_id,
                    const std::string& reason = "visitor");
  bool reportCallAnsweredV2(const std::string& door_id, const std::string& call_id,
                            int stage_revision);
  bool reportCallEndedV2(const std::string& door_id, const std::string& call_id,
                         int stage_revision, const std::string& reason = "sip_ended");
  void reportCallRecovery(const std::string& call_id, bool restored);




  // Deliver a configured reply; free_text takes precedence over reply_id.
  void sendQuickReply(const std::string& reply_id, const std::string& free_text,
                      const std::string& door_id, const std::string& via);
  bool sendQuickReplyV2(const std::string& reply_id, const std::string& free_text,
                        const std::string& door_id, const std::string& call_id,
                        int stage_revision);





  // Replicate a visitor-language change. Empty door selects the local assigned door.
  void setVisitorLang(const std::string& door_id, const std::string& lang);



  // Persist a validated shared asset and return its content hash, or empty on failure.
  std::string addAsset(const Bytes& data, const std::string& type, const std::string& label);

  std::string assetPath(const std::string& hash);







  // Resolve core-owned text through config overrides, built-ins, then the key itself.
  using TextArgs = std::vector<std::pair<std::string, std::string>>;
  std::string text(const std::string& key, const std::string& lang,
                   const TextArgs& args = {}) const;




  // Replicate SOS state. The caller owns authorization for clearing it.
  void setEmergency(bool active, const std::string& via);
  bool setEmergencyV2(bool active, const std::string& via);




  // SIP mode is bidirectional by default; "monitor" is one-way and "answer" takes over ringing.
  void sipCall(const std::string& target, const std::string& mode = "");
  void sipHangup();
  bool sipSendDtmf(const std::string& digits);
  // Microphone mute for the talk control. Remembered across calls and reported as
  // status.call.mic_muted, including on builds without a SIP backend.
  void setSipMicMuted(bool muted);
  bool sipMicMuted();

  // One administrator password for the whole cluster, stored as a salted digest in replicated
  // configuration. verify returns 1 accepted, 0 wrong, -2 locked out, -3 not set yet; the
  // lockout counter is shared with the web login. set returns 0 changed, -1 bad arguments,
  // -2 current password wrong, -3 locked out, -4 not persisted; current is ignored, and may be
  // empty, when no password has been set.
  int verifyAdminPassword(const std::string& password);
  int setAdminPassword(const std::string& current, const std::string& next);



  // Copies the caller-owned camera buffer before returning.
  void pushCameraFrame(const uint8_t* data, int format, int width, int height, int stride,
                       int64_t ts_ms);



  // Accepts Annex-B access units from any thread and copies the caller-owned buffer.
  void pushEncodedFrame(const uint8_t* annexb, size_t len, bool key, int64_t ts_ms);



  // True only while H.264/auto has at least one stream subscriber.
  bool videoEncoderWanted();

  // Normalize door-station orientation to clockwise cardinal degrees for video metadata.
  // An explicit devices.<self>.local.video.rotation value takes precedence over the sensor.
  void setVideoSensorRotation(int degrees);

  std::string statusJson();
  std::string debugJson();
  std::string configJson();

  // Wall-clock rendering in the configured IANA zone. Pass 0 for "now". The result is
  // {"iso","date","hh","mm","ss","weekday","weekday_num","offset_min","dst","known","wall_ms",
  //  "tz"}.
  std::string localTimeJson(int64_t wall_ms);
  // Effective volumes for one device (empty means this node):
  // {"device","call","sos","idle","source","sources":{...}}.
  std::string audioJson(const std::string& device_id);
  // Start one immediate SNTP round. Returns false when NTP is disabled or the node is stopped.
  bool syncTimeNow();
  // Replicated per-door announcement. expires_ms is an absolute wall-clock deadline; 0 means
  // "until cleared". Returns false for an unknown door, invalid text, or a persistence failure.
  // door may be "*" for the cluster-wide announcement a door-specific one overrides.
  bool setDoorNotice(const std::string& door, const std::string& text, int64_t expires_ms);
  bool clearDoorNotice(const std::string& door);
  // Trigger the configured unlock action for one door. False when the door is unknown or no
  // unlock action is configured anywhere, so the caller can explain rather than no-op silently.
  bool openDoor(const std::string& door);

  // Configuration writes with the same validation and result shape the HTTP endpoints use, so a
  // native shell does not have to talk to its own loopback HTTP server. The returned JSON is
  // {"ok":true,...} or {"ok":false,"err":"..."} and carries the advisory "warnings" array.
  std::string setConfigJson(const std::string& key, const std::string& value_json);
  // The advisory warnings from the most recent single-key write, as a JSON array.
  std::string lastWriteWarningsJson();
  std::string configBatchJson(const std::string& ops_json);
  std::string deleteConfigKeyJson(const std::string& key);

  // Call history for the local device. since_ms is an inclusive lower bound on the row timestamp
  // and zero means "from the beginning"; limit is clamped to a bounded page. The result is
  // {"rows":[...],"unread_missed":N,"seen_hlc":"...","server_ts":...}.
  std::string callLogJson(int64_t since_ms, int limit);
  // Paging variant: before_ms is an exclusive upper bound on a row's timestamp, so a shell can
  // fetch older pages by passing the oldest timestamp it already has. Zero means no upper bound.
  std::string callLogJson(int64_t since_ms, int64_t before_ms, int limit);
  // Move the device-local seen watermark. An empty HLC marks every known call as seen. The
  // watermark never moves backwards and a call_log_changed event follows a successful write.
  bool markCallLogSeen(const std::string& up_to_hlc);


  std::string pairingJson();
  bool foundCluster();
  void joinCluster(const std::string& host, const std::string& pin);
  void setPairingMode(int seconds);
  // Open the bulk-add window and mint a PIN. Only the explicit "add several devices" button.
  std::string startPairingJson(int seconds);
  // Mint or refresh the join PIN without opening the bulk-add window. seconds of zero keeps the
  // default PIN lifetime.
  std::string mintJoinTokenJson(int seconds);
  void removeDevice(const std::string& node_id);
  void inviteDevice(const std::string& id);

  void inviteDeviceDirect(const std::string& addr, const std::string& id, const std::string& pk);
  // Ignore one pending device for a while and drop it from the pending list.
  void denyDevice(const std::string& id);
  // Re-run the secure-store write after a persistence failure. Returns true once the PSK is
  // stored; the resulting pairing_state event is emitted either way.
  bool retryPairingPersistence();
  // Leave the cluster and wipe the local pairing secret.
  void unpair();
  // Invite from a scanned or pasted "doorbell-pair:<addr>|<id>|<pk>" payload.
  bool inviteFromQrText(const std::string& text);
  // Decode QR codes from the existing camera-frame pipeline until stopped or the 120 s deadline.
  void startQrScan();
  void stopQrScan();

  void setConfigKey(const std::string& key, const std::string& value_json);
  const std::string& nodeId() const { return node_id_; }
  Runloop& loop();

  struct Impl;

 private:
  std::string node_id_;
  std::unique_ptr<Impl> impl_;
};

}  // namespace db
