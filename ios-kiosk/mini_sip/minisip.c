
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


long long ms_now_ms(void) {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return (long long)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}


static void set_nonblock(int fd) {
  int fl = fcntl(fd, F_GETFL, 0);
  if (fl >= 0) fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}


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


static void set_public_state(ms_session *s, ms_state st) {
  if (s->cbs.on_state) s->cbs.on_state(st, s->cbs.user);
}


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

static int same_call_id(ms_session *s, const char *msg, int len) {
  char value[128];
  if (!ms_hdr(msg, len, "call-id", "i", value, sizeof(value))) return 0;
  return s->call_id[0] != '\0' && strcmp(value, s->call_id) == 0;
}

static void copy_header(ms_session *s, const char *msg, int len, const char *name,
                        const char *compact, char *out, int outsz) {
  (void)s;
  out[0] = '\0';
  ms_hdr(msg, len, name, compact, out, outsz);
}

static void handle_uas_invite(ms_session *s, const char *msg, int len) {
  const char *body;
  char callid[128];
  char mode[32];
  int rc;

  if (!ms_hdr(msg, len, "call-id", "i", callid, sizeof(callid))) {
    ms_reply_status(s, msg, len, 400, "Bad Request", NULL);
    return;
  }
  if (s->st != MS_ST_INIT) {
    if (strcmp(callid, s->call_id) == 0) {
      /* UDP INVITE retransmission or a minimal re-INVITE. Return the same SDP. */
      ms_reply_status(s, msg, len, 200, "OK", s->last_sdp);
    } else {
      ms_reply_status(s, msg, len, 486, "Busy Here", NULL);
    }
    return;
  }

  s->door_sip = s->last_sip_from;
  discover_local_ip(&s->door_sip, s->local_ip, sizeof(s->local_ip));
  strncpy(s->call_id, callid, sizeof(s->call_id) - 1);
  s->call_id[sizeof(s->call_id) - 1] = '\0';
  copy_header(s, msg, len, "via", "v", s->uas_via, sizeof(s->uas_via));
  copy_header(s, msg, len, "from", "f", s->uas_from, sizeof(s->uas_from));
  copy_header(s, msg, len, "to", "t", s->uas_to, sizeof(s->uas_to));
  copy_header(s, msg, len, "contact", "m", s->uas_contact, sizeof(s->uas_contact));
  copy_header(s, msg, len, "cseq", NULL, s->uas_cseq, sizeof(s->uas_cseq));
  s->cseq = (unsigned)atoi(s->uas_cseq);
  mode[0] = '\0';
  ms_hdr(msg, len, "x-doorbell-mode", NULL, mode, sizeof(mode));
  strncpy(s->mode, mode, sizeof(s->mode) - 1);
  s->mode[sizeof(s->mode) - 1] = '\0';
  s->uas_invite_len = len < MS_SIP_BUF - 1 ? len : MS_SIP_BUF - 1;
  memcpy(s->uas_invite, msg, (size_t)s->uas_invite_len);
  s->uas_invite[s->uas_invite_len] = '\0';

  body = strstr(msg, "\r\n\r\n");
  rc = -1;
  if (body) {
    body += 4;
    rc = ms_parse_answer(s, body, len - (int)(body - msg));
  }
  if (rc != 0) {
    ms_reply_status(s, msg, len, 488, "Not Acceptable Here", NULL);
    s->call_id[0] = '\0';
    return;
  }
  if (ms_send_uas_answer(s, msg, len) != 0) {
    s->end_reason = MS_END_ERROR;
    s->st = MS_ST_ENDED;
    set_public_state(s, MS_STATE_ENDED);
    return;
  }
  s->st = MS_ST_ACCEPTING;
  s->start_ms = ms_now_ms();
  s->call_deadline_ms = s->start_ms + MS_CALL_TIMEOUT_MS;
  set_public_state(s, MS_STATE_RINGING);
}


