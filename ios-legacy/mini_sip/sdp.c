/* sdp.c — 最小 SDP。オファー生成 (PCMU + telephone-event) とアンサー解析。
 * 門口機 (pjsua) は PCMU/8000 のみ有効化しているので、こちらもそれだけ提示する。 */
#include "minisip_priv.h"

#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* オファー SDP を s->last_sdp に生成。全経路 8kHz、payload 0 = PCMU、
 * 101 = telephone-event (RFC2833 DTMF)。direction は sendrecv 固定
 * (一方向/双方向は門口機側が X-Doorbell-Mode で conf 配線を決めるため、
 *  SDP では両方向を提示しておくのが素直で相互運用しやすい)。 */
int ms_build_offer(ms_session *s) {
  int n;
  /* セッション ID / バージョンは now_ms 由来で十分 (一意性のみ要求) */
  unsigned long sess = (unsigned long)(ms_now_ms() & 0x7fffffff);
  n = snprintf(s->last_sdp, sizeof(s->last_sdp),
               "v=0\r\n"
               "o=- %lu %lu IN IP4 %s\r\n"
               "s=doorbell-minisip\r\n"
               "c=IN IP4 %s\r\n"
               "t=0 0\r\n"
               "m=audio %d RTP/AVP 0 %d\r\n"
               "a=rtpmap:0 PCMU/8000\r\n"
               "a=rtpmap:%d telephone-event/8000\r\n"
               "a=fmtp:%d 0-16\r\n"
               "a=ptime:20\r\n"
               "a=sendrecv\r\n",
               sess, sess, s->local_ip, s->local_ip, s->local_rtp_port,
               MS_PT_TE_DEFAULT, MS_PT_TE_DEFAULT, MS_PT_TE_DEFAULT);
  if (n < 0 || n >= (int)sizeof(s->last_sdp)) return -1;
  return n;
}

/* 行頭が prefix で始まる最初の行の、prefix 直後へのポインタを返す。無ければ NULL。
 * len 制限内で走査 (SDP 本文は NUL 終端でないことがある)。 */
static const char *find_line(const char *sdp, int len, const char *prefix) {
  int plen = (int)strlen(prefix);
  int i = 0;
  while (i < len) {
    /* 行頭判定 */
    if (i + plen <= len && strncmp(sdp + i, prefix, plen) == 0) {
      return sdp + i + plen;
    }
    /* 次行へ */
    while (i < len && sdp[i] != '\n') i++;
    i++;
  }
  return NULL;
}

/* アンサー解析: m=audio の port、c= の IP、telephone-event の PT を取り、
 * PCMU(0) が提示されていることを確認する。 */
int ms_parse_answer(ms_session *s, const char *sdp, int len) {
  const char *p;
  char ip[64];
  int port = 0;
  int i;
  int has_pcmu = 0;

  /* c=IN IP4 <ip> (セッションまたはメディアレベル。最初の 1 本を採用) */
  p = find_line(sdp, len, "c=IN IP4 ");
  if (!p) return -1;
  i = 0;
  while (p < sdp + len && *p != '\r' && *p != '\n' && i < (int)sizeof(ip) - 1) {
    ip[i++] = *p++;
  }
  ip[i] = '\0';

  /* m=audio <port> RTP/AVP <pts...> */
  p = find_line(sdp, len, "m=audio ");
  if (!p) return -1;
  port = atoi(p);
  if (port <= 0) return -1;

  /* PCMU 提示確認: rtpmap:0 PCMU か、m= 行の payload に 0 が含まれる */
  if (find_line(sdp, len, "a=rtpmap:0 PCMU") != NULL) has_pcmu = 1;
  if (!has_pcmu) {
    /* m= 行の payload list を粗く確認 */
    const char *q = p;
    /* p は "audio <port> RTP/AVP ..." の port 直後付近。RTP/AVP まで飛ばす */
    while (q < sdp + len && *q != '\r' && *q != '\n') {
      if (q[0] == ' ' && q[1] == '0' &&
          (q[2] == ' ' || q[2] == '\r' || q[2] == '\n')) {
        has_pcmu = 1;
        break;
      }
      q++;
    }
  }
  if (!has_pcmu) return -2; /* PCMU が無い = 想定外 */

  /* telephone-event の PT (a=rtpmap:<pt> telephone-event) */
  s->pt_te = MS_PT_TE_DEFAULT;
  {
    /* "a=rtpmap:" を総なめして telephone-event を含む行の PT を拾う */
    int j = 0;
    while (j < len) {
      if (j + 9 <= len && strncmp(sdp + j, "a=rtpmap:", 9) == 0) {
        const char *v = sdp + j + 9;
        int pt = atoi(v);
        const char *nl = v;
        int k = j + 9;
        while (k < len && sdp[k] != '\n') k++;
        /* この行に telephone-event があるか */
        {
          int seg = k - (j + 9);
          const char *hay = v;
          int m;
          for (m = 0; m + 15 <= seg; m++) {
            if (strncmp(hay + m, "telephone-event", 15) == 0) {
              if (pt > 0) s->pt_te = pt;
              break;
            }
          }
        }
        (void)nl;
      }
      while (j < len && sdp[j] != '\n') j++;
      j++;
    }
  }

  /* door_rtp を設定 */
  memset(&s->door_rtp, 0, sizeof(s->door_rtp));
  s->door_rtp.sin_family = AF_INET;
  s->door_rtp.sin_port = htons((unsigned short)port);
  s->door_rtp.sin_addr.s_addr = inet_addr(ip);
  s->have_door_rtp = 1;
  snprintf(s->remote_rtp_str, sizeof(s->remote_rtp_str), "%s:%d", ip, port);
  return 0;
}
