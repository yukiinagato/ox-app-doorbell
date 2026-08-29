/* minisip.c — セッション生成・状態機・poll ループ (SIP/RTP を束ねる)。
 * 純 BSD ソケット + select。単一スレッド駆動。iOS5 armv7 互換 (C89/C99)。 */
#include "minisip_priv.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

/* ---- 時刻 ---- */
long long ms_now_ms(void) {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return (long long)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

/* ---- ソケット小物 ---- */
static void set_nonblock(int fd) {
  int fl = fcntl(fd, F_GETFL, 0);
  if (fl >= 0) fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

/* fd を bind し実ポートを返す (0 指定でエフェメラル)。失敗 -1。 */
static int bind_udp(int fd, int port) {
  struct sockaddr_in a;
  socklen_t al = sizeof(a);
  memset(&a, 0, sizeof(a));
  a.sin_family = AF_INET;
  a.sin_addr.s_addr = htonl(INADDR_ANY);
  a.sin_port = htons((unsigned short)port);
  if (bind(fd, (struct sockaddr *)&a, sizeof(a)) < 0) return -1;
  if (getsockname(fd, (struct sockaddr *)&a, &al) < 0) return -1;
  return ntohs(a.sin_port);
}

/* 門口 IP へ到達する自 IP を UDP connect の getsockname で得る。 */
static void discover_local_ip(const struct sockaddr_in *door, char *out, int outsz) {
  int fd = socket(AF_INET, SOCK_DGRAM, 0);
  struct sockaddr_in a;
  socklen_t al = sizeof(a);
  strncpy(out, "127.0.0.1", outsz - 1);
  out[outsz - 1] = '\0';
  if (fd < 0) return;
  if (connect(fd, (const struct sockaddr *)door, sizeof(*door)) == 0 &&
      getsockname(fd, (struct sockaddr *)&a, &al) == 0) {
    const char *ip = inet_ntoa(a.sin_addr);
    if (ip) {
      strncpy(out, ip, outsz - 1);
      out[outsz - 1] = '\0';
    }
  }
  close(fd);
}

/* ランダム十六進トークン (tag/call-id/ssrc 用)。 */
static void rand_hex(char *out, int sz, int nbytes) {
  static const char *H = "0123456789abcdef";
  int i;
  int o = 0;
  for (i = 0; i < nbytes && o < sz - 2; i++) {
    int v = rand() & 0xff;
    out[o++] = H[(v >> 4) & 0xf];
    out[o++] = H[v & 0xf];
  }
  out[o] = '\0';
}

/* ---- 状態遷移通知 ---- */
static void set_public_state(ms_session *s, ms_state st) {
  if (s->cbs.on_state) s->cbs.on_state(st, s->cbs.user);
}

/* ---- To ヘッダ等から ;tag= を抽出 ---- */
static void extract_tag(const char *hval, char *out, int outsz) {
  const char *p = strstr(hval, ";tag=");
  int o = 0;
  out[0] = '\0';
  if (!p) return;
  p += 5;
  while (*p && *p != ';' && *p != ' ' && *p != '\t' && *p != '>' && o < outsz - 1) {
    out[o++] = *p++;
  }
  out[o] = '\0';
}

/* ---- SIP 受信処理 ---- */
void ms_handle_sip(ms_session *s, const char *msg, int len) {
  int code = ms_status_code(msg, len);
  char method[32];

  if (code > 0) {
    /* ---- 応答 ---- */
    char to[256];
    if (ms_hdr(msg, len, "to", "t", to, sizeof(to))) {
      char tag[128];
      extract_tag(to, tag, sizeof(tag));
      if (tag[0]) {
        strncpy(s->to_tag, tag, sizeof(s->to_tag) - 1);
        s->to_tag[sizeof(s->to_tag) - 1] = '\0';
      }
    }

    /* CSeq メソッドで INVITE 応答か BYE 応答かを判別 */
    {
      char cseq[64];
      int is_bye = 0;
      if (ms_hdr(msg, len, "cseq", NULL, cseq, sizeof(cseq))) {
        if (strstr(cseq, "BYE")) is_bye = 1;
      }
      if (is_bye) {
        if (s->st == MS_ST_ENDING || s->st == MS_ST_IN_CALL) {
          s->st = MS_ST_ENDED;
          set_public_state(s, MS_STATE_ENDED);
        }
        return;
      }
    }

    if (code >= 100 && code < 200) {
      /* 暫定応答: INVITE 再送を止める (T1 タイマ無効化) */
      s->invite_next_retx_ms = s->call_deadline_ms; /* 実質停止 */
      return;
    }
    if (code >= 200 && code < 300) {
      if (s->st == MS_ST_CALLING) {
        /* SDP 本文を取り出し門口 RTP を確定 */
        const char *body = strstr(msg, "\r\n\r\n");
        int rc = -1;
        if (body) {
          body += 4;
          rc = ms_parse_answer(s, body, len - (int)(body - msg));
        }
        /* Contact を控える (in-dialog 宛先解析用。実送信は door_sip でも可) */
        ms_hdr(msg, len, "contact", "m", s->door_contact, sizeof(s->door_contact));
        ms_send_ack(s);
        if (rc == 0) {
          s->st = MS_ST_IN_CALL;
          s->next_rtp_ms = ms_now_ms();
          set_public_state(s, MS_STATE_IN_CALL);
        } else {
          /* SDP 不正 — 通話継続不能。BYE で畳む */
          s->end_reason = MS_END_ERROR;
          ms_send_bye(s);
          s->st = MS_ST_ENDING;
        }
      }
      return;
    }
    if (code >= 300) {
      /* INVITE 最終失敗 (486 通話中 等)。ACK は省略 (門口機が再送→タイムアウトで処理)。 */
      if (s->st == MS_ST_CALLING) {
        s->end_reason = MS_END_REJECTED;
        s->st = MS_ST_ENDED;
        set_public_state(s, MS_STATE_ENDED);
      }
      return;
    }
    return;
  }

  /* ---- 要求 (門口機発) ---- */
  if (!ms_req_method(msg, len, method, sizeof(method))) return;
  if (strcmp(method, "BYE") == 0) {
    ms_reply_ok(s, msg, len);
    if (s->st != MS_ST_ENDED) {
      s->end_reason = MS_END_REMOTE_BYE;
      s->st = MS_ST_ENDED;
      set_public_state(s, MS_STATE_ENDED);
    }
  } else if (strcmp(method, "OPTIONS") == 0 || strcmp(method, "INFO") == 0) {
    ms_reply_ok(s, msg, len); /* 礼儀的 200 */
  }
  /* その他 (re-INVITE 等) は無視 — 門口機は基本送ってこない */
}

/* ---- 生成 ---- */
ms_session *ms_call(const char *host, int port, const char *mode,
                    const ms_callbacks *cbs) {
  ms_session *s;
  int p;

  s = (ms_session *)calloc(1, sizeof(*s));
  if (!s) return NULL;
  s->sip_fd = s->rtp_fd = s->rtcp_fd = -1;
  if (cbs) s->cbs = *cbs;
  s->pt_te = MS_PT_TE_DEFAULT;

  srand((unsigned)(ms_now_ms() ^ (long long)(size_t)s));

  /* 門口 SIP アドレス */
  memset(&s->door_sip, 0, sizeof(s->door_sip));
  s->door_sip.sin_family = AF_INET;
  s->door_sip.sin_port = htons((unsigned short)port);
  s->door_sip.sin_addr.s_addr = inet_addr(host ? host : "127.0.0.1");
  if (s->door_sip.sin_addr.s_addr == INADDR_NONE) {
    free(s);
    return NULL;
  }

  discover_local_ip(&s->door_sip, s->local_ip, sizeof(s->local_ip));

  /* ソケット */
  s->sip_fd = socket(AF_INET, SOCK_DGRAM, 0);
  s->rtp_fd = socket(AF_INET, SOCK_DGRAM, 0);
  s->rtcp_fd = socket(AF_INET, SOCK_DGRAM, 0);
  if (s->sip_fd < 0 || s->rtp_fd < 0 || s->rtcp_fd < 0) {
    ms_free(s);
    return NULL;
  }
  p = bind_udp(s->sip_fd, 0);
  if (p < 0) {
    ms_free(s);
    return NULL;
  }
  s->local_sip_port = p;
  /* RTP は偶数ポート、RTCP は +1 を狙う。空きに任せて実測ポートを SDP に載せる。 */
  p = bind_udp(s->rtp_fd, 0);
  if (p < 0) {
    ms_free(s);
    return NULL;
  }
  s->local_rtp_port = p;
  bind_udp(s->rtcp_fd, s->local_rtp_port + 1); /* 失敗しても致命ではない */
  set_nonblock(s->sip_fd);
  set_nonblock(s->rtp_fd);
  set_nonblock(s->rtcp_fd);

  /* ダイアログ識別子 */
  {
    char a[24], b[24];
    rand_hex(a, sizeof(a), 8);
    rand_hex(b, sizeof(b), 4);
    snprintf(s->call_id, sizeof(s->call_id), "%s@%s", a, s->local_ip);
    snprintf(s->from_tag, sizeof(s->from_tag), "%s", b);
  }
  s->cseq = 1;
  {
    char sx[16];
    rand_hex(sx, sizeof(sx), 4);
    s->ssrc = (uint32_t)strtoul(sx, NULL, 16);
  }
  s->tx_seq = (uint16_t)(rand() & 0xffff);
  s->tx_ts = (uint32_t)rand();
  if (mode) {
    strncpy(s->mode, mode, sizeof(s->mode) - 1);
    s->mode[sizeof(s->mode) - 1] = '\0';
  }
  strncpy(s->remote_rtp_str, "0.0.0.0:0", sizeof(s->remote_rtp_str) - 1);

  /* INVITE 送信 → CALLING */
  s->start_ms = ms_now_ms();
  s->call_deadline_ms = s->start_ms + MS_CALL_TIMEOUT_MS;
  s->invite_retx_interval = MS_T1_MS;
  s->invite_next_retx_ms = s->start_ms + MS_T1_MS;
  if (ms_send_invite(s) != 0) {
    ms_free(s);
    return NULL;
  }
  s->st = MS_ST_CALLING;
  set_public_state(s, MS_STATE_CALLING);
  return s;
}

/* ---- poll ---- */
int ms_poll(ms_session *s, int timeout_ms) {
  fd_set rf;
  struct timeval tv;
  long long now;
  int maxfd;
  int wait_ms;
  long long next_event;

  if (!s) return -1;
  if (s->st == MS_ST_ENDED) return 1;

  now = ms_now_ms();

  /* 次に起こすべき時刻を決め、select の待ちを詰める */
  next_event = now + timeout_ms;
  if (s->st == MS_ST_CALLING) {
    if (s->invite_next_retx_ms < next_event) next_event = s->invite_next_retx_ms;
    if (s->call_deadline_ms < next_event) next_event = s->call_deadline_ms;
  } else if (s->st == MS_ST_IN_CALL) {
    if (s->next_rtp_ms < next_event) next_event = s->next_rtp_ms;
  } else if (s->st == MS_ST_ENDING) {
    if (s->call_deadline_ms < next_event) next_event = s->call_deadline_ms;
  }
  wait_ms = (int)(next_event - now);
  if (wait_ms < 0) wait_ms = 0;
  if (wait_ms > timeout_ms) wait_ms = timeout_ms;

  FD_ZERO(&rf);
  FD_SET(s->sip_fd, &rf);
  FD_SET(s->rtp_fd, &rf);
  FD_SET(s->rtcp_fd, &rf);
  maxfd = s->sip_fd;
  if (s->rtp_fd > maxfd) maxfd = s->rtp_fd;
  if (s->rtcp_fd > maxfd) maxfd = s->rtcp_fd;
  tv.tv_sec = wait_ms / 1000;
  tv.tv_usec = (wait_ms % 1000) * 1000;

  if (select(maxfd + 1, &rf, NULL, NULL, &tv) > 0) {
    if (FD_ISSET(s->sip_fd, &rf)) {
      char buf[MS_SIP_BUF];
      int n;
      /* 溜まっている SIP を全部処理 */
      for (;;) {
        n = (int)recvfrom(s->sip_fd, buf, sizeof(buf) - 1, 0, NULL, NULL);
        if (n <= 0) break;
        buf[n] = '\0';
        ms_handle_sip(s, buf, n);
        if (s->st == MS_ST_ENDED) return 1;
      }
    }
    if (FD_ISSET(s->rtp_fd, &rf)) ms_rtp_recv(s);
    if (FD_ISSET(s->rtcp_fd, &rf)) {
      char junk[512];
      while (recvfrom(s->rtcp_fd, junk, sizeof(junk), 0, NULL, NULL) > 0) {
      }
    }
  }

  now = ms_now_ms();

  /* タイマ処理 */
  if (s->st == MS_ST_CALLING) {
    if (now >= s->call_deadline_ms) {
      s->end_reason = MS_END_TIMEOUT;
      s->st = MS_ST_ENDED;
      set_public_state(s, MS_STATE_ENDED);
      return 1;
    }
    if (now >= s->invite_next_retx_ms) {
      ms_send_invite(s); /* 同一ヘッダで再送 */
      s->invite_retx_interval *= 2;
      if (s->invite_retx_interval > MS_T2_MS)
        s->invite_retx_interval = MS_T2_MS;
      s->invite_next_retx_ms = now + s->invite_retx_interval;
    }
  } else if (s->st == MS_ST_IN_CALL) {
    /* 20ms ごとに RTP 送出。取りこぼした分は追いつく (最大数フレーム) */
    int guard = 0;
    while (now >= s->next_rtp_ms && guard < 10) {
      ms_rtp_tick(s);
      s->next_rtp_ms += MS_PTIME_MS;
      guard++;
    }
    if (guard >= 10) s->next_rtp_ms = now + MS_PTIME_MS; /* 大幅遅延はリセット */
  } else if (s->st == MS_ST_ENDING) {
    /* BYE の 200 待ち。来なくても deadline で畳む */
    if (now >= s->call_deadline_ms) {
      s->st = MS_ST_ENDED;
      set_public_state(s, MS_STATE_ENDED);
      return 1;
    }
  }
  return (s->st == MS_ST_ENDED) ? 1 : 0;
}

/* ---- DTMF ---- */
int ms_send_dtmf(ms_session *s, const char *digits) {
  const char *p;
  if (!s || s->st != MS_ST_IN_CALL || !digits) return -1;
  for (p = digits; *p; p++) {
    int ev = -1;
    char c = *p;
    if (c >= '0' && c <= '9') ev = c - '0';
    else if (c == '*') ev = 10;
    else if (c == '#') ev = 11;
    else if (c >= 'A' && c <= 'D') ev = 12 + (c - 'A');
    else if (c >= 'a' && c <= 'd') ev = 12 + (c - 'a');
    else continue; /* 区切り等は無視 */
    if (s->dtmf_qlen < MS_DTMF_MAX) s->dtmf_events[s->dtmf_qlen++] = ev;
  }
  return 0;
}

/* ---- hangup ---- */
void ms_hangup(ms_session *s) {
  if (!s) return;
  if (s->st == MS_ST_IN_CALL) {
    s->end_reason = MS_END_LOCAL_BYE;
    ms_send_bye(s);
    s->st = MS_ST_ENDING;
    /* BYE 200 待ちは短めに (500ms) */
    s->call_deadline_ms = ms_now_ms() + 500;
  } else if (s->st == MS_ST_CALLING) {
    /* 確立前: CANCEL は簡略化のため送らず、ローカルに畳む */
    s->end_reason = MS_END_LOCAL_BYE;
    s->st = MS_ST_ENDED;
    set_public_state(s, MS_STATE_ENDED);
  }
}

/* ---- 破棄 ---- */
void ms_free(ms_session *s) {
  if (!s) return;
  if (s->st == MS_ST_IN_CALL) {
    ms_send_bye(s); /* ベストエフォート */
  }
  if (s->sip_fd >= 0) close(s->sip_fd);
  if (s->rtp_fd >= 0) close(s->rtp_fd);
  if (s->rtcp_fd >= 0) close(s->rtcp_fd);
  free(s);
}

/* ---- getters ---- */
ms_state ms_get_state(const ms_session *s) {
  if (!s) return MS_STATE_ENDED;
  switch (s->st) {
    case MS_ST_CALLING: return MS_STATE_CALLING;
    case MS_ST_IN_CALL: return MS_STATE_IN_CALL;
    case MS_ST_INIT: return MS_STATE_CALLING;
    default: return MS_STATE_ENDED;
  }
}

ms_end_reason ms_get_end_reason(const ms_session *s) {
  return s ? s->end_reason : MS_END_NONE;
}

void ms_get_stats(const ms_session *s, unsigned long *tx_pkts,
                  unsigned long *rx_pkts) {
  if (!s) return;
  if (tx_pkts) *tx_pkts = s->tx_pkts;
  if (rx_pkts) *rx_pkts = s->rx_pkts;
}

const char *ms_get_remote_rtp(const ms_session *s) {
  return s ? s->remote_rtp_str : "0.0.0.0:0";
}