void ms_handle_sip(ms_session *s, const char *msg, int len) {
  int code = ms_status_code(msg, len);
  char method[32];

  if (code > 0) {

    char to[256];
    if (!s->is_uas && ms_hdr(msg, len, "to", "t", to, sizeof(to))) {
      char tag[128];
      extract_tag(to, tag, sizeof(tag));
      if (tag[0]) {
        strncpy(s->to_tag, tag, sizeof(s->to_tag) - 1);
        s->to_tag[sizeof(s->to_tag) - 1] = '\0';
      }
    }


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

      s->invite_next_retx_ms = s->call_deadline_ms;
      return;
    }
    if (code >= 200 && code < 300) {
      if (s->st == MS_ST_CALLING) {

        const char *body = strstr(msg, "\r\n\r\n");
        int rc = -1;
        if (body) {
          body += 4;
          rc = ms_parse_answer(s, body, len - (int)(body - msg));
        }

        ms_hdr(msg, len, "contact", "m", s->door_contact, sizeof(s->door_contact));
        ms_send_ack(s);
        if (rc == 0) {
          s->st = MS_ST_IN_CALL;
          s->next_rtp_ms = ms_now_ms();
          set_public_state(s, MS_STATE_IN_CALL);
        } else {

          s->end_reason = MS_END_ERROR;
          ms_send_bye(s);
          s->st = MS_ST_ENDING;
        }
      }
      return;
    }
    if (code >= 300) {

      if (s->st == MS_ST_CALLING) {
        s->end_reason = MS_END_REJECTED;
        s->st = MS_ST_ENDED;
        set_public_state(s, MS_STATE_ENDED);
      }
      return;
    }
    return;
  }


  if (!ms_req_method(msg, len, method, sizeof(method))) return;
  if (strcmp(method, "INVITE") == 0 && s->is_uas) {
    handle_uas_invite(s, msg, len);
  } else if (strcmp(method, "ACK") == 0 && s->is_uas) {
    if (s->st == MS_ST_ACCEPTING && same_call_id(s, msg, len)) {
      s->st = MS_ST_IN_CALL;
      s->next_rtp_ms = ms_now_ms();
      set_public_state(s, MS_STATE_IN_CALL);
    }
  } else if (strcmp(method, "CANCEL") == 0 && s->is_uas) {
    if (s->st == MS_ST_ACCEPTING && same_call_id(s, msg, len)) {
      ms_reply_ok(s, msg, len);
      ms_reply_status(s, s->uas_invite, s->uas_invite_len, 487,
                      "Request Terminated", NULL);
      s->end_reason = MS_END_REMOTE_BYE;
      s->st = MS_ST_ENDED;
      set_public_state(s, MS_STATE_ENDED);
    } else {
      ms_reply_status(s, msg, len, 481, "Call/Transaction Does Not Exist", NULL);
    }
  } else if (strcmp(method, "BYE") == 0) {
    if (!same_call_id(s, msg, len)) {
      ms_reply_status(s, msg, len, 481, "Call/Transaction Does Not Exist", NULL);
    } else {
      ms_reply_ok(s, msg, len);
      s->end_reason = MS_END_REMOTE_BYE;
      s->st = MS_ST_ENDED;
      set_public_state(s, MS_STATE_ENDED);
    }
  } else if (strcmp(method, "OPTIONS") == 0) {
    ms_reply_ok(s, msg, len);
  } else if (strcmp(method, "INFO") == 0) {
    if (same_call_id(s, msg, len))
      ms_reply_ok(s, msg, len);
    else
      ms_reply_status(s, msg, len, 481, "Call/Transaction Does Not Exist", NULL);
  }

}


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


  memset(&s->door_sip, 0, sizeof(s->door_sip));
  s->door_sip.sin_family = AF_INET;
  s->door_sip.sin_port = htons((unsigned short)port);
  s->door_sip.sin_addr.s_addr = inet_addr(host ? host : "127.0.0.1");
  if (s->door_sip.sin_addr.s_addr == INADDR_NONE) {
    free(s);
    return NULL;
  }

  discover_local_ip(&s->door_sip, s->local_ip, sizeof(s->local_ip));


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

  p = bind_udp(s->rtp_fd, 0);
  if (p < 0) {
    ms_free(s);
    return NULL;
  }
  s->local_rtp_port = p;
  bind_udp(s->rtcp_fd, s->local_rtp_port + 1);
  set_nonblock(s->sip_fd);
  set_nonblock(s->rtp_fd);
  set_nonblock(s->rtcp_fd);


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

