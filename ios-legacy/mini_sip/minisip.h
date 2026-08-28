/* minisip.h — 手書き迷い SIP/RTP/G.711 UAC (公開 API)。
 *
 * 目的: iPad 1 (iOS 5.1.1, armv7) 門铃衛星ノードの「音声レッグ」。PJSIP の iOS5
 * クロスビルドを回避するため、門口機 (core/sipctl) への直接呼 (REGISTER 不要・
 * 認証不要・自動応答) に必要な最小の SIP UAC + RTP + G.711(PCMU) + RFC2833 DTMF を
 * 純 C で自前実装する。
 *
 * 対応範囲 (門口機 sipctl が受ける前提):
 *   - コーデックは PCMU/8000 のみ (全経路 8kHz、リサンプルなし)
 *   - X-Doorbell-Mode: "monitor" (一方向: 門口マイク→こちら) / "answer" (双方向)
 *   - RFC2833 DTMF 送信 (通話中の *1 = 開門 など)
 *
 * 移植性: 純 C89/C99、C++/libc++ 非依存、外部ライブラリ非依存。BSD ソケット +
 * select のみ。単一スレッド poll モデル (pthread 不要)。iOS5 armv7 で素直に通る。
 *
 * スレッドモデル: 1 セッションは 1 スレッドから駆動する (ms_call で生成し、同じ
 * スレッドから ms_poll をループ)。門口機の契約に合わせ主呼は同時 1 本。
 *
 * 音声 SPI (プラットフォームが埋める):
 *   - on_rx_audio: 門口から届いた PCM をプラットフォームが再生する
 *   - pull_tx_audio: プラットフォームがマイク PCM を渡す (0 サンプル返却で無音送信)
 *   iOS 実機は後続で AudioUnit RemoteIO を接続。Mac テストは無音/正弦波で埋める。
 */
#ifndef MINISIP_H
#define MINISIP_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 通話状態 (状態コールバックで通知)。 */
typedef enum {
  MS_STATE_CALLING = 0, /* INVITE 送信〜200 OK 待ち */
  MS_STATE_IN_CALL = 1, /* 200 OK 受信 + ACK 済み。RTP 疎通中 */
  MS_STATE_ENDED = 2    /* BYE 完了 / 失敗 / タイムアウト */
} ms_state;

/* 終了理由 (ms_get_end_reason)。 */
typedef enum {
  MS_END_NONE = 0,
  MS_END_LOCAL_BYE,   /* こちらから ms_hangup */
  MS_END_REMOTE_BYE,  /* 門口機から BYE */
  MS_END_REJECTED,    /* 4xx/5xx/6xx 最終応答 (486 通話中 等) */
  MS_END_TIMEOUT,     /* 32s 以内に確立せず */
  MS_END_ERROR        /* ソケット等の致命エラー */
} ms_end_reason;

/* 20ms @ 8kHz = 160 サンプル/パケット。SPI コールバックはこの粒度で来る。 */
#define MS_SAMPLES_PER_FRAME 160

/* プラットフォーム連携コールバック群。すべて ms_poll を呼んだスレッド上で実行される
 * (別スレッドからは呼ばれない — ロック不要)。NULL 許容。 */
typedef struct {
  /* 門口からの受信音声 (デコード済み linear16, n サンプル)。門口の声を再生する。 */
  void (*on_rx_audio)(const int16_t *pcm, int n, void *user);

  /* 送信音声の要求。pcm に最大 n サンプル書き込み、書いた数を返す。
   * 0 を返すと無音 (μ-law 0xFF) を送る。音源が無い/未接続なら 0 でよい。 */
  int (*pull_tx_audio)(int16_t *pcm, int n, void *user);

  /* 状態遷移通知 (CALLING → IN_CALL → ENDED)。 */
  void (*on_state)(ms_state st, void *user);

  /* 任意ユーザデータ (各コールバックへ透過)。 */
  void *user;
} ms_callbacks;

typedef struct ms_session ms_session;

/* 直接呼を開始する。
 *   host  : 門口機 IP (例 "127.0.0.1")
 *   port  : 門口機 SIP 待受ポート (既定 47190 — docs/network-ports.md)
 *   mode  : "monitor" | "answer" | "" (X-Doorbell-Mode ヘッダ値。"" はヘッダ無し)
 *   cbs   : 音声/状態コールバック (内容はコピーされる。NULL 可)
 * 戻り値: セッションハンドル。失敗時 NULL。
 * この時点で INVITE を送信し状態は CALLING。以降 ms_poll で駆動する。 */
ms_session *ms_call(const char *host, int port, const char *mode,
                    const ms_callbacks *cbs);

/* ネットワーク + RTP を 1 回ポンプする。timeout_ms はソケット待ちの上限
 * (内部で次 RTP 送信期限に合わせ短縮する)。通話が続く限りループで呼び続ける。
 * 戻り値: 0 = 継続、1 = 終了 (ENDED に達した)、負値 = 致命エラー。 */
int ms_poll(ms_session *s, int timeout_ms);

/* 通話中に RFC2833 DTMF を送る。digits は "*1" 等の並び (0-9 * # A-D)。
 * 各桁は複数の telephone-event パケット (末尾に end bit) として送出される。
 * IN_CALL 以外では無視。キューされ ms_poll の RTP tick で送出。 */
int ms_send_dtmf(ms_session *s, const char *digits);

/* BYE を送って通話を終える (最大数百 ms 応答待ち)。以降 ms_poll は 1 を返す。 */
void ms_hangup(ms_session *s);

/* セッション破棄 (ソケットを閉じ資源解放)。未 hangup なら BYE を試みる。 */
void ms_free(ms_session *s);

/* 現在の状態。 */
ms_state ms_get_state(const ms_session *s);

/* 終了理由 (ENDED 到達後に有効)。 */
ms_end_reason ms_get_end_reason(const ms_session *s);

/* RTP 送受パケット数の実測値 (診断/テスト)。NULL 可。 */
void ms_get_stats(const ms_session *s, unsigned long *tx_pkts,
                  unsigned long *rx_pkts);

/* 協商済みの門口 RTP 宛先 (デバッグ表示用)。確立前は "0.0.0.0:0"。 */
const char *ms_get_remote_rtp(const ms_session *s);

#ifdef __cplusplus
}
#endif

#endif /* MINISIP_H */
