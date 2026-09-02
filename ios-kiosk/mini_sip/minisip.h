
#ifndef MINISIP_H
#define MINISIP_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Call state reported through the state callback. */
typedef enum {
  MS_STATE_CALLING = 0, /* INVITE sent; waiting for 200 OK. */
  MS_STATE_IN_CALL = 1, /* 200 OK received, ACK sent, and RTP active. */
  MS_STATE_ENDED = 2,   /* BYE completed, failure, or timeout. */
  MS_STATE_RINGING = 3, /* UAS received INVITE; waiting for ACK after 200 OK. */
  MS_STATE_LISTENING = 4 /* UAS is listening on its direct port. */
} ms_state;

/* Termination reason returned by ms_get_end_reason. */
typedef enum {
  MS_END_NONE = 0,
  MS_END_LOCAL_BYE,   /* Local ms_hangup. */
  MS_END_REMOTE_BYE,  /* Remote BYE. */
  MS_END_REJECTED,    /* Final 4xx/5xx/6xx response, such as 486 Busy. */
  MS_END_TIMEOUT,     /* Not established within 32 seconds. */
  MS_END_ERROR        /* Fatal socket or protocol error. */
} ms_end_reason;

/* 20 ms at 8 kHz is 160 samples per packet and callback. */
#define MS_SAMPLES_PER_FRAME 160

/* Platform callbacks run only on the thread that calls ms_poll. Fields may be NULL. */
typedef struct {
  /* Decoded signed-linear receive audio, with n samples. */
  void (*on_rx_audio)(const int16_t *pcm, int n, void *user);

  /* Writes up to n transmit samples and returns the count. Zero sends PCMU silence. */
  int (*pull_tx_audio)(int16_t *pcm, int n, void *user);

  /* State transition notification. */
  void (*on_state)(ms_state st, void *user);

  /* Opaque value forwarded to every callback. */
  void *user;
} ms_callbacks;

typedef struct ms_session ms_session;

/* Starts a direct call. host is the peer IP, port is normally 47190, and mode is
 * "monitor", "answer", or empty. Callbacks are copied and may be NULL. The
 * returned session starts in CALLING and is driven by repeated ms_poll calls. */
ms_session *ms_call(const char *host, int port, const char *mode,
                    const ms_callbacks *cbs);

/* Starts a direct-call UAS on the UDP port, normally 47190. It automatically
 * answers PCMU INVITEs and supports one call per listener. Free and recreate
 * the listener after a call ends. REGISTER and PBX operation are out of scope. */
ms_session *ms_listen(int port, const ms_callbacks *cbs);

/* Pumps signaling and RTP once. The timeout is shortened to the next RTP send
 * deadline. Returns 0 while active, 1 at ENDED, or a negative fatal error. */
int ms_poll(ms_session *s, int timeout_ms);

/* Queues RFC 2833 DTMF digits (0-9, *, #, A-D) for ms_poll to transmit. */
int ms_send_dtmf(ms_session *s, const char *digits);

/* Sends BYE and ends the call. Subsequent ms_poll calls return 1. */
void ms_hangup(ms_session *s);

/* Closes sockets and frees the session, attempting BYE when necessary. */
void ms_free(ms_session *s);

/* Returns the current state. */
ms_state ms_get_state(const ms_session *s);

/* Returns the termination reason after ENDED. */
ms_end_reason ms_get_end_reason(const ms_session *s);

/* Returns measured RTP packet counts. Either output may be NULL. */
void ms_get_stats(const ms_session *s, unsigned long *tx_pkts,
                  unsigned long *rx_pkts);

/* Returns the negotiated RTP target, or "0.0.0.0:0" before negotiation. */
const char *ms_get_remote_rtp(const ms_session *s);

/* Returns the X-Doorbell-Mode received by the UAS. */
const char *ms_get_mode(const ms_session *s);

/* Returns 1 for a session created by ms_listen. */
int ms_is_listener(const ms_session *s);

#ifdef __cplusplus
}
#endif

#endif /* MINISIP_H */
