
#include "minisip_priv.h"

#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>



static int ci_starts(const char *a, const char *b) {

  while (*b) {
    char ca = *a, cb = *b;
    if (ca >= 'A' && ca <= 'Z') ca = (char)(ca - 'A' + 'a');
    if (ca != cb) return 0;
    a++;
    b++;
  }
  return 1;
}


int ms_hdr(const char *msg, int len, const char *name, const char *cname, char *out,
           int outsz) {
  int i = 0;
  int nlen = (int)strlen(name);
  while (i < len) {
    const char *line = msg + i;
    int rem = len - i;
    int match = 0;
    if (rem > nlen && ci_starts(line, name)) {

      int j = nlen;
      while (j < rem && (line[j] == ' ' || line[j] == '\t')) j++;
      if (j < rem && line[j] == ':') match = j + 1;
    }
    if (!match && cname && rem > 1 &&
        (line[0] == cname[0] || line[0] == (cname[0] - 'a' + 'A'))) {
      int j = 1;
      while (j < rem && (line[j] == ' ' || line[j] == '\t')) j++;
      if (j < rem && line[j] == ':') match = j + 1;
    }
    if (match) {
      int k = match;
      int o = 0;
      while (k < rem && (line[k] == ' ' || line[k] == '\t')) k++;
      while (k < rem && line[k] != '\r' && line[k] != '\n' && o < outsz - 1) {
        out[o++] = line[k++];
      }
      out[o] = '\0';
      return 1;
    }

    while (i < len && msg[i] != '\n') i++;
    i++;

    if (i + 1 < len && (msg[i] == '\r' || msg[i] == '\n')) break;
  }
  return 0;
}

int ms_status_code(const char *msg, int len) {
  /* "SIP/2.0 200 OK" */
  if (len < 12) return 0;
  if (strncmp(msg, "SIP/2.0 ", 8) != 0) return 0;
  return atoi(msg + 8);
}

int ms_req_method(const char *msg, int len, char *out, int outsz) {
  int i = 0;
  if (len >= 8 && strncmp(msg, "SIP/2.0 ", 8) == 0) return 0;
  while (i < len && msg[i] != ' ' && i < outsz - 1) {
    out[i] = msg[i];
    i++;
  }
  out[i] = '\0';
  return i > 0;
}



static int send_sip(ms_session *s, const char *buf, int len) {
  int n = (int)sendto(s->sip_fd, buf, (size_t)len, 0,
                      (struct sockaddr *)&s->door_sip, sizeof(s->door_sip));
  return (n == len) ? 0 : -1;
}

static int send_sip_response(ms_session *s, const char *buf, int len) {
  const struct sockaddr_in *target = &s->door_sip;
  if (s->is_uas && s->last_sip_from.sin_port != 0) target = &s->last_sip_from;
  return sendto(s->sip_fd, buf, (size_t)len, 0, (const struct sockaddr *)target,
                sizeof(*target)) == len ? 0 : -1;
}


static void gen_branch(char *out, int sz) {
  static unsigned ctr = 0;
  ctr++;
  snprintf(out, sz, "z9hG4bK%08lx%04x", (unsigned long)(ms_now_ms() & 0xffffffff),
           ctr & 0xffff);
}

/* ---- INVITE ---- */

