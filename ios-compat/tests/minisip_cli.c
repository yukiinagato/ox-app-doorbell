#include "minisip.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

static double g_phase;
static unsigned long g_rx_samples;

static long long now_ms(void) {
  struct timeval value;
  gettimeofday(&value, NULL);
  return (long long)value.tv_sec * 1000 + value.tv_usec / 1000;
}

static int pull_tone(int16_t *pcm, int count, void *user) {
  int i;
  (void)user;
  for (i = 0; i < count; ++i) {
    pcm[i] = (int16_t)(8000.0 * sin(g_phase));
    g_phase += 2.0 * 3.14159265358979 * 440.0 / 8000.0;
    if (g_phase > 2.0 * 3.14159265358979)
      g_phase -= 2.0 * 3.14159265358979;
  }
  return count;
}

static void receive_audio(const int16_t *pcm, int count, void *user) {
  (void)pcm;
  (void)user;
  g_rx_samples += (unsigned long)count;
}

static const char *state_name(ms_state state) {
  switch (state) {
    case MS_STATE_CALLING: return "calling";
    case MS_STATE_IN_CALL: return "in_call";
    case MS_STATE_ENDED: return "ended";
    case MS_STATE_RINGING: return "ringing";
    case MS_STATE_LISTENING: return "listening";
  }
  return "unknown";
}

static void state_changed(ms_state state, void *user) {
  (void)user;
  printf("[state] %s\n", state_name(state));
}

static const char *reason_name(ms_end_reason reason) {
  switch (reason) {
    case MS_END_NONE: return "none";
    case MS_END_LOCAL_BYE: return "local_bye";
    case MS_END_REMOTE_BYE: return "remote_bye";
    case MS_END_REJECTED: return "rejected";
    case MS_END_TIMEOUT: return "timeout";
    case MS_END_ERROR: return "error";
  }
  return "unknown";
}

static int wait_established(ms_session *session, int timeout_ms) {
  long long deadline = now_ms() + timeout_ms;
  while (now_ms() < deadline) {
    (void)ms_poll(session, 20);
    if (ms_get_state(session) == MS_STATE_IN_CALL) return 0;
    if (ms_get_state(session) == MS_STATE_ENDED) return -1;
  }
  return -1;
}

static void drain(ms_session *session, int timeout_ms) {
  long long deadline = now_ms() + timeout_ms;
  while (now_ms() < deadline && ms_get_state(session) != MS_STATE_ENDED)
    (void)ms_poll(session, 20);
}

static ms_session *start_call(const char *host, int port, const char *mode) {
  ms_callbacks callbacks;
  ms_session *session;
  memset(&callbacks, 0, sizeof(callbacks));
  callbacks.pull_tx_audio = pull_tone;
  callbacks.on_rx_audio = receive_audio;
  callbacks.on_state = state_changed;
  session = ms_call(host, port, mode, &callbacks);
  if (session == NULL) {
    fprintf(stderr, "ms_call failed\n");
    return NULL;
  }
  if (wait_established(session, 15000) != 0) {
    fprintf(stderr, "call did not establish (reason=%s)\n",
            reason_name(ms_get_end_reason(session)));
    ms_free(session);
    return NULL;
  }
  return session;
}

static int run_call(const char *host, int port, const char *mode, int seconds) {
  ms_session *session;
  unsigned long tx = 0;
  unsigned long rx = 0;
  long long deadline;
  int passed;
  g_rx_samples = 0;
  session = start_call(host, port, mode);
  if (session == NULL) return 2;
  printf("[rtp] remote=%s\n", ms_get_remote_rtp(session));
  deadline = now_ms() + (long long)seconds * 1000;
  while (now_ms() < deadline && ms_get_state(session) == MS_STATE_IN_CALL)
    (void)ms_poll(session, 20);
  ms_get_stats(session, &tx, &rx);
  ms_hangup(session);
  drain(session, 2000);
  passed = strcmp(mode, "answer") == 0 ? (tx > 50 && rx > 50) : (rx > 50);
  printf("[stats] tx=%lu rx=%lu rx_samples=%lu\n", tx, rx, g_rx_samples);
  printf("[result] %s\n", passed ? "PASS" : "FAIL");
  ms_free(session);
  return passed ? 0 : 1;
}

static int run_dtmf(const char *host, int port, const char *digits) {
  ms_session *session = start_call(host, port, "answer");
  long long deadline;
  if (session == NULL) return 2;
  if (ms_send_dtmf(session, digits) != 0) {
    ms_free(session);
    return 1;
  }
  deadline = now_ms() + (long long)strlen(digits) * 250 + 1000;
  while (now_ms() < deadline && ms_get_state(session) == MS_STATE_IN_CALL)
    (void)ms_poll(session, 20);
  ms_hangup(session);
  drain(session, 2000);
  printf("[result] DTMF sent; verify the peer event log\n");
  ms_free(session);
  return 0;
}

int main(int argc, char **argv) {
  if (argc == 6 && strcmp(argv[1], "call") == 0)
    return run_call(argv[2], atoi(argv[3]), argv[4], atoi(argv[5]));
  if (argc == 5 && strcmp(argv[1], "dtmf") == 0)
    return run_dtmf(argv[2], atoi(argv[3]), argv[4]);
  fprintf(stderr,
          "usage:\n"
          "  %s call <host> <port> <monitor|answer> <seconds>\n"
          "  %s dtmf <host> <port> <digits>\n",
          argv[0], argv[0]);
  return 2;
}
