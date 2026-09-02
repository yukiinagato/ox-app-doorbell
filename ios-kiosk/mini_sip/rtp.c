
#include "minisip_priv.h"
#include "g711.h"

#include <arpa/inet.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>


static void put_rtp_header(unsigned char *b, int marker, int pt, uint16_t seq,
                           uint32_t ts, uint32_t ssrc) {
  b[0] = 0x80; /* V=2 */
  b[1] = (unsigned char)((marker ? 0x80 : 0x00) | (pt & 0x7f));
  b[2] = (unsigned char)(seq >> 8);
  b[3] = (unsigned char)(seq & 0xff);
  b[4] = (unsigned char)(ts >> 24);
  b[5] = (unsigned char)(ts >> 16);
  b[6] = (unsigned char)(ts >> 8);
  b[7] = (unsigned char)(ts & 0xff);
  b[8] = (unsigned char)(ssrc >> 24);
  b[9] = (unsigned char)(ssrc >> 16);
  b[10] = (unsigned char)(ssrc >> 8);
  b[11] = (unsigned char)(ssrc & 0xff);
}

static void send_rtp(ms_session *s, const unsigned char *pkt, int len) {
  if (!s->have_door_rtp) return;
  if (sendto(s->rtp_fd, pkt, (size_t)len, 0, (struct sockaddr *)&s->door_rtp,
             sizeof(s->door_rtp)) == len) {
    s->tx_pkts++;
  }
}


static void put_te_payload(unsigned char *p, int event, int end, int volume,
                           uint32_t duration) {
  p[0] = (unsigned char)(event & 0xff);
  p[1] = (unsigned char)((end ? 0x80 : 0x00) | (volume & 0x3f));
  p[2] = (unsigned char)((duration >> 8) & 0xff);
  p[3] = (unsigned char)(duration & 0xff);
}


int ms_dtmf_tick(ms_session *s) {
  unsigned char pkt[16];
  ms_dtmf_tx *d = &s->dtmf;
  int end;
  uint32_t dur;
  int marker;

  if (!d->active) {

    if (s->dtmf_qpos >= s->dtmf_qlen) return 0;
    d->event = s->dtmf_events[s->dtmf_qpos++];
    d->active = 1;
    d->pkts_sent = 0;

    d->total_pkts = 8;
    d->ts = s->tx_ts;
    if (s->dtmf_qpos >= s->dtmf_qlen) {

    }
  }

  marker = (d->pkts_sent == 0) ? 1 : 0;

  dur = (uint32_t)((d->pkts_sent + 1) * MS_FRAME);
  end = (d->pkts_sent >= d->total_pkts - 3) ? 1 : 0;

  put_rtp_header(pkt, marker, s->pt_te, s->tx_seq, d->ts, s->ssrc);
  put_te_payload(pkt + 12, d->event, end, 10, dur);
  send_rtp(s, pkt, 16);
  s->tx_seq++;

  s->tx_ts += MS_FRAME;
  d->pkts_sent++;

  if (d->pkts_sent >= d->total_pkts) {
    d->active = 0;

    if (s->dtmf_qpos >= s->dtmf_qlen) {
      s->dtmf_qlen = 0;
      s->dtmf_qpos = 0;
    }
  }
  return 1;
}


void ms_rtp_tick(ms_session *s) {
  unsigned char pkt[12 + MS_FRAME];
  int16_t pcm[MS_FRAME];
  int got = 0;
  int i;
  int marker;

  if (!s->have_door_rtp) return;


  if (ms_dtmf_tick(s)) return;


  if (s->cbs.pull_tx_audio) {
    got = s->cbs.pull_tx_audio(pcm, MS_FRAME, s->cbs.user);
    if (got < 0) got = 0;
    if (got > MS_FRAME) got = MS_FRAME;
  }

  marker = s->tx_started ? 0 : 1;
  s->tx_started = 1;
  put_rtp_header(pkt, marker, MS_PT_PCMU, s->tx_seq, s->tx_ts, s->ssrc);
  for (i = 0; i < MS_FRAME; i++) {
    if (i < got) {
      pkt[12 + i] = ms_linear2ulaw(pcm[i]);
    } else {
      pkt[12 + i] = MS_ULAW_SILENCE;
    }
  }
  send_rtp(s, pkt, 12 + MS_FRAME);
  s->tx_seq++;
  s->tx_ts += MS_FRAME;
}


void ms_rtp_recv(ms_session *s) {
  unsigned char buf[2048];
  int16_t pcm[2048];
  int n;
  int pt;
  int hdrlen;
  int payload;
  int i;

  for (;;) {
    n = (int)recvfrom(s->rtp_fd, buf, sizeof(buf), 0, NULL, NULL);
    if (n < 12) break;

    pt = buf[1] & 0x7f;

    hdrlen = 12 + (buf[0] & 0x0f) * 4;
    if (n <= hdrlen) continue;

    s->rx_pkts++;

    if (pt == MS_PT_PCMU) {
      payload = n - hdrlen;
      if (payload > (int)sizeof(pcm)) payload = (int)sizeof(pcm);
      if (s->cbs.on_rx_audio) {
        for (i = 0; i < payload; i++) pcm[i] = ms_ulaw2linear(buf[hdrlen + i]);
        s->cbs.on_rx_audio(pcm, payload, s->cbs.user);
      }
    }

  }
}