int ms_send_invite(ms_session *s) {
  char buf[MS_SIP_BUF];
  int sdplen;
  int n;
  const char *door_ip = inet_ntoa(s->door_sip.sin_addr);
  int door_port = ntohs(s->door_sip.sin_port);
  char modehdr[64];

  sdplen = ms_build_offer(s);
  if (sdplen < 0) return -1;


  if (s->invite_branch[0] == '\0') {
    gen_branch(s->invite_branch, sizeof(s->invite_branch));
  }
  strncpy(s->via_branch, s->invite_branch, sizeof(s->via_branch) - 1);

  modehdr[0] = '\0';
  if (s->mode[0] != '\0') {
    snprintf(modehdr, sizeof(modehdr), "X-Doorbell-Mode: %s\r\n", s->mode);
  }

  n = snprintf(
      buf, sizeof(buf),
      "INVITE sip:door@%s:%d SIP/2.0\r\n"
      "Via: SIP/2.0/UDP %s:%d;rport;branch=%s\r\n"
      "Max-Forwards: 70\r\n"
      "From: <sip:doorbell@%s:%d>;tag=%s\r\n"
      "To: <sip:door@%s:%d>\r\n"
      "Call-ID: %s\r\n"
      "CSeq: %u INVITE\r\n"
      "Contact: <sip:doorbell@%s:%d>\r\n"
      "%s"
      "User-Agent: doorbell-minisip/1.0\r\n"
      "Content-Type: application/sdp\r\n"
      "Content-Length: %d\r\n"
      "\r\n"
      "%s",
      door_ip, door_port, s->local_ip, s->local_sip_port, s->via_branch,
      s->local_ip, s->local_sip_port, s->from_tag, door_ip, door_port,
      s->call_id, s->cseq, s->local_ip, s->local_sip_port, modehdr, sdplen,
      s->last_sdp);
  if (n < 0 || n >= (int)sizeof(buf)) return -1;
  return send_sip(s, buf, n);
}



int ms_send_ack(ms_session *s) {
  char buf[MS_SIP_BUF];
  int n;
  char abranch[64];
  const char *door_ip = inet_ntoa(s->door_sip.sin_addr);
  int door_port = ntohs(s->door_sip.sin_port);
  char totag[128];

  gen_branch(abranch, sizeof(abranch));
  strncpy(s->via_branch, abranch, sizeof(s->via_branch) - 1);
  totag[0] = '\0';
  if (s->to_tag[0]) snprintf(totag, sizeof(totag), ";tag=%s", s->to_tag);

  n = snprintf(buf, sizeof(buf),
               "ACK sip:door@%s:%d SIP/2.0\r\n"
               "Via: SIP/2.0/UDP %s:%d;rport;branch=%s\r\n"
               "Max-Forwards: 70\r\n"
               "From: <sip:doorbell@%s:%d>;tag=%s\r\n"
               "To: <sip:door@%s:%d>%s\r\n"
               "Call-ID: %s\r\n"
               "CSeq: %u ACK\r\n"
               "Content-Length: 0\r\n"
               "\r\n",
               door_ip, door_port, s->local_ip, s->local_sip_port, abranch,
               s->local_ip, s->local_sip_port, s->from_tag, door_ip, door_port,
               totag, s->call_id, s->cseq);
  if (n < 0 || n >= (int)sizeof(buf)) return -1;
  return send_sip(s, buf, n);
}



