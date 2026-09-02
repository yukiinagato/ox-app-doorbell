// JNI bridge between the public Core C ABI and DoorbellCore. Core invokes callbacks on
// its own threads; this layer attaches them to the JVM and Kotlin marshals UI work to main.
// A pthread TLS destructor detaches threads at exit to avoid per-callback attach churn.
#include <android/log.h>
#include <jni.h>
#include <pthread.h>

#include <cstdlib>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

#include "doorbell/doorbell.h"

// PJSIP pjlib C ABI. The JNI bridge is not part of the doorbell_core target, so it only
// declares the JVM registration entry point instead of depending on PJSIP include paths.
extern "C" void pj_jni_set_jvm(void* jvm);

#ifndef DB_ANDROID_REAL_PJSIP
#error "Android product APKs must link the real PJSIP backend"
#endif

#ifndef DB_ANDROID_PJSIP_TIER_NAME
#define DB_ANDROID_PJSIP_TIER_NAME "unknown"
#endif

namespace {

JavaVM* g_vm = nullptr;
pthread_key_t g_tls_key;
pthread_once_t g_tls_once = PTHREAD_ONCE_INIT;

void detachThread(void*) {
  if (g_vm) g_vm->DetachCurrentThread();
}

void makeTlsKey() { pthread_key_create(&g_tls_key, detachThread); }

// Attach a Core callback thread once and arrange for its eventual detachment.
JNIEnv* envForThisThread() {
  if (!g_vm) return nullptr;
  JNIEnv* env = nullptr;
  jint r = g_vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);
  if (r == JNI_OK) return env;
  if (r != JNI_EDETACHED) return nullptr;
  if (g_vm->AttachCurrentThread(&env, nullptr) != JNI_OK) return nullptr;
  pthread_once(&g_tls_once, makeTlsKey);
  pthread_setspecific(g_tls_key, env);
  return env;
}

// One bridge per DoorbellCore instance. The platform table outlives Core.
struct Bridge {
  db_core* core = nullptr;
  db_platform_v2 plat{};
  jobject obj = nullptr;          // DoorbellCore global reference
  jmethodID mid_ui_event = nullptr;   // onUiEventFromNative(String)
  jmethodID mid_tts = nullptr;        // onTtsFromNative(String, String)
  jmethodID mid_https = nullptr;
  jmethodID mid_secure_get = nullptr;
  jmethodID mid_secure_put = nullptr;
  jmethodID mid_device_info = nullptr;
  jclass cls_string = nullptr;        // java/lang/String (GlobalRef)
  jmethodID mid_string_ctor = nullptr;  // String(byte[], String charset)
  jmethodID mid_string_get_bytes = nullptr;
  jstring utf8 = nullptr;             // "UTF-8" (GlobalRef)
};

// NewStringUTF accepts modified UTF-8 and cannot safely decode four-byte emoji, so use
// String(byte[], "UTF-8") for visitor-facing reply text.
jstring toJString(JNIEnv* env, const Bridge* b, const char* utf8) {
  if (!utf8) utf8 = "";
  const jsize n = static_cast<jsize>(strlen(utf8));
  jbyteArray bytes = env->NewByteArray(n);
  if (!bytes) return nullptr;
  env->SetByteArrayRegion(bytes, 0, n, reinterpret_cast<const jbyte*>(utf8));
  jstring s = static_cast<jstring>(
      env->NewObject(b->cls_string, b->mid_string_ctor, bytes, b->utf8));
  env->DeleteLocalRef(bytes);
  return s;
}

// Convert Java input to UTF-8; identifiers are restricted to BMP-compatible text.
std::string toUtf8(JNIEnv* env, jstring s) {
  if (!s) return "";
  const char* p = env->GetStringUTFChars(s, nullptr);
  std::string out = p ? p : "";
  if (p) env->ReleaseStringUTFChars(s, p);
  return out;
}

bool clearJavaException(JNIEnv* env, const char* operation) {
  if (!env->ExceptionCheck()) return false;
  env->ExceptionClear();
  __android_log_print(ANDROID_LOG_ERROR, "doorbell-jni", "%s callback failed", operation);
  return true;
}

