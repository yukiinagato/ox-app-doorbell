# 永続操作 API

`operations_v1` は Core の prepare/execute/query の実装と検証を示します。既存 UI の移行、実行機器の ACK、物理動作の exactly-once 保証を示すものではありません。フィールドの完全な定義は [英語原本](../en/operation-api.md) に対応します。

ドアごとに `doors.<door>.operations.authority_node`、グローバル SOS に `cluster.operations.sos_authority_node` を設定します。値は小文字16進数32桁の既存ノード ID です。未設定、切断、非対応なら拒否し、ページノードや別ノードへ代行させません。担当変更の前に未決操作の手動確認が必要です。分断時の自動引き継ぎは非対応です。

`devices.<node>.operations` は明示的な権限です。例：`{"doors":["front"],"sos_start":true,"sos_clear":false}`。省略は許可なし、ドア許可は SOS 許可を含みません。ドアは重複なしの最大64件、ID は ASCII 英数字と `_`、`-` の1–128文字です。未知のセキュリティフィールド、型違い、重複フィールド、不正なノード ID は、オブジェクト全体への埋め込み書き込みでも拒否します。権限と担当設定は既存のバージョン付き構成で永続化・複製されます。

HTTP は現在有効な管理者セッションを必要とし、POST には正確な Origin と空でない `X-Doorbell-CSRF` も必要です。実行直前に Core のループ上で再検証します。ネイティブの主体は自ノード、mesh の主体は認証済み接続の相手です。担当ノードは現在の資格情報・権限バージョンと対象の許可を再確認します。管理者の申告もデバイス権限を省略できません。execute は作成者のみ、query は作成者または対象の許可を保有する管理者のみです。JSON から主体を選べません。Web SOS は有効な dbpanel セッションでも sos_start だけを利用できます。POST はそのセッションのCSRFと正確な信頼済みOriginが必要です。GET queryもCSRFを必要とし、Originがある場合は信頼済みか検証します。GETのOrigin省略は同一originのブラウザー取得のため許可します。有効なpanel CSRFがある場合、管理者cookieが同時にあってもpanel主体を選びます。主体は認証済みページノードとサーバー生成のセッションハッシュに結び付き、実行・照会は同じセッションだけです。共有Bearerだけでは利用できません。ページは毎回セッション期限と資格情報を、担当は複製された資格情報メタデータとページノードの明示SOS権限を確認します。分断中の未到達の撤回は適用できません。これはセッションの識別であり、独立panel/SIPアカウントの開通ではありません。

prepare は `POST /api/operations/prepare`、本文例は `{"schema_version":2,"action":"door_open","door":"front","parameters":{}}` です。ほかに `sos_start` と `sos_clear` があり、SOS はドアを指定しません。parameters は省略か空オブジェクトのみです。任意の `request_id` は小文字16進数32桁で、1回の通信の対応付けだけに使います。prepare はランダムな `operation_id`、固定 `authority_node`、`config_generation`、`prepared`、最大30000ミリ秒の残り時間を返します。再 prepare は新しい意図なので、応答喪失時に自動実行しません。

execute は `POST /api/operations/<id>/execute` で、元の action/door/parameters と返却された操作・担当 ID を送ります。query は `GET /api/operations/<id>?authority_node=<node>&action=door_open&door=front`、SOS では door を省略します。対象指定はルーティングのヒントに過ぎず、保存済み対象と現在権限を照合します。未知・重複フィールドと8 KiB超の本文は拒否します。

追加 ABI は `db_core_operation_prepare_json_v2`、`db_core_operation_execute_json_v2`、`db_core_operation_query_json_v2` です。同じ JSON を受け取り、返却文字列は `db_free` で解放します。ワーカースレッドで呼び出し、最長4秒待機します。Core ループ上のブロッキング呼び出しは拒否します。既存 ABI のレイアウトは変えません。

結果はバージョン、リクエスト ID、状態、再試行方針を含み、既知の操作は操作 ID・担当・構成スナップショットと同じ opaque 世代も含みます。query は200、受理/送出/不明な execute は202です。`dispatched` はアダプターの受理のみで `ack_unavailable` を示し、開錠の証明ではありません。`unknown_after_dispatch` は元 ID の問い合わせのみで再送しません。未開始の期限切れは503 `not_started`、開始後の応答不明は503 `outcome_unknown` です。ほかに認証401、権限403、構成/パラメーター競合409、不正400、非対応501、未知ID404、担当不通・容量・保存障害503、本文超過413を返します。

ローカル待機と mesh の送信待ちは各32件・4秒までです。開始と期限切れは同じロックで決定し、ワーカーが待機し、Core ループは非同期応答を処理します。停止時は待機を解除してから HTTP ワーカーを終了させます。コールバックは入力を所有し、接続や終了済みスタックに依存しません。借用ループが残っても破棄済み Node を参照しません。

新しい開錠操作は固定担当が永続トランザクションで唯一の送出資格を得て直接 MQTT に入れ、再生可能な開錠イベントを使いません。コマンドと broker/port/topic のダイジェストを固定し、活動中のアダプターと一致させます。担当は既存 MQTT bridge の活動条件も満たす必要があります。新操作の入隊には接続済み、256パケット未満、合計1 MiB以下を要求します。この新制限は旧 MQTT 経路を変更しません。入隊は broker/機器 ACK ではなく、機器側の重複排除なしに end-to-end exactly-once は保証できません。

SOS は操作・担当 ID 付きの永続意図イベントを1回だけ追加します。再試行で2件目を作らず、`dispatched` は遠隔通知の配送成功を意味しません。T07 はアダプター証拠、T12/T36 は SOS/UI 移行を扱います。旧 ABI、HTTP、ネイティブ UI、SIP 特徴コード、ルールは従来の1回限りの best-effort のままで、呼び出し間の重複排除や不明結果の自動再試行を提供しません。残る呼び出し元と移行担当は T06 caller map に記録します。
