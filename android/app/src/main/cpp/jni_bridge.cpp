// doorbell-core C ABI ⇔ Kotlin (jp.keihan.doorbell.DoorbellCore) の JNI グルー。
// 規約 (doorbell.h): コールバックは core 内部スレッドから呼ばれる — ここで JavaVM に
// AttachCurrentThread し、UI スレッドへの marshal は Kotlin 側 (Handler) の責務。
// attach したスレッドは pthread TLS デストラクタで自動 detach する (毎回 detach は高コスト)。
#include <android/log.h>
#include <jni.h>
#include <pthread.h>

#include <cstring>
#include <string>
#include <vector>

#include "doorbell/doorbell.h"

namespace {

JavaVM* g_vm = nullptr;
pthread_key_t g_tls_key;          // 値: attach したスレッドの JNIEnv* (detach 用の印)
pthread_once_t g_tls_once = PTHREAD_ONCE_INIT;

void detachThread(void*) {
  if (g_vm) g_vm->DetachCurrentThread();
}

void makeTlsKey() { pthread_key_create(&g_tls_key, detachThread); }

// core スレッドから呼ぶ際の JNIEnv 取得。必要なら attach し、TLS に登録して終了時に detach。
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

// DoorbellCore インスタンス 1 個ぶんの結線。db_platform は core より長生きさせる。
struct Bridge {
  db_core* core = nullptr;
  db_platform plat{};
  jobject obj = nullptr;          // DoorbellCore の GlobalRef
  jmethodID mid_ui_event = nullptr;   // onUiEventFromNative(String)
  jmethodID mid_tts = nullptr;        // onTtsFromNative(String, String)
  jclass cls_string = nullptr;        // java/lang/String (GlobalRef)
  jmethodID mid_string_ctor = nullptr;  // String(byte[], String charset)
  jstring utf8 = nullptr;             // "UTF-8" (GlobalRef)
};

// UTF-8 → jstring。NewStringUTF は修正 UTF-8 前提で絵文字 (4 バイト列) で落ちるため、
// String(byte[], "UTF-8") 経由で作る (クイック返信の文言に絵文字が来ても安全)。
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

// jstring → std::string (UTF-8)。boot.json / door id 等の入力用 (BMP 内なら MUTF-8 と一致)。
std::string toUtf8(JNIEnv* env, jstring s) {
  if (!s) return "";
  const char* p = env->GetStringUTFChars(s, nullptr);
  std::string out = p ? p : "";
  if (p) env->ReleaseStringUTFChars(s, p);
  return out;
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

// ---------- db_platform コールバック (core 内部スレッド) ----------

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
  jclass str = env->FindClass("java/lang/String");
  b->cls_string = static_cast<jclass>(env->NewGlobalRef(str));
  b->mid_string_ctor = env->GetMethodID(str, "<init>", "([BLjava/lang/String;)V");
  jstring u = env->NewStringUTF("UTF-8");
  b->utf8 = static_cast<jstring>(env->NewGlobalRef(u));
  env->DeleteLocalRef(u);
  env->DeleteLocalRef(str);
  env->DeleteLocalRef(cls);
  if (!b->mid_ui_event || !b->mid_tts || !b->mid_string_ctor) {
    delete b;
    return 0;
  }

  b->plat.user = b;
  b->plat.https_request = nullptr;  // Phase 3 後半 (Cronet か HttpsURLConnection ラッパ)
  b->plat.secure_get = nullptr;     // Phase 3 後半 (Android Keystore)
  b->plat.secure_put = nullptr;
  b->plat.log_line = platLogLine;
  b->plat.tts_speak = platTtsSpeak;

  const std::string dir = toUtf8(env, data_dir);
  const std::string boot = toUtf8(env, boot_json);
  b->core = db_core_create(&b->plat, dir.c_str(), boot.c_str());
  if (!b->core) {
    env->DeleteGlobalRef(b->obj);
    env->DeleteGlobalRef(b->cls_string);
    env->DeleteGlobalRef(b->utf8);
    delete b;
    return 0;
  }
  return reinterpret_cast<jlong>(b);
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
Java_jp_keihan_doorbell_DoorbellCore_nativeOnCameraFrame(JNIEnv* env, jobject, jlong h,
                                                         jbyteArray data, jint format, jint width,
                                                         jint height, jint stride, jlong ts_ms) {
  Bridge* b = fromHandle(h);
  if (!b || !b->core || !data) return;
  jbyte* p = env->GetByteArrayElements(data, nullptr);
  if (!p) return;
  db_core_on_camera_frame(b->core, reinterpret_cast<const uint8_t*>(p), format, width, height,
                          stride, ts_ms);
  env->ReleaseByteArrayElements(data, p, JNI_ABORT);  // 読み取りのみ — 書き戻し不要
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
  env->ReleaseByteArrayElements(annexb, p, JNI_ABORT);  // 読み取りのみ — 書き戻し不要
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

extern "C" JNIEXPORT void JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeQuickReply(JNIEnv* env, jobject, jlong h,
                                                      jstring reply_id, jstring door) {
  Bridge* b = fromHandle(h);
  if (b && b->core)
    db_core_quick_reply(b->core, toUtf8(env, reply_id).c_str(), toUtf8(env, door).c_str());
}

extern "C" JNIEXPORT jstring JNICALL
Java_jp_keihan_doorbell_DoorbellCore_nativeVersion(JNIEnv* env, jobject) {
  return env->NewStringUTF(db_core_version());
}

// --- 配対 (発見/招待) ---
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

// QR エンコード (core 共通実装)。戻り値 int[]: [0]=一辺のモジュール数, [1..]=行優先 0/1。失敗 null。
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