bool copyJavaString(JNIEnv* env, const Bridge* b, jstring value, char** out) {
  if (!value || !out) return false;
  auto* bytes = static_cast<jbyteArray>(
      env->CallObjectMethod(value, b->mid_string_get_bytes, b->utf8));
  if (clearJavaException(env, "String.getBytes") || !bytes) return false;
  const jsize size = env->GetArrayLength(bytes);
  char* copy = static_cast<char*>(std::malloc(static_cast<size_t>(size) + 1));
  if (!copy) {
    env->DeleteLocalRef(bytes);
    return false;
  }
  if (size > 0)
    env->GetByteArrayRegion(bytes, 0, size, reinterpret_cast<jbyte*>(copy));
  copy[size] = '\0';
  env->DeleteLocalRef(bytes);
  *out = copy;
  return true;
}

void callVoidChecked(JNIEnv* env, const Bridge* b, jmethodID mid, jstring a1, jstring a2) {
  if (a2)
    env->CallVoidMethod(b->obj, mid, a1, a2);
  else
    env->CallVoidMethod(b->obj, mid, a1);
  if (env->ExceptionCheck()) {
    env->ExceptionDescribe();
    env->ExceptionClear();
  }
}

// db_platform callbacks run on Core-owned threads.

void platLogLine(void* user, int level, const char* line) {
  (void)user;
  int prio = ANDROID_LOG_DEBUG;
  if (level == 1) prio = ANDROID_LOG_INFO;
  else if (level == 2) prio = ANDROID_LOG_WARN;
  else if (level >= 3) prio = ANDROID_LOG_ERROR;
  __android_log_print(prio, "doorbell-core", "%s", line ? line : "");
}

void platTtsSpeak(void* user, const char* text, const char* lang) {
  auto* b = static_cast<Bridge*>(user);
  JNIEnv* env = envForThisThread();
  if (!env || !b->obj) return;
  jstring jt = toJString(env, b, text);
  jstring jl = toJString(env, b, lang);
  callVoidChecked(env, b, b->mid_tts, jt, jl);
  if (jt) env->DeleteLocalRef(jt);
  if (jl) env->DeleteLocalRef(jl);
}

int platHttpsRequest(void* user, const char* method, const char* url,
                     const char* headers_json, const uint8_t* body, size_t body_len,
                     char** resp_body_out, int* http_status_out) {
  auto* b = static_cast<Bridge*>(user);
  if (!b || !resp_body_out || !http_status_out ||
      (body_len > 0 && !body) ||
      body_len > static_cast<size_t>(std::numeric_limits<jsize>::max())) return -1;
  *resp_body_out = nullptr;
  *http_status_out = 0;
  JNIEnv* env = envForThisThread();
  if (!env || !b->obj) return -1;
  jstring jm = toJString(env, b, method);
  jstring ju = toJString(env, b, url);
  jstring jh = toJString(env, b, headers_json);
  jbyteArray jb = env->NewByteArray(static_cast<jsize>(body_len));
  if (jb && body_len > 0)
    env->SetByteArrayRegion(jb, 0, static_cast<jsize>(body_len),
                            reinterpret_cast<const jbyte*>(body));
  auto* result = (jm && ju && jh && jb) ? static_cast<jbyteArray>(
      env->CallObjectMethod(b->obj, b->mid_https, jm, ju, jh, jb)) : nullptr;
  const bool exception = clearJavaException(env, "HTTPS");
  if (jm) env->DeleteLocalRef(jm);
  if (ju) env->DeleteLocalRef(ju);
  if (jh) env->DeleteLocalRef(jh);
  if (jb) env->DeleteLocalRef(jb);
  if (exception || !result) return -1;
  const jsize size = env->GetArrayLength(result);
  if (size < 4) {
    env->DeleteLocalRef(result);
    return -1;
  }
  jbyte status_bytes[4]{};
  env->GetByteArrayRegion(result, 0, 4, status_bytes);
  const int status = ((status_bytes[0] & 0xff) << 24) |
                     ((status_bytes[1] & 0xff) << 16) |
                     ((status_bytes[2] & 0xff) << 8) |
                     (status_bytes[3] & 0xff);
  const size_t payload_size = static_cast<size_t>(size - 4);
  char* payload = static_cast<char*>(std::malloc(payload_size + 1));
  if (!payload) {
    env->DeleteLocalRef(result);
    return -2;
  }
  if (payload_size > 0)
    env->GetByteArrayRegion(result, 4, size - 4, reinterpret_cast<jbyte*>(payload));
  payload[payload_size] = '\0';
  env->DeleteLocalRef(result);
  *resp_body_out = payload;
  *http_status_out = status;
  return 0;
}

