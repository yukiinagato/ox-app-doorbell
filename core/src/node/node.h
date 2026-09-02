
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
  void setSecureStore(SecureGetFn get, SecurePutFn put);
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


  std::string pairingJson();
  bool foundCluster();
  void joinCluster(const std::string& host, const std::string& pin);
  void setPairingMode(int seconds);
  std::string startPairingJson(int seconds);
  void removeDevice(const std::string& node_id);
  void inviteDevice(const std::string& id);

  void inviteDeviceDirect(const std::string& addr, const std::string& id, const std::string& pk);

  void setConfigKey(const std::string& key, const std::string& value_json);
  const std::string& nodeId() const { return node_id_; }
  Runloop& loop();

  struct Impl;

 private:
  std::string node_id_;
  std::unique_ptr<Impl> impl_;
};

}  // namespace db
