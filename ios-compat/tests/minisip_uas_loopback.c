#include "minisip.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

static unsigned g_state_mask;

static void on_state(ms_state state, void *user) {
  (void)user;
  g_state_mask |= 1u << (unsigned)state;
}

static int pull_silence(int16_t *pcm, int count, void *user) {
  (void)user;
  memset(pcm, 0, (size_t)count * sizeof(*pcm));
  return count;
}

static int bind_loopback_udp(int *port_out) {
  int fd = socket(AF_INET, SOCK_DGRAM, 0);
  struct sockaddr_in address;
  socklen_t length = sizeof(address);
  if (fd < 0) return -1;
  memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = 0;
  if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 ||
      getsockname(fd, (struct sockaddr *)&address, &length) != 0) {
    close(fd);
    return -1;
  }
  *port_out = ntohs(address.sin_port);
  return fd;
}

static int send_request(int fd, int listener_port, const char *message) {
  struct sockaddr_in target;
  size_t length = strlen(message);
  memset(&target, 0, sizeof(target));
  target.sin_family = AF_INET;
  target.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  target.sin_port = htons((unsigned short)listener_port);
  return sendto(fd, message, length, 0, (struct sockaddr *)&target,
                sizeof(target)) == (ssize_t)length ? 0 : -1;
}

static int receive_status(int fd, int wanted, int timeout_ms) {
  int elapsed = 0;
  while (elapsed < timeout_ms) {
    fd_set read_set;
    struct timeval timeout;
    char response[4096];
    int selected;
    FD_ZERO(&read_set);
    FD_SET(fd, &read_set);
    timeout.tv_sec = 0;
    timeout.tv_usec = 50000;
    selected = select(fd + 1, &read_set, NULL, NULL, &timeout);
    elapsed += 50;
    if (selected < 0 && errno != EINTR) return -1;
    if (selected <= 0) continue;
    {
      ssize_t received = recv(fd, response, sizeof(response) - 1, 0);
      int status = 0;
      if (received <= 0) continue;
      response[received] = '\0';
      if (sscanf(response, "SIP/2.0 %d", &status) == 1 && status == wanted)
        return 0;
    }
  }
  return -1;
}

static int poll_until_state(ms_session *session, ms_state wanted, int max_polls) {
  int i;
  for (i = 0; i < max_polls; ++i) {
    (void)ms_poll(session, 20);
    if (ms_get_state(session) == wanted) return 0;
    if (ms_get_state(session) == MS_STATE_ENDED && wanted != MS_STATE_ENDED) return -1;
  }
  return -1;
}

static int fail(const char *message) {
  fprintf(stderr, "FAIL: %s\n", message);
  return 1;
}