int platSecureGet(void* user, const char* key, char** value_out) {
  auto* b = static_cast<Bridge*>(user);
  if (!b || !value_out) return -1;
  *value_out = nullptr;
  JNIEnv* env = envForThisThread();
  if (!env || !b->obj) return -1;
  jstring jk = toJString(env, b, key);
  auto* value = jk ? static_cast<jstring>(
      env->CallObjectMethod(b->obj, b->mid_secure_get, jk)) : nullptr;
  const bool exception = clearJavaException(env, "secure_get");
  if (jk) env->DeleteLocalRef(jk);
  if (exception || !value) return -1;
  const bool copied = copyJavaString(env, b, value, value_out);
  env->DeleteLocalRef(value);
  return copied ? 0 : -1;
}

int platSecurePut(void* user, const char* key, const char* value) {
  auto* b = static_cast<Bridge*>(user);
  JNIEnv* env = envForThisThread();
  if (!b || !env || !b->obj) return -1;
  jstring jk = toJString(env, b, key);
  jstring jv = toJString(env, b, value);
  const jboolean ok = (jk && jv) ?
      env->CallBooleanMethod(b->obj, b->mid_secure_put, jk, jv) : JNI_FALSE;
  const bool exception = clearJavaException(env, "secure_put");
  if (jk) env->DeleteLocalRef(jk);
  if (jv) env->DeleteLocalRef(jv);
  return !exception && ok == JNI_TRUE ? 0 : -1;
}

int platDeviceInfo(void* user, char** out_json) {
  auto* b = static_cast<Bridge*>(user);
  if (!b || !out_json) return -1;
  *out_json = nullptr;
  JNIEnv* env = envForThisThread();
  if (!env || !b->obj) return -1;
  auto* value = static_cast<jstring>(
      env->CallObjectMethod(b->obj, b->mid_device_info));
  if (clearJavaException(env, "device_info") || !value) return -1;
  const bool copied = copyJavaString(env, b, value, out_json);
  env->DeleteLocalRef(value);
  return copied ? 0 : -1;
}

void platReleaseBuffer(void*, void* buffer) { std::free(buffer); }

void uiEventCb(void* user, const char* event_json) {
  auto* b = static_cast<Bridge*>(user);
  JNIEnv* env = envForThisThread();
  if (!env || !b->obj) return;
  jstring js = toJString(env, b, event_json);
  callVoidChecked(env, b, b->mid_ui_event, js, nullptr);
  if (js) env->DeleteLocalRef(js);
}

Bridge* fromHandle(jlong h) { return reinterpret_cast<Bridge*>(h); }

}  // namespace

extern "C" JNIEXPORT jint JNI_OnLoad(JavaVM* vm, void*) {
  g_vm = vm;
  // PJSIP's Android GUID generator uses Java UUID for SIP tags and call IDs. Its own
  // JNI_OnLoad is disabled because this shared library has one, so register the JVM here.
  // Without this call, the first incoming INVITE can abort while creating an empty tag.
  pj_jni_set_jvm(vm);
  return JNI_VERSION_1_6;
}

