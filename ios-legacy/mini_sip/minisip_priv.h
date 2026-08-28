/* minisip_priv.h — mini SIP 内部共有定義 (minisip.c / sip.c / sdp.c / rtp.c 間)。
 * 公開ヘッダには出さない実装詳細。 */
#ifndef MINISIP_PRIV_H
#define MINISIP_PRIV_H

#include "minisip.h"

#include <netinet/in.h>
#include <stdint.h>

/* 内部状態機。公開 ms_state より細かい (ENDING = BYE 送信済み応答待ち)。 */
typedef enum {
  MS_ST_INIT = 0,
  MS_ST_CALLING,
  MS_ST_IN_CALL,
  MS_ST_ENDING,
  MS_ST_ENDED
} ms_istate;

#define MS_PTIME_MS 20                      /* パケット間隔 */
#define MS_FRAME MS_SAMPLES_PER_FRAME       /* 160 サンプル/20ms */
#define MS_PT_PCMU 0                        /* RTP payload type: PCMU 固定 */
#define MS_PT_TE_DEFAULT 101                /* telephone-event の既定 PT */
#define MS_SIP_BUF 2048
#define MS_CALL_TIMEOUT_MS 32000            /* 呼確立の上限 (RFC3261 Timer B 相当) */
#define MS_T1_MS 500                        /* INVITE 再送初期間隔 */
#define MS_T2_MS 4000                       /* 再送間隔の上限 */
#define MS_DTMF_MAX 16                      /* DTMF 送信キュー長 */

/* 進行中の DTMF イベント送出状態 (RFC2833)。 */
typedef struct {
  int active;        /* 送出中か */
  int event;         /* イベント番号 0-15 */
  int pkts_sent;     /* このイベントで送ったパケット数 */
  int total_pkts;    /* 送出総数 (末尾数個が end bit) */
  uint32_t ts;       /* イベント開始 RTP timestamp (全パケット共通) */
} ms_dtmf_tx;

struct ms_session {
  int sip_fd;   /* SIP UDP ソケット */
  int rtp_fd;   /* RTP UDP ソケット */
  int rtcp_fd;  /* RTCP UDP ソケット (rtp+1)。最小実装では受信破棄のみ */

  struct sockaddr_in door_sip; /* 門口機 SIP アドレス */
  struct sockaddr_in door_rtp; /* 協商後の門口 RTP 宛先 */
  int have_door_rtp;

  char local_ip[64];  /* 門口へ到達する自 IP (SDP/Contact/Via 用) */
  int local_sip_port; /* sip_fd の実ポート */
  int local_rtp_port; /* rtp_fd の実ポート */

  /* ダイアログ識別子 */
  char call_id[128];
  char from_tag[40];
  char to_tag[96];        /* 200 OK / 受信要求から学習 */
  char invite_branch[64]; /* INVITE トランザクションの branch */
  char via_branch[64];    /* 直近送信要求の branch (ACK/BYE で更新) */
  unsigned cseq;          /* INVITE の CSeq。BYE は +1 */
  char mode[16];
  char door_contact[256]; /* 200 OK の Contact (in-dialog 要求の宛先解析用) */
  char last_sdp[1024];    /* 直近 INVITE の SDP (再送で同一本文) */

  /* RTP 送信状態 */
  uint32_t ssrc;
  uint16_t tx_seq;
  uint32_t tx_ts;
  int pt_te;      /* 協商済 telephone-event PT */
  int tx_started; /* 最初の RTP を送ったか (marker bit 用) */

  /* タイミング (ms 単位, 単調近似) */
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

  /* DTMF キュー */
  int dtmf_events[MS_DTMF_MAX];
  int dtmf_qlen;
  int dtmf_qpos;
  ms_dtmf_tx dtmf;

  char remote_rtp_str[64]; /* ms_get_remote_rtp 用の整形バッファ */
};

/* ---- 時刻ヘルパ (minisip.c) ---- */
long long ms_now_ms(void);

/* ---- SIP メッセージ (sip.c) ---- */
/* 送信要求を組み立てて sip_fd から送る。成功 0。 */
int ms_send_invite(ms_session *s);
int ms_send_ack(ms_session *s);
int ms_send_bye(ms_session *s);
/* 受信 BYE への 200 OK 応答 (要求本文をエコー)。 */
int ms_reply_ok(ms_session *s, const char *req, int reqlen);

/* 受信 SIP メッセージを処理。戻り値は状態遷移のヒント (0 通常)。 */
void ms_handle_sip(ms_session *s, const char *msg, int len);

/* ---- SDP (sdp.c) ---- */
/* オファー SDP を last_sdp に生成。長さを返す。 */
int ms_build_offer(ms_session *s);
/* アンサー SDP を解析し door_rtp / pt_te を設定。PCMU 確認で 0、失敗で負。 */
int ms_parse_answer(ms_session *s, const char *sdp, int len);

/* ---- RTP (rtp.c) ---- */
/* 音声 1 フレーム (または DTMF) を送出。 */
void ms_rtp_tick(ms_session *s);
/* 受信 RTP を処理 (デコード → on_rx_audio)。 */
void ms_rtp_recv(ms_session *s);
/* DTMF 送出を進める。呼ばれる度に 1 パケット。継続中なら 1、無ければ 0。 */
int ms_dtmf_tick(ms_session *s);

/* ---- 小物 (minisip.c) ---- */
/* ヘッダ値抽出 (大文字小文字無視、compact form 対応)。見つからねば 0、値を out へ。 */
int ms_hdr(const char *msg, int len, const char *name, const char *cname, char *out,
           int outsz);
/* SIP 応答のステータスコード (先頭行)。無ければ 0。 */
int ms_status_code(const char *msg, int len);
/* 要求メソッド (先頭行の先頭語)。out へ。要求でなければ 0。 */
int ms_req_method(const char *msg, int len, char *out, int outsz);

#endif /* MINISIP_PRIV_H */
