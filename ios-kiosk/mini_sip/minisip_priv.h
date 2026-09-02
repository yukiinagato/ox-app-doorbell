
#ifndef MINISIP_PRIV_H
#define MINISIP_PRIV_H

#include "minisip.h"

#include <netinet/in.h>
#include <stdint.h>

/* Internal MiniSIP state is owned by one poll thread. Socket and callback lifetimes end in
 * ms_free; no callback may retain pointers into this structure. */


typedef enum {
  MS_ST_INIT = 0,
  MS_ST_CALLING,
  MS_ST_ACCEPTING,
  MS_ST_IN_CALL,
  MS_ST_ENDING,
  MS_ST_ENDED
} ms_istate;

#define MS_PTIME_MS 20
#define MS_FRAME MS_SAMPLES_PER_FRAME
#define MS_PT_PCMU 0
#define MS_PT_TE_DEFAULT 101
#define MS_SIP_BUF 2048
#define MS_CALL_TIMEOUT_MS 32000
#define MS_T1_MS 500
#define MS_T2_MS 4000
#define MS_DTMF_MAX 16


typedef struct {
  int active;
  int event;
  int pkts_sent;     /* Packets sent for this event. */
  int total_pkts;    /* Total packets; the final packets carry the end bit. */
  uint32_t ts;       /* Shared RTP timestamp for the event. */
} ms_dtmf_tx;

struct ms_session {
  int sip_fd;   /* SIP UDP socket. */
  int rtp_fd;   /* RTP UDP socket. */
  int rtcp_fd;  /* RTCP UDP socket at RTP+1; received packets are discarded. */

  struct sockaddr_in door_sip; /* Peer SIP address. */
  struct sockaddr_in last_sip_from; /* Most recent datagram sender for UAS replies. */
  struct sockaddr_in door_rtp; /* Negotiated peer RTP target. */
  int have_door_rtp;

  char local_ip[64];  /* Local route address used by SDP, Contact, and Via. */
  int local_sip_port; /* Bound sip_fd port. */
  int local_rtp_port; /* Bound rtp_fd port. */

  /* Dialog identifiers. */
  char call_id[128];
  char from_tag[40];
  char to_tag[96];        /* Learned from 200 OK or an incoming request. */
  char invite_branch[64]; /* INVITE transaction branch. */
  char via_branch[64];    /* Latest outgoing request branch. */
  unsigned cseq;          /* INVITE CSeq; BYE uses the next value. */
  char mode[16];
  char door_contact[256]; /* Contact from 200 OK for in-dialog routing. */
  char last_sdp[1024];    /* Stable INVITE SDP reused by retransmissions. */

  /* The UAS listener keeps received dialog headers separate from UAC state so
   * response direction cannot be inverted. */
  int is_uas;
  char uas_via[256];
  char uas_from[256];
  char uas_to[256];
  char uas_contact[256];
  char uas_cseq[64];
  char uas_invite[MS_SIP_BUF];
  int uas_invite_len;


  uint32_t ssrc;
  uint16_t tx_seq;
  uint32_t tx_ts;
  int pt_te;
  int tx_started;


  long long start_ms;
  long long next_rtp_ms;
  long long invite_next_retx_ms;
  int invite_retx_interval;
  long long call_deadline_ms;

  ms_istate st;
  ms_end_reason end_reason;
  ms_callbacks cbs;

  unsigned long tx_pkts;
  unsigned long rx_pkts;


  int dtmf_events[MS_DTMF_MAX];
  int dtmf_qlen;
  int dtmf_qpos;
  ms_dtmf_tx dtmf;

  char remote_rtp_str[64];
};


long long ms_now_ms(void);



int ms_send_invite(ms_session *s);
int ms_send_ack(ms_session *s);
int ms_send_bye(ms_session *s);

int ms_reply_ok(ms_session *s, const char *req, int reqlen);
int ms_reply_status(ms_session *s, const char *req, int reqlen, int code,
                    const char *reason, const char *body);
int ms_send_uas_answer(ms_session *s, const char *req, int reqlen);


void ms_handle_sip(ms_session *s, const char *msg, int len);

/* ---- SDP (sdp.c) ---- */

int ms_build_offer(ms_session *s);

int ms_parse_answer(ms_session *s, const char *sdp, int len);

/* ---- RTP (rtp.c) ---- */

void ms_rtp_tick(ms_session *s);

void ms_rtp_recv(ms_session *s);

int ms_dtmf_tick(ms_session *s);



int ms_hdr(const char *msg, int len, const char *name, const char *cname, char *out,
           int outsz);

int ms_status_code(const char *msg, int len);

int ms_req_method(const char *msg, int len, char *out, int outsz);

#endif /* MINISIP_PRIV_H */