extern "C" JNIEXPORT jlong JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeCreate(JNIEnv* env, jobject thiz, jstring data_dir,
                                                  jstring boot_json) {
  auto* b = new Bridge();
  b->obj = env->NewGlobalRef(thiz);
  jclass cls = env->GetObjectClass(thiz);
  b->mid_ui_event = env->GetMethodID(cls, "onUiEventFromNative", "(Ljava/lang/String;)V");
  b->mid_tts = env->GetMethodID(cls, "onTtsFromNative",
                                "(Ljava/lang/String;Ljava/lang/String;)V");
  b->mid_https = env->GetMethodID(
      cls, "onHttpsRequestFromNative",
      "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;[B)[B");
  b->mid_secure_get = env->GetMethodID(
      cls, "onSecureGetFromNative", "(Ljava/lang/String;)Ljava/lang/String;");
  b->mid_secure_put = env->GetMethodID(
      cls, "onSecurePutFromNative", "(Ljava/lang/String;Ljava/lang/String;)Z");
  b->mid_device_info = env->GetMethodID(
      cls, "onDeviceInfoFromNative", "()Ljava/lang/String;");
  jclass str = env->FindClass("java/lang/String");
  b->cls_string = static_cast<jclass>(env->NewGlobalRef(str));
  b->mid_string_ctor = env->GetMethodID(str, "<init>", "([BLjava/lang/String;)V");
  b->mid_string_get_bytes = env->GetMethodID(str, "getBytes", "(Ljava/lang/String;)[B");
  jstring u = env->NewStringUTF("UTF-8");
  b->utf8 = static_cast<jstring>(env->NewGlobalRef(u));
  env->DeleteLocalRef(u);
  env->DeleteLocalRef(str);
  env->DeleteLocalRef(cls);
  if (!b->obj || !b->cls_string || !b->utf8 || !b->mid_ui_event || !b->mid_tts ||
      !b->mid_https || !b->mid_secure_get || !b->mid_secure_put || !b->mid_device_info ||
      !b->mid_string_ctor || !b->mid_string_get_bytes) {
    clearJavaException(env, "nativeCreate method lookup");
    if (b->obj) env->DeleteGlobalRef(b->obj);
    if (b->cls_string) env->DeleteGlobalRef(b->cls_string);
    if (b->utf8) env->DeleteGlobalRef(b->utf8);
    delete b;
    return 0;
  }

  b->plat.struct_size = sizeof(db_platform_v2);
  b->plat.version = DB_PLATFORM_V2_VERSION;
  b->plat.user = b;
  b->plat.https_request = platHttpsRequest;
  b->plat.secure_get = platSecureGet;
  b->plat.secure_put = platSecurePut;
  b->plat.log_line = platLogLine;
  b->plat.tts_speak = platTtsSpeak;
  b->plat.device_info = platDeviceInfo;
  b->plat.release_buffer = platReleaseBuffer;

  const std::string dir = toUtf8(env, data_dir);
  const std::string boot = toUtf8(env, boot_json);
  b->core = db_core_create_v2(&b->plat, dir.c_str(), boot.c_str());
  if (!b->core) {
    env->DeleteGlobalRef(b->obj);
    env->DeleteGlobalRef(b->cls_string);
    env->DeleteGlobalRef(b->utf8);
    delete b;
    return 0;
  }
  return reinterpret_cast<jlong>(b);
}

extern "C" JNIEXPORT jstring JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeBackendJson(JNIEnv* env, jobject) {
  const std::string json = std::string("{\"platform_abi\":2,\"sip\":\"pjsip\",\"pjsip_tier\":\"") +
                           DB_ANDROID_PJSIP_TIER_NAME + "\"}";
  return env->NewStringUTF(json.c_str());
}

extern "C" JNIEXPORT jint JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeStart(JNIEnv*, jobject, jlong h) {
  Bridge* b = fromHandle(h);
  return b && b->core ? db_core_start(b->core) : -1;
}

extern "C" JNIEXPORT void JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeStop(JNIEnv*, jobject, jlong h) {
  Bridge* b = fromHandle(h);
  if (b && b->core) db_core_stop(b->core);
}

extern "C" JNIEXPORT void JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeDestroy(JNIEnv* env, jobject, jlong h) {
  Bridge* b = fromHandle(h);
  if (!b) return;
  if (b->core) db_core_destroy(b->core);
  if (b->obj) env->DeleteGlobalRef(b->obj);
  if (b->cls_string) env->DeleteGlobalRef(b->cls_string);
  if (b->utf8) env->DeleteGlobalRef(b->utf8);
  delete b;
}

extern "C" JNIEXPORT void JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeSetUiCallback(JNIEnv*, jobject, jlong h,
                                                         jboolean enabled) {
  Bridge* b = fromHandle(h);
  if (b && b->core)
    db_core_set_ui_callback(b->core, enabled ? uiEventCb : nullptr, b);
}

extern "C" JNIEXPORT void JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativePress(JNIEnv* env, jobject, jlong h, jstring door_id) {
  Bridge* b = fromHandle(h);
  if (b && b->core) db_core_press(b->core, toUtf8(env, door_id).c_str());
}