int main(void) {
  ms_callbacks callbacks;
  ms_session *listener = NULL;
  int listener_port;
  int sip_port = 0;
  int rtp_port = 0;
  int sip_fd = -1;
  int rtp_fd = -1;
  char message[4096];
  char sdp[1024];
  int sdp_length;
  int n;

  memset(&callbacks, 0, sizeof(callbacks));
  callbacks.pull_tx_audio = pull_silence;
  callbacks.on_state = on_state;

  for (listener_port = 49090; listener_port < 49130; ++listener_port) {
    listener = ms_listen(listener_port, &callbacks);
    if (listener != NULL) break;
  }
  if (listener == NULL) return fail("could not bind a MiniSIP listener");
  if (!ms_is_listener(listener) || ms_get_state(listener) != MS_STATE_LISTENING)
    return fail("listener did not enter LISTENING");

  sip_fd = bind_loopback_udp(&sip_port);
  rtp_fd = bind_loopback_udp(&rtp_port);
  if (sip_fd < 0 || rtp_fd < 0) return fail("could not bind test UDP sockets");

  n = snprintf(message, sizeof(message),
      "INVITE sip:door@127.0.0.1:%d SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:%d;branch=z9hG4bKbad\r\n"
      "From: <sip:test@127.0.0.1>;tag=bad\r\n"
      "To: <sip:door@127.0.0.1>\r\n"
      "Call-ID: unsupported@test\r\n"
      "CSeq: 1 INVITE\r\n"
      "Contact: <sip:test@127.0.0.1:%d>\r\n"
      "Content-Type: application/sdp\r\n"
      "Content-Length: 76\r\n\r\n"
      "v=0\r\nc=IN IP4 127.0.0.1\r\nm=audio %d RTP/AVP 111\r\n"
      "a=rtpmap:111 opus/48000/2\r\n",
      listener_port, sip_port, sip_port, rtp_port);
  if (n <= 0 || n >= (int)sizeof(message) ||
      send_request(sip_fd, listener_port, message) != 0)
    return fail("could not send unsupported INVITE");
  (void)ms_poll(listener, 100);
  if (receive_status(sip_fd, 488, 500) != 0)
    return fail("unsupported codec did not receive 488");
  if (ms_get_state(listener) != MS_STATE_LISTENING)
    return fail("listener did not recover after 488");

  sdp_length = snprintf(sdp, sizeof(sdp),
      "v=0\r\n"
      "o=test 1 1 IN IP4 127.0.0.1\r\n"
      "s=minisip-loopback\r\n"
      "c=IN IP4 127.0.0.1\r\n"
      "t=0 0\r\n"
      "m=audio %d RTP/AVP 0 101\r\n"
      "a=rtpmap:0 PCMU/8000\r\n"
      "a=rtpmap:101 telephone-event/8000\r\n"
      "a=fmtp:101 0-16\r\n"
      "a=ptime:20\r\n"
      "a=sendrecv\r\n", rtp_port);
  if (sdp_length <= 0 || sdp_length >= (int)sizeof(sdp))
    return fail("SDP formatting failed");

  n = snprintf(message, sizeof(message),
      "INVITE sip:door@127.0.0.1:%d SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:%d;rport;branch=z9hG4bKloop\r\n"
      "Max-Forwards: 70\r\n"
      "From: <sip:test@127.0.0.1:%d>;tag=caller\r\n"
      "To: <sip:door@127.0.0.1:%d>\r\n"
      "Call-ID: loopback@test\r\n"
      "CSeq: 1 INVITE\r\n"
      "Contact: <sip:test@127.0.0.1:%d>\r\n"
      "X-Doorbell-Mode: answer\r\n"
      "Content-Type: application/sdp\r\n"
      "Content-Length: %d\r\n\r\n%s",
      listener_port, sip_port, sip_port, listener_port, sip_port,
      sdp_length, sdp);
  if (n <= 0 || n >= (int)sizeof(message) ||
      send_request(sip_fd, listener_port, message) != 0)
    return fail("could not send valid INVITE");
  (void)ms_poll(listener, 100);
  if (receive_status(sip_fd, 200, 800) != 0)
    return fail("valid INVITE did not receive 200");
  if (ms_get_state(listener) != MS_STATE_RINGING)
    return fail("listener did not enter RINGING");
  if (strcmp(ms_get_mode(listener), "answer") != 0)
    return fail("X-Doorbell-Mode was not retained");

  n = snprintf(message, sizeof(message),
      "CANCEL sip:door@127.0.0.1:%d SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:%d;branch=z9hG4bKforeign\r\n"
      "From: <sip:test@127.0.0.1>;tag=other\r\n"
      "To: <sip:door@127.0.0.1>\r\n"
      "Call-ID: foreign@test\r\n"
      "CSeq: 1 CANCEL\r\nContent-Length: 0\r\n\r\n",
      listener_port, sip_port);
  if (n <= 0 || n >= (int)sizeof(message) ||
      send_request(sip_fd, listener_port, message) != 0) return fail("foreign CANCEL send");
  (void)ms_poll(listener, 100);
  if (receive_status(sip_fd, 481, 500) != 0 ||
      ms_get_state(listener) != MS_STATE_RINGING)
    return fail("foreign CANCEL affected the active dialog");

  n = snprintf(message, sizeof(message),
      "ACK sip:door@127.0.0.1:%d SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:%d;branch=z9hG4bKack\r\n"
      "From: <sip:test@127.0.0.1>;tag=caller\r\n"
      "To: <sip:door@127.0.0.1>;tag=server\r\n"
      "Call-ID: loopback@test\r\n"
      "CSeq: 1 ACK\r\nContent-Length: 0\r\n\r\n",
      listener_port, sip_port);
  if (n <= 0 || n >= (int)sizeof(message) ||
      send_request(sip_fd, listener_port, message) != 0 ||
      poll_until_state(listener, MS_STATE_IN_CALL, 20) != 0)
    return fail("ACK did not establish the dialog");

  n = snprintf(message, sizeof(message),
      "BYE sip:door@127.0.0.1:%d SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:%d;branch=z9hG4bKforeignbye\r\n"
      "From: <sip:test@127.0.0.1>;tag=other\r\n"
      "To: <sip:door@127.0.0.1>;tag=server\r\n"
      "Call-ID: foreign@test\r\n"
      "CSeq: 2 BYE\r\nContent-Length: 0\r\n\r\n",
      listener_port, sip_port);
  if (n <= 0 || n >= (int)sizeof(message) ||
      send_request(sip_fd, listener_port, message) != 0) return fail("foreign BYE send");
  (void)ms_poll(listener, 100);
  if (receive_status(sip_fd, 481, 500) != 0 ||
      ms_get_state(listener) != MS_STATE_IN_CALL)
    return fail("foreign BYE affected the active dialog");

  n = snprintf(message, sizeof(message),
      "BYE sip:door@127.0.0.1:%d SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:%d;branch=z9hG4bKbye\r\n"
      "From: <sip:test@127.0.0.1>;tag=caller\r\n"
      "To: <sip:door@127.0.0.1>;tag=server\r\n"
      "Call-ID: loopback@test\r\n"
      "CSeq: 2 BYE\r\nContent-Length: 0\r\n\r\n",
      listener_port, sip_port);
  if (n <= 0 || n >= (int)sizeof(message) ||
      send_request(sip_fd, listener_port, message) != 0)
    return fail("could not send BYE");
  (void)ms_poll(listener, 100);
  if (receive_status(sip_fd, 200, 500) != 0)
    return fail("BYE did not receive 200");
  if (ms_get_state(listener) != MS_STATE_ENDED)
    return fail("listener did not end after BYE");
  if ((g_state_mask & (1u << MS_STATE_RINGING)) == 0 ||
      (g_state_mask & (1u << MS_STATE_IN_CALL)) == 0 ||
      (g_state_mask & (1u << MS_STATE_ENDED)) == 0)
    return fail("expected state callbacks were not delivered");

  ms_free(listener);
  close(sip_fd);
  close(rtp_fd);
  puts("PASS: MiniSIP UAS INVITE/ACK/BYE loopback");
  return 0;
}