ms_session *ms_listen(int port, const ms_callbacks *cbs) {
  ms_session *s;
  int p;
  int reuse = 1;
  char token[24];

  if (port <= 0 || port > 65535) return NULL;
  s = (ms_session *)calloc(1, sizeof(*s));
  if (!s) return NULL;
  s->sip_fd = s->rtp_fd = s->rtcp_fd = -1;
  s->is_uas = 1;
  if (cbs) s->cbs = *cbs;
  s->pt_te = MS_PT_TE_DEFAULT;
  strncpy(s->local_ip, "0.0.0.0", sizeof(s->local_ip) - 1);
  strncpy(s->remote_rtp_str, "0.0.0.0:0", sizeof(s->remote_rtp_str) - 1);
  srand((unsigned)(ms_now_ms() ^ (long long)(size_t)s));

  s->sip_fd = socket(AF_INET, SOCK_DGRAM, 0);
  s->rtp_fd = socket(AF_INET, SOCK_DGRAM, 0);
  s->rtcp_fd = socket(AF_INET, SOCK_DGRAM, 0);
  if (s->sip_fd < 0 || s->rtp_fd < 0 || s->rtcp_fd < 0) {
    ms_free(s);
    return NULL;
  }
  setsockopt(s->sip_fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
  p = bind_udp(s->sip_fd, port);
  if (p < 0) {
    ms_free(s);
    return NULL;
  }
  s->local_sip_port = p;
  p = bind_udp(s->rtp_fd, 0);
  if (p < 0) {
    ms_free(s);
    return NULL;
  }
  s->local_rtp_port = p;
  bind_udp(s->rtcp_fd, s->local_rtp_port + 1);
  set_nonblock(s->sip_fd);
  set_nonblock(s->rtp_fd);
  set_nonblock(s->rtcp_fd);

  rand_hex(token, sizeof(token), 8);
  snprintf(s->to_tag, sizeof(s->to_tag), "%s", token);
  rand_hex(token, sizeof(token), 4);
  s->ssrc = (uint32_t)strtoul(token, NULL, 16);
  s->tx_seq = (uint16_t)(rand() & 0xffff);
  s->tx_ts = (uint32_t)rand();
  s->st = MS_ST_INIT;
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

      for (;;) {
        {
          socklen_t from_len = sizeof(s->last_sip_from);
          memset(&s->last_sip_from, 0, sizeof(s->last_sip_from));
          n = (int)recvfrom(s->sip_fd, buf, sizeof(buf) - 1, 0,
                            (struct sockaddr *)&s->last_sip_from, &from_len);
        }
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


  if (s->st == MS_ST_CALLING) {
    if (now >= s->call_deadline_ms) {
      s->end_reason = MS_END_TIMEOUT;
      s->st = MS_ST_ENDED;
      set_public_state(s, MS_STATE_ENDED);
      return 1;
    }
    if (now >= s->invite_next_retx_ms) {
      ms_send_invite(s);
      s->invite_retx_interval *= 2;
      if (s->invite_retx_interval > MS_T2_MS)
        s->invite_retx_interval = MS_T2_MS;
      s->invite_next_retx_ms = now + s->invite_retx_interval;
    }
  } else if (s->st == MS_ST_ACCEPTING) {
    if (now >= s->call_deadline_ms) {
      s->end_reason = MS_END_TIMEOUT;
      s->st = MS_ST_ENDED;
      set_public_state(s, MS_STATE_ENDED);
      return 1;
    }
  } else if (s->st == MS_ST_IN_CALL) {

    int guard = 0;
    while (now >= s->next_rtp_ms && guard < 10) {
      ms_rtp_tick(s);
      s->next_rtp_ms += MS_PTIME_MS;
      guard++;
    }
    if (guard >= 10) s->next_rtp_ms = now + MS_PTIME_MS;
  } else if (s->st == MS_ST_ENDING) {

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
    else continue;
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

    s->call_deadline_ms = ms_now_ms() + 500;
  } else if (s->st == MS_ST_ACCEPTING) {
    if (s->uas_invite_len > 0)
      ms_reply_status(s, s->uas_invite, s->uas_invite_len, 487,
                      "Request Terminated", NULL);
    s->end_reason = MS_END_LOCAL_BYE;
    s->st = MS_ST_ENDED;
    set_public_state(s, MS_STATE_ENDED);
  } else if (s->st == MS_ST_CALLING || s->st == MS_ST_INIT) {

    s->end_reason = MS_END_LOCAL_BYE;
    s->st = MS_ST_ENDED;
    set_public_state(s, MS_STATE_ENDED);
  }
}


void ms_free(ms_session *s) {
  if (!s) return;
  if (s->st == MS_ST_IN_CALL) {
    ms_send_bye(s);
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
    case MS_ST_ACCEPTING: return MS_STATE_RINGING;
    case MS_ST_IN_CALL: return MS_STATE_IN_CALL;
    case MS_ST_INIT: return s->is_uas ? MS_STATE_LISTENING : MS_STATE_CALLING;
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

const char *ms_get_mode(const ms_session *s) {
  return s ? s->mode : "";
}

int ms_is_listener(const ms_session *s) {
  return s ? s->is_uas : 0;
}