extern "C" JNIEXPORT void JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativePressPurpose(JNIEnv* env, jobject, jlong h,
                                                        jstring door_id, jstring purpose) {
  Bridge* b = fromHandle(h);
  if (b && b->core)
    db_core_press_purpose(b->core, toUtf8(env, door_id).c_str(), toUtf8(env, purpose).c_str());
}

extern "C" JNIEXPORT void JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeSelectPurpose(JNIEnv* env, jobject, jlong h,
                                                         jstring door_id, jstring purpose) {
  Bridge* b = fromHandle(h);
  if (b && b->core)
    db_core_select_purpose(b->core, toUtf8(env, door_id).c_str(), toUtf8(env, purpose).c_str());
}

extern "C" JNIEXPORT void JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeCancelCall(JNIEnv* env, jobject, jlong h,
                                                      jstring door_id) {
  Bridge* b = fromHandle(h);
  if (b && b->core) db_core_cancel_call(b->core, toUtf8(env, door_id).c_str());
}

extern "C" JNIEXPORT jstring JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativePressV2(JNIEnv* env, jobject, jlong h,
                                                   jstring door_id, jstring purpose) {
  Bridge* b = fromHandle(h);
  if (!b || !b->core) return nullptr;
  const std::string door = toUtf8(env, door_id);
  const std::string selected_purpose = toUtf8(env, purpose);
  char* call_id = db_core_press_v2(b->core, door.c_str(), selected_purpose.c_str());
  jstring result = toJString(env, b, call_id);
  db_free(call_id);
  return result;
}

extern "C" JNIEXPORT jint JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeSelectPurposeV2(
    JNIEnv* env, jobject, jlong h, jstring door_id, jstring call_id, jstring purpose) {
  Bridge* b = fromHandle(h);
  if (!b || !b->core) return -1;
  const std::string door = toUtf8(env, door_id);
  const std::string id = toUtf8(env, call_id);
  const std::string selected_purpose = toUtf8(env, purpose);
  return db_core_select_purpose_v2(b->core, door.c_str(), id.c_str(),
                                   selected_purpose.c_str());
}

extern "C" JNIEXPORT jint JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeCancelCallV2(
    JNIEnv* env, jobject, jlong h, jstring door_id, jstring call_id, jstring reason) {
  Bridge* b = fromHandle(h);
  if (!b || !b->core) return -1;
  const std::string door = toUtf8(env, door_id);
  const std::string id = toUtf8(env, call_id);
  const std::string why = toUtf8(env, reason);
  return db_core_cancel_call_v2(b->core, door.c_str(), id.c_str(), why.c_str());
}

extern "C" JNIEXPORT jint JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeReportCallAnsweredV2(
    JNIEnv* env, jobject, jlong h, jstring door_id, jstring call_id, jint stage_revision) {
  Bridge* b = fromHandle(h);
  if (!b || !b->core) return -1;
  const std::string door = toUtf8(env, door_id);
  const std::string id = toUtf8(env, call_id);
  return db_core_report_call_answered_v2(b->core, door.c_str(), id.c_str(),
                                         static_cast<int>(stage_revision));
}

extern "C" JNIEXPORT jint JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeReportCallEndedV2(
    JNIEnv* env, jobject, jlong h, jstring door_id, jstring call_id, jint stage_revision,
    jstring reason) {
  Bridge* b = fromHandle(h);
  if (!b || !b->core) return -1;
  const std::string door = toUtf8(env, door_id);
  const std::string id = toUtf8(env, call_id);
  const std::string why = toUtf8(env, reason);
  return db_core_report_call_ended_v2(b->core, door.c_str(), id.c_str(),
                                      static_cast<int>(stage_revision), why.c_str());
}

