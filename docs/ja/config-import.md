# 設定の一時保存とインポート

既存の管理者認証、設定検証、LWW と SQLite トランザクションを使用します。
通常の batch 上限 256 件は変わりません。外部ファイルパスは受け付けません。

`POST /api/config/import/{stage,preflight,commit,cancel,query}` は毎回、有効な管理者
セッション、信頼された Origin、`X-Doorbell-CSRF` を要求します。追加 ABI
`db_core_config_import_json_v2` も同じセッションと CSRF を要求し、戻り値は
`db_free` で解放します。stage token だけでは認証できません。

stage の入力は `{schema_version:2,expected_revision,document:{schema_version:2,config}}`
です。config は可変設定全体の希望状態で、省略したフィールドは削除されます。
有効な未知フィールドは保持されます。管理者 snapshot から開始してください。
既存 admin は保持され、パスワード digest や admin の変更は復元できません。
未知の schema、重複キー、予約された履歴キー、不正な JSON は拒否します。
旧ファイル形式は呼出側が明示的に変換します。旧 import API の互換動作と上限は維持します。

成功時は stage_token、digest、expected_revision、expires_in_ms を返します。
token は乱数 128 bit、digest は envelope を含むアップロード要求の正確なバイト列の
SHA-256 です。管理者資格情報、開始セッション、起動 ID、基準 revision、単調時計の
固定 10 分期限に結び付けます。共有管理者につき一つのみ保持し、preflight は延長しません。
cancel、期限切れ、成功時にメモリを解放し、再起動で失効します。元ファイルは変更しません。

preflight/cancel は `{schema_version:2,stage_token,digest}`、commit はさらに
乱数 128 bit を表す 32 桁小文字 hex の安定した operation_id を要求します。
別セッションによる既存 stage の利用は拒否し、基準 revision の変更は config_conflict
になります。新しい snapshot と stage を確認してください。

preflight は実設定を変更せず、全差分の JSON Pointer、変更前後の有無と秘匿済み値、
展開件数、検証問題、不足する secret: 参照とローカル asset を返します。
問題があれば can_commit:false です。秘密値と asset 実体は既存サービスで別途復元し、
commit 時にも再検証します。通常の JSON export は完全な災害復旧バックアップではありません。

上限は要求全体 4 MiB、config 内の深さ 16、解析ノード 65,536、変更葉 4,096、
物理 CRDT 変更 4,096 です。配列は全体置換です。既存の子レコードも同じトランザクションで
整合させ、デバイス UI は既存の semantic element 検証を通します。

各変更 entity に全体置換の意図を一つ保存し、[競合履歴](config-conflicts.md)の
64 KiB/record と全体予算を維持します。未解決競合や履歴容量超過は preflight で示し、
書込みを拒否します。4 MiB 内なら必ず保存できるという意味ではありません。
機器メモリと最大サイズの実機資格は別のリリース条件です。

設定、履歴、成功 receipt は一つのローカル SQLite トランザクションで保存し、
成功後のみメモリ公開と複製を行います。障害時に半分のインポートは公開しません。
クラッシュ復旧は旧版か新版全体です。全クラスタの同時切替ではなく、既存の複製状態に従い収束します。

receipt は upload/token digest、資格情報の identity、元の結果と committed_revision を保存します。
同一 ID/token/digest は再起動後の同じ管理者による再認証でも元の結果を返し、再書込みしません。
その revision は元の commit のものです。不一致は operation_conflict、資格情報変更はアクセス失効です。
receipt は無断削除せず 128 件保持し、以後は receipt_capacity_exceeded になります。
自動再試行・再実行・破壊的な履歴整理は行いません。

query は commit と同じ envelope を受け取り、receipt の読取りだけを行います。成功時は
`{ok:true,schema_version:2,state:"committed",result:<元の結果>}`、未登録 ID は
operation_not_found です。活動中の stage を実行しません。同じ管理者資格情報での
再起動後の再認証にも対応します。応答がないことは成功・失敗の証明ではありません。
永続 receipt は厳密に検証し、不正な場合は receipt_store_invalid で拒否します。
容量不足と不正な receipt は preflight に表示し、不正時も cancel で stage を解放できます。
