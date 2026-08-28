/* minisip_test.c — Mac CLI 検証ドライバ。門口機 (core/sipctl) の直接呼待受へ実際に
 * 呼を張り、RTP 疎通と DTMF を確認する。
 *
 * ビルド (macOS):
 *   cc -std=c99 -Wall ios-legacy/mini_sip/g711.c ios-legacy/mini_sip/sdp.c \
 *      ios-legacy/mini_sip/sip.c ios-legacy/mini_sip/rtp.c \
 *      ios-legacy/mini_sip/minisip.c ios-legacy/mini_sip/minisip_test.c \
 *      -o /tmp/minisip_test
 *
 * 使い方:
 *   minisip_test call <host> <port> <monitor|answer> <seconds>
 *       直接呼を張り、確立後 <seconds> 秒 RTP を流して tx/rx パケット数を表示、BYE。
 *   minisip_test dtmf <host> <port> <digits>
 *       answer 直呼を張り、確立後 DTMF (<digits> 例 '*1') を送出、BYE。
 *
 * 音声源はテスト用に 440Hz 正弦波 (pull_tx_audio)。受信音声は破棄 (カウントのみ)。 */
#include "minisip.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

static long long now_ms(void) {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return (long long)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

/* 正弦波位相 (連続性のため静的に保持) */
static double g_phase = 0.0;

static int pull_tx(int16_t *pcm, int n, void *user) {
  int i;
  (void)user;
  for (i = 0; i < n; i++) {
    pcm[i] = (int16_t)(8000.0 * sin(g_phase));
    g_phase += 2.0 * 3.14159265358979 * 440.0 / 8000.0;
    if (g_phase > 2.0 * 3.14159265358979) g_phase -= 2.0 * 3.14159265358979;
  }
  return n; /* 常に n サンプル供給 (無音でなく実音を送る) */
}

static unsigned long g_rx_samples = 0;
static void on_rx(const int16_t *pcm, int n, void *user) {
  (void)pcm;
  (void)user;
  g_rx_samples += (unsigned long)n;
}

static const char *state_name(ms_state st) {
  switch (st) {
    case MS_STATE_CALLING: return "calling";
    case MS_STATE_IN_CALL: return "in_call";
    case MS_STATE_ENDED: return "ended";
  }
  return "?";
}

static void on_state(ms_state st, void *user) {
  (void)user;
  printf("[state] %s\n", state_name(st));
}

static const char *reason_name(ms_end_reason r) {
  switch (r) {
    case MS_END_NONE: return "none";
    case MS_END_LOCAL_BYE: return "local_bye";
    case MS_END_REMOTE_BYE: return "remote_bye";
    case MS_END_REJECTED: return "rejected";
    case MS_END_TIMEOUT: return "timeout";
    case MS_END_ERROR: return "error";
  }
  return "?";
}

/* 確立まで待つ。成功で 0、確立せず ENDED なら -1。 */
static int wait_established(ms_session *s, int max_ms) {
  long long deadline = now_ms() + max_ms;
  while (now_ms() < deadline) {
    ms_poll(s, 20);
    if (ms_get_state(s) == MS_STATE_IN_CALL) return 0;
    if (ms_get_state(s) == MS_STATE_ENDED) return -1;
  }
  return -1;
}

/* ENDED まで poll し続ける (BYE 完了待ち)。 */
static void drain_until_ended(ms_session *s, int max_ms) {
  long long deadline = now_ms() + max_ms;
  while (now_ms() < deadline && ms_get_state(s) != MS_STATE_ENDED) {
    ms_poll(s, 20);
  }
}

static int cmd_call(const char *host, int port, const char *mode, int seconds) {
  ms_callbacks cbs;
  ms_session *s;
  unsigned long tx = 0, rx = 0;
  long long t_end;

  memset(&cbs, 0, sizeof(cbs));
  cbs.pull_tx_audio = pull_tx;
  cbs.on_rx_audio = on_rx;
  cbs.on_state = on_state;

  printf("== call %s:%d mode=%s dur=%ds\n", host, port, mode, seconds);
  s = ms_call(host, port, mode, &cbs);
  if (!s) {
    fprintf(stderr, "ms_call 失敗\n");
    return 2;
  }
  if (wait_established(s, 15000) != 0) {
    fprintf(stderr, "確立せず (reason=%s)\n", reason_name(ms_get_end_reason(s)));
    ms_free(s);
    return 2;
  }
  printf("[rtp] remote=%s\n", ms_get_remote_rtp(s));

  /* seconds 秒間 RTP を流す */
  t_end = now_ms() + (long long)seconds * 1000;
  while (now_ms() < t_end && ms_get_state(s) == MS_STATE_IN_CALL) {
    ms_poll(s, 20);
  }

  ms_get_stats(s, &tx, &rx);
  printf("[stats] tx=%lu rx=%lu rx_samples=%lu\n", tx, rx, g_rx_samples);

  ms_hangup(s);
  drain_until_ended(s, 2000);
  printf("[end] state=%s reason=%s\n", state_name(ms_get_state(s)),
         reason_name(ms_get_end_reason(s)));

  /* 判定: monitor は rx>50、answer は tx>50 && rx>50 */
  {
    int ok;
    if (strcmp(mode, "answer") == 0) {
      ok = (tx > 50 && rx > 50);
    } else {
      ok = (rx > 50);
    }
    printf("[result] %s (mode=%s tx=%lu rx=%lu)\n", ok ? "PASS" : "FAIL", mode, tx,
           rx);
    ms_free(s);
    return ok ? 0 : 1;
  }
}

static int cmd_dtmf(const char *host, int port, const char *digits) {
  ms_callbacks cbs;
  ms_session *s;
  unsigned long tx = 0, rx = 0;

  memset(&cbs, 0, sizeof(cbs));
  cbs.pull_tx_audio = pull_tx;
  cbs.on_rx_audio = on_rx;
  cbs.on_state = on_state;

  printf("== dtmf %s:%d digits=%s\n", host, port, digits);
  s = ms_call(host, port, "answer", &cbs);
  if (!s) {
    fprintf(stderr, "ms_call 失敗\n");
    return 2;
  }
  if (wait_established(s, 15000) != 0) {
    fprintf(stderr, "確立せず (reason=%s)\n", reason_name(ms_get_end_reason(s)));
    ms_free(s);
    return 2;
  }
  printf("[rtp] remote=%s\n", ms_get_remote_rtp(s));

  /* 少し音声を流してから DTMF 送出 */
  {
    long long t = now_ms() + 300;
    while (now_ms() < t && ms_get_state(s) == MS_STATE_IN_CALL) ms_poll(s, 20);
  }
  printf("[dtmf] send '%s'\n", digits);
  ms_send_dtmf(s, digits);

  /* DTMF 送出 + 余韻を流す (桁数 * ~200ms + 1s) */
  {
    long long t = now_ms() + (long long)strlen(digits) * 250 + 1000;
    while (now_ms() < t && ms_get_state(s) == MS_STATE_IN_CALL) ms_poll(s, 20);
  }

  ms_get_stats(s, &tx, &rx);
  printf("[stats] tx=%lu rx=%lu\n", tx, rx);

  ms_hangup(s);
  drain_until_ended(s, 2000);
  printf("[end] state=%s reason=%s\n", state_name(ms_get_state(s)),
         reason_name(ms_get_end_reason(s)));
  printf("[result] DTMF 送出完了 (門口機ログで digit を確認すること)\n");
  ms_free(s);
  return 0;
}

int main(int argc, char **argv) {
  if (argc >= 6 && strcmp(argv[1], "call") == 0) {
    return cmd_call(argv[2], atoi(argv[3]), argv[4], atoi(argv[5]));
  }
  if (argc >= 5 && strcmp(argv[1], "dtmf") == 0) {
    return cmd_dtmf(argv[2], atoi(argv[3]), argv[4]);
  }
  fprintf(stderr,
          "usage:\n"
          "  %s call <host> <port> <monitor|answer> <seconds>\n"
          "  %s dtmf <host> <port> <digits>\n",
          argv[0], argv[0]);
  return 2;
}