int ms_send_bye(ms_session *s) {
  char buf[MS_SIP_BUF];
  int n;
  char bbranch[64];
  const char *door_ip = inet_ntoa(s->door_sip.sin_addr);
  int door_port = ntohs(s->door_sip.sin_port);
  char totag[128];

  gen_branch(bbranch, sizeof(bbranch));
  strncpy(s->via_branch, bbranch, sizeof(s->via_branch) - 1);
  totag[0] = '\0';
  if (s->to_tag[0]) snprintf(totag, sizeof(totag), ";tag=%s", s->to_tag);

  if (s->is_uas) {
    char local_to[320];
    if (strstr(s->uas_to, ";tag=") != NULL)
      snprintf(local_to, sizeof(local_to), "%s", s->uas_to);
    else
      snprintf(local_to, sizeof(local_to), "%s;tag=%s", s->uas_to, s->to_tag);
    n = snprintf(buf, sizeof(buf),
                 "BYE sip:doorbell@%s:%d SIP/2.0\r\n"
                 "Via: SIP/2.0/UDP %s:%d;rport;branch=%s\r\n"
                 "Max-Forwards: 70\r\n"
                 "From: %s\r\n"
                 "To: %s\r\n"
                 "Call-ID: %s\r\n"
                 "CSeq: %u BYE\r\n"
                 "Content-Length: 0\r\n\r\n",
                 door_ip, door_port, s->local_ip, s->local_sip_port, bbranch,
                 local_to, s->uas_from, s->call_id, s->cseq + 1);
  } else {
    n = snprintf(buf, sizeof(buf),
               "BYE sip:door@%s:%d SIP/2.0\r\n"
               "Via: SIP/2.0/UDP %s:%d;rport;branch=%s\r\n"
               "Max-Forwards: 70\r\n"
               "From: <sip:doorbell@%s:%d>;tag=%s\r\n"
               "To: <sip:door@%s:%d>%s\r\n"
               "Call-ID: %s\r\n"
               "CSeq: %u BYE\r\n"
               "Content-Length: 0\r\n"
               "\r\n",
               door_ip, door_port, s->local_ip, s->local_sip_port, bbranch,
               s->local_ip, s->local_sip_port, s->from_tag, door_ip, door_port,
               totag, s->call_id, s->cseq + 1);
  }
  if (n < 0 || n >= (int)sizeof(buf)) return -1;
  return send_sip(s, buf, n);
}



int ms_reply_ok(ms_session *s, const char *req, int reqlen) {
  return ms_reply_status(s, req, reqlen, 200, "OK", NULL);
}

int ms_reply_status(ms_session *s, const char *req, int reqlen, int code,
                    const char *reason, const char *body) {
  char buf[MS_SIP_BUF];
  char via[256], from[256], to[256], callid[128], cseq[64];
  char tagged_to[320];
  char contact[160];
  char content_type[64];
  int n;
  int body_len = body ? (int)strlen(body) : 0;

  if (!ms_hdr(req, reqlen, "via", "v", via, sizeof(via))) return -1;
  if (!ms_hdr(req, reqlen, "from", "f", from, sizeof(from))) return -1;
  if (!ms_hdr(req, reqlen, "to", "t", to, sizeof(to))) return -1;
  if (!ms_hdr(req, reqlen, "call-id", "i", callid, sizeof(callid))) return -1;
  if (!ms_hdr(req, reqlen, "cseq", NULL, cseq, sizeof(cseq))) return -1;

  snprintf(tagged_to, sizeof(tagged_to), "%s", to);
  if (s->is_uas && code > 100 && s->to_tag[0] && strstr(to, ";tag=") == NULL)
    snprintf(tagged_to, sizeof(tagged_to), "%s;tag=%s", to, s->to_tag);
  contact[0] = '\0';
  content_type[0] = '\0';
  if (body_len > 0) {
    snprintf(contact, sizeof(contact), "Contact: <sip:door@%s:%d>\r\n",
             s->local_ip, s->local_sip_port);
    snprintf(content_type, sizeof(content_type), "Content-Type: application/sdp\r\n");
  }

  n = snprintf(buf, sizeof(buf),
               "SIP/2.0 %d %s\r\n"
               "Via: %s\r\n"
               "From: %s\r\n"
               "To: %s\r\n"
               "Call-ID: %s\r\n"
               "CSeq: %s\r\n"
               "%s%s"
               "Content-Length: %d\r\n"
               "\r\n%s",
               code, reason ? reason : "", via, from, tagged_to, callid, cseq,
               contact, content_type, body_len, body ? body : "");
  if (n < 0 || n >= (int)sizeof(buf)) return -1;
  return send_sip_response(s, buf, n);
}

int ms_send_uas_answer(ms_session *s, const char *req, int reqlen) {
  if (!s || !s->is_uas) return -1;
  if (ms_build_offer(s) < 0) return -1;
  if (ms_reply_status(s, req, reqlen, 100, "Trying", NULL) != 0) return -1;
  return ms_reply_status(s, req, reqlen, 200, "OK", s->last_sdp);
}
