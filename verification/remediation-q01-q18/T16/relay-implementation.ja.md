# T16 同一オリジン・認証付き・有界な映像返送

状態：**IMPLEMENTED_CANDIDATE**。完全な本番経路検証は **BLOCKED_ENV / NOT_RUN**。
基準コミット：`39b57222b45d83e2116a65b3d5242718d56fac79`。リリース判定は **NOT_READY**。
push、配備、実機解錠、実際の SOS は行っていない。T16/T17/T18/T31 を完了扱いにしない。

## 実装内容

既存ブラウザーの相対 URL `/api/panel/media-authorize` と `/call-frame` を維持し、`Httpd::routeWorker` と既存 OperationDispatcher の独立した映像用上限に接続した。JPEG を JSON として解析しない。任意 HTTP 転送クライアントや追加スレッドプールは作らない。

A は door から設定済みの唯一の door_station を選ぶ。対象なし、複数対象（オフラインの競合も含む）、削除済み・未接続 peer は拒否する。URL/host/port/path/redirect や呼出側の peer 指定、重複・エンコードされた重複フィールドを受け入れない。Cookie、CSRF、既存の明示的な trusted-Origin 検証を維持し、認証情報付きワイルドカード CORS を追加しない。リバースプロキシも既存の信頼オリジン設定が必要であり、任意の転送ヘッダーは信頼しない。

A は元のパネルセッション、資格情報と権限の版、door 範囲、media.publish、所有者 WebDialogLease、call/revision/owner を検証する。ノード間転送には T31 独立パネル ID が必要で、旧共有資格情報は同一ノードのみ互換対応する。B にブラウザー秘密情報を保存する必要はない。

認証済み暗号化 Mesh の一時コマンドで認可・フレーム・結果・失効を送る。公開 principal のみを委譲し、Cookie、CSRF、長期 Bearer、secret やその参照を転送しない。JPEG を CRDT や永続イベントに記録しない。

B が generation を発行し、B の単調時計上で有効期限を固定する。送信元 peer/epoch、対象、principal、通話、認可要求に結び付け、再送で期限を延長しない。失効要求の再利用記録も有界で、満杯時は拒否する。A は返信時に元のセッションと通話を再検証する。不一致の RPC、peer、世代、応答種別、シーケンスは別の要求を完了できず、3xx を追跡しない。

A の送信前検証に加え、B は有界 JPEG 検証後、既存 peer_frame スロットへの書込み直前に権限・通話・シーケンス・期限を再確認する。異なるノードの単調時計の絶対値は比較しない。`remote_core_accepted` は Core の受理であり、**画面表示の確認ではない**。

発行者ごとに送信中 1 枚と最新待機 1 枚だけを保持し、置換された待機フレームは明示的に破棄する。タイムアウト、失効、通話・世代・peer 変更でキューとキャッシュを消去する。停止時は HTTP 待機を解除してから loop 上の RPC/キューを排出し、HTTP/転送スレッドの join は loop 外に残す。遅い返信で権限を復活させない。`/peer-frame.jpg` は元の同一ノード発行セッション、またはブラウザー資格情報なしの loopback ネイティブ受信側だけに制限する。別の有効な Cookie は loopback でも昇格しない。既存 LAN-public カメラ映像は変更しない。

## 上限

HTTP 全体 16 worker、映像認可とアップロードで共通 4 枠。認可 form/query は 2 KiB、JPEG は 1 MiB。認可・レート記録各 8、RPC と発行者キュー各 4。発行者 10 fps/バースト 2、全体 20 fps/バースト 4。body 読取後の待機 3000 ms、RPC 2500 ms、清掃 50 ms。既存 body 読取期限 5 秒は別であり、総 HTTP 時間を常に 3 秒とは呼ばない。認可は最大 10 秒で転送時間を予約し、再利用防止記録は最大 64。既存 TCP 出力上限を維持する。

JPEG は baseline・単一 scan・8 bit 灰度または 3 成分、各辺 1024 以下かつ 307200 pixel 以下。progressive/multiscan は拒否する。base64 は復号前に正規形と出力長を検証し、Mesh JSON は有界な平坦フィールドのみ。JPEG デコードは有界でも Core CPU を消費する。キュー上限はプロセス全体 RSS 上限ではなく、旧実機の遅延や HTTP 公平性、遅い peer の性能は未測定。

## 証拠と未検証範囲

厳格な C++14 ビルド、production bounds の 50085 assertion、production relay コンポーネント 9 群の 40309 assertion が成功した。反復入力・10000 回の古い要求を含み、90394 個の独立した統合シナリオではない。AddressSanitizer、UndefinedBehaviorSanitizer、リーク検査でも成功。交付物にコマンド、終了コード、ソース hash、ログと Linux 再現 runner を含む。

コンポーネントは新しい production `.inc` 自体を含むが、周辺 Node 認証、HTTP dispatcher、時計/loop、Mesh は明示的な fixture で、画像アダプターはリポジトリ stb ではなく libjpeg を使う。実 Node、TCP、SecureChannel、HTTPS の統合証明ではない。

実リポジトリ用に bounds、既存 HTTP テストの厳密な対象/form/JPEG ケース、実際の二つの Node と HTTP→Mesh→B スロットのテストを追加したが、ここでは完全な Node ビルド・実行は行えていない。T15 の既存権限・世代・読取り制限を弱めず、未知対象の旧 501 期待値だけを拒否 409 に変更する。

適用器の一括検査、Git patch 生成・適用・stage、競合編集・再適用・symlink 拒否は合成アンカーのリポジトリで試験した。完全なソースへの適用証明ではない。ユーザー環境では実際の SHA、作業ツリー、全アンカーを再検証し、より新しいコミットを巻き戻したり既存編集を上書きしたりしない。

T16-01 の実 HTTPS ブラウザー、T16-03 の無応答 peer・連続送信・並列 status/SOS・資源測定、T16-02/04/05 の完全な production ケースは NOT_RUN。対応するコンポーネント成功は部分証拠のみ。全 Core 回帰、実 SIP、歴史的 SDK/実機、独立レビューも NOT_RUN であり、VERIFIED_IN_SCOPE にしない。

適用後のコマンドは commit 前に標準 Core/SIP stub ビルド、全 doorbell_tests、i18n と英文ソース検査を実行する。stub 成功はリリース資格ではない。T17/T18、T31、実機ゲートを維持する。

版更新：Android 0.3.21/22→0.3.22/23、modern iOS 0.1.37/38→0.1.38/39、iOS-kiosk 0.3.49/52→0.3.50/53。ios-legacy、公開 C ABI は変更せず、新しい UI 文字列、SDK、署名材料、アプリバイナリーを含まない。`relay-progress.json` はこの T16 候補だけの記録であり、未確認の全体進捗や他タスクの状態を上書きしない。