extern "C" JNIEXPORT void JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeReportCallRecovery(
    JNIEnv* env, jobject, jlong h, jstring call_id, jboolean restored) {
  Bridge* b = fromHandle(h);
  if (!b || !b->core) return;
  const std::string id = toUtf8(env, call_id);
  db_core_report_call_recovery(b->core, id.c_str(), restored == JNI_TRUE ? 1 : 0);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeEmergencyV2(JNIEnv*, jobject, jlong h,
                                                        jboolean active) {
  Bridge* b = fromHandle(h);
  return b && b->core && db_core_emergency_v2(b->core, active == JNI_TRUE ? 1 : 0) != 0
      ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT void JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeSetVisitorLang(JNIEnv* env, jobject, jlong h,
                                                          jstring door, jstring lang) {
  Bridge* b = fromHandle(h);
  if (b && b->core)
    db_core_set_visitor_lang(b->core, toUtf8(env, door).c_str(), toUtf8(env, lang).c_str());
}

extern "C" JNIEXPORT jstring JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeStatusJson(JNIEnv* env, jobject, jlong h) {
  Bridge* b = fromHandle(h);
  if (!b || !b->core) return nullptr;
  char* s = db_core_status_json(b->core);
  jstring out = toJString(env, b, s);
  db_free(s);
  return out;
}

extern "C" JNIEXPORT jstring JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeConfigJson(JNIEnv* env, jobject, jlong h) {
  Bridge* b = fromHandle(h);
  if (!b || !b->core) return nullptr;
  char* s = db_core_config_json(b->core);
  jstring out = toJString(env, b, s);
  db_free(s);
  return out;
}

extern "C" JNIEXPORT void JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeSetCapabilitiesJson(JNIEnv* env, jobject, jlong h,
                                                               jstring json) {
  Bridge* b = fromHandle(h);
  if (b && b->core) db_core_set_capabilities_json(b->core, toUtf8(env, json).c_str());
}

extern "C" JNIEXPORT void JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeSetRuntimeStatusJson(JNIEnv* env, jobject, jlong h,
                                                                jstring json) {
  Bridge* b = fromHandle(h);
  if (b && b->core) db_core_set_runtime_status_json(b->core, toUtf8(env, json).c_str());
}

extern "C" JNIEXPORT void JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeSetUiManifestJson(JNIEnv* env, jobject, jlong h,
                                                             jstring json) {
  Bridge* b = fromHandle(h);
  if (b && b->core) db_core_set_ui_manifest_json(b->core, toUtf8(env, json).c_str());
}

extern "C" JNIEXPORT jstring JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeCapabilitiesJson(JNIEnv* env, jobject, jlong h) {
  Bridge* b = fromHandle(h);
  if (!b || !b->core) return nullptr;
  char* s = db_core_capabilities_json(b->core);
  jstring out = toJString(env, b, s);
  db_free(s);
  return out;
}

extern "C" JNIEXPORT void JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeOnCameraFrame(JNIEnv* env, jobject, jlong h,
                                                         jbyteArray data, jint format, jint width,
                                                         jint height, jint stride, jlong ts_ms) {
  Bridge* b = fromHandle(h);
  if (!b || !b->core || !data) return;
  jbyte* p = env->GetByteArrayElements(data, nullptr);
  if (!p) return;
  db_core_on_camera_frame(b->core, reinterpret_cast<const uint8_t*>(p), format, width, height,
                          stride, ts_ms);
  env->ReleaseByteArrayElements(data, p, JNI_ABORT);
}

extern "C" JNIEXPORT void JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeSetVideoSensorRotation(JNIEnv*, jobject, jlong h,
                                                                  jint degrees) {
  Bridge* b = fromHandle(h);
  if (b && b->core) db_core_set_video_sensor_rotation(b->core, static_cast<int>(degrees));
}

extern "C" JNIEXPORT void JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeOnEncodedFrame(JNIEnv* env, jobject, jlong h,
                                                          jbyteArray annexb, jboolean is_key,
                                                          jlong ts_ms) {
  Bridge* b = fromHandle(h);
  if (!b || !b->core || !annexb) return;
  const jsize len = env->GetArrayLength(annexb);
  if (len <= 0) return;
  jbyte* p = env->GetByteArrayElements(annexb, nullptr);
  if (!p) return;
  db_core_on_encoded_frame(b->core, reinterpret_cast<const uint8_t*>(p),
                           static_cast<size_t>(len), is_key ? 1 : 0, ts_ms);
  env->ReleaseByteArrayElements(annexb, p, JNI_ABORT);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeVideoEncoderWanted(JNIEnv*, jobject, jlong h) {
  Bridge* b = fromHandle(h);
  return (b && b->core && db_core_video_encoder_wanted(b->core)) ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT void JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeSipCall(JNIEnv* env, jobject, jlong h, jstring target,
                                                   jstring mode) {
  Bridge* b = fromHandle(h);
  if (b && b->core)
    db_core_sip_call(b->core, toUtf8(env, target).c_str(), toUtf8(env, mode).c_str());
}

extern "C" JNIEXPORT void JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeSipHangup(JNIEnv*, jobject, jlong h) {
  Bridge* b = fromHandle(h);
  if (b && b->core) db_core_sip_hangup(b->core);
}

extern "C" JNIEXPORT jint JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeSipSendDtmf(JNIEnv* env, jobject, jlong h,
                                                       jstring digits) {
  Bridge* b = fromHandle(h);
  if (!b || !b->core) return -1;
  const std::string value = toUtf8(env, digits);
  return db_core_sip_send_dtmf(b->core, value.c_str());
}

extern "C" JNIEXPORT void JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeQuickReply(JNIEnv* env, jobject, jlong h,
                                                      jstring reply_id, jstring door) {
  Bridge* b = fromHandle(h);
  if (b && b->core)
    db_core_quick_reply(b->core, toUtf8(env, reply_id).c_str(), toUtf8(env, door).c_str());
}

extern "C" JNIEXPORT jboolean JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeQuickReplyV2(
    JNIEnv* env, jobject, jlong h, jstring reply_id, jstring door, jstring call_id,
    jint stage_revision) {
  Bridge* b = fromHandle(h);
  if (!b || !b->core) return JNI_FALSE;
  const std::string reply = toUtf8(env, reply_id);
  const std::string target_door = toUtf8(env, door);
  const std::string call = toUtf8(env, call_id);
  return db_core_quick_reply_v2(b->core, reply.c_str(), target_door.c_str(), call.c_str(),
                                static_cast<int>(stage_revision)) == 0
      ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jstring JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeVersion(JNIEnv* env, jobject) {
  return env->NewStringUTF(db_core_version());
}

// Pairing discovery and invitation.
extern "C" JNIEXPORT jstring JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativePairingJson(JNIEnv* env, jobject, jlong h) {
  Bridge* b = fromHandle(h);
  if (!b || !b->core) return nullptr;
  char* s = db_core_pairing_json(b->core);
  jstring out = toJString(env, b, s);
  db_free(s);
  return out;
}

extern "C" JNIEXPORT void JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeJoinCluster(JNIEnv* env, jobject, jlong h, jstring host,
                                                       jstring pin) {
  Bridge* b = fromHandle(h);
  if (b && b->core)
    db_core_join_cluster(b->core, toUtf8(env, host).c_str(), toUtf8(env, pin).c_str());
}

extern "C" JNIEXPORT void JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativePairingMode(JNIEnv*, jobject, jlong h, jint seconds) {
  Bridge* b = fromHandle(h);
  if (b && b->core) db_core_pairing_mode(b->core, static_cast<int>(seconds));
}

extern "C" JNIEXPORT void JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeInviteDevice(JNIEnv* env, jobject, jlong h, jstring id) {
  Bridge* b = fromHandle(h);
  if (b && b->core) db_core_invite_device(b->core, toUtf8(env, id).c_str());
}

extern "C" JNIEXPORT jboolean JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeFoundCluster(JNIEnv*, jobject, jlong h) {
  Bridge* b = fromHandle(h);
  return (b && b->core && db_core_found_cluster(b->core)) ? JNI_TRUE : JNI_FALSE;
}

// Core QR encoding returns [side length, row-major module values...] or null.
extern "C" JNIEXPORT jintArray JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeQrEncode(JNIEnv* env, jobject, jstring text) {
  const std::string t = toUtf8(env, text);
  int size = 0;
  unsigned char* m = db_core_qr_encode(t.c_str(), &size);
  if (!m) return nullptr;
  if (size <= 0) { db_free(reinterpret_cast<char*>(m)); return nullptr; }
  std::vector<jint> buf(1 + static_cast<size_t>(size) * size);
  buf[0] = size;
  for (int i = 0; i < size * size; i++) buf[1 + i] = m[i];
  db_free(reinterpret_cast<char*>(m));
  jintArray arr = env->NewIntArray(static_cast<jsize>(buf.size()));
  if (arr) env->SetIntArrayRegion(arr, 0, static_cast<jsize>(buf.size()), buf.data());
  return arr;
}
