# 認証付き操作 ACK プロトコル v1

[操作 API](operation-api.md)の任意拡張で、既定は無効です。既存 Monocypher の標準 Ed25519 検証を利用し、独自暗号、鍵交換、合意形成、Broker、自動再送を追加しません。

`doors.<door>.operations.ack` に完全なオブジェクト `{"protocol":"ed25519-v1","actuator_id":"front-lock","public_key":"小文字16進数64桁"}` を設定します。公開鍵は32バイト、秘密鍵は実行機器のみが保持し、複製構成・ログ・バックアップへ入れません。未設定/不完全なら ACK 無効です。未知/重複フィールド、別プロトコル、不正/ゼロ公開鍵、ASCII 英数字・`_`・`-` 以外または1–64文字外の機器 ID は拒否します。リーフ編集も完全な設定になるまでは無効です。削除/置換で失効し、現在の設定と prepare 時の固定鍵・機器の両方が一致しなければなりません。鍵、ドア、コマンド、broker/topic、固定担当が変更された旧結び付けでは確認できません。

設定は署名元の指定であり、実機、重複排除、ドアセンサーの動作保証ではありません。ローカル試験機器は実機検証の代用になりません。

設定済み機器への MQTT コマンドは operation_id/authority_node/door に加えて `ack_protocol:"ed25519-v1"`、actuator_id、command_digest を含みます。摘要は `ox-doorbell/operation-command/v1`、door、command、既存の固定 broker-binding SHA256 を順に1行ずつ、末尾改行付き UTF-8 バイト列にした SHA256（小文字16進数）です。変数中の改行は禁止します。

機器は `<base_topic>/cmd/ack` に非 retained のフラット JSON を公開します。8個の文字列フィールドだけを認めます：protocol、operation_id、authority_node、actuator_id、door、command_digest、result、signature。protocol は `ed25519-v1`、result は `command_processed` のみ。2つの ID は小文字16進数32桁、摘要64桁、署名128桁です。本文は最大2048バイト。未知/重複フィールド、retained ACK、従来の未署名 ACK、通常の開閉センサーメッセージは受理しません。

署名対象は `ox-doorbell/operation-ack/v1`、operation_id、authority_node、actuator_id、door、command_digest、`command_processed` の順に各1行、最後の改行も含む正確な UTF-8 バイト列です。フィールドを厳密に検証してからドメイン分離した入力を作り、曖昧な JSON の直列化は署名しません。JSON 順序/空白は関係しません。参照テスト機器は公開形式を独立実装し、明示的なテスト鍵で署名します。

Core の状態ループは現在認可された署名元/公開鍵と固定担当、ドア、コマンド、endpoint、prepare 時の意図、永続化済み dispatch 取得を照合します。有効な署名だけでは別の対象を更新できません。重複 ACK は元レコードだけを確定し、再送しません。遅延した有効な ACK は再起動後も元の unknown を解決できますが、新しいドア操作には影響しません。

`actuator_ack` は認証機器がコマンド処理を報告した意味です。物理的に開扉した証明でも、独立したセンサー変化の原因証明でもありません。UI は operation_id と authority_node の両方を照合します。実測センサーがなければ物理状態は未確認で、本タスクは架空のセンサー API を追加しません。

ACK 設定がある場合、アダプター受理から4秒を待ち、期限切れで同じ行を `unknown_after_dispatch/ack_unavailable` にします。切断時は未決送信を `transport_ambiguous` とし、再接続で再送しません。非対応機器は `dispatched/ack_unavailable`、切断後は不明です。監視は最大2048件、切断掃除の永続更新は1ターン32件まで。停止はタイマー/掃除を取消し、再起動は既存の台帳回復規則に従います。未解決行を黙って削除しません。

機器側の重複排除は副作用より先に ID を永続化する必要があります。テスト機器は有限の参照契約で、既存 Home Assistant へのデプロイではありません。Core は重複排除対応でも1回しか送出せず、未検証の機器に end-to-end exactly-once を保証しません。

検証鍵は Edwards の正規エンコーディングを使い、8 個の低位数点を拒否します。既存の余因子付き検証器では認証を成立させない鍵を除外します。固定座標は [libsodium](https://github.com/jedisct1/libsodium/blob/1.0.18/src/libsodium/crypto_core/ed25519/ref10/ed25519_ref10.c#L966) でも確認される標準 Ed25519 点で、署名検証は既存 Monocypher を使用します。

参照実行器は pending/completed を別々に永続化します。ID の取得後、完了保存前のクラッシュでは成功 ACK を送らず、模擬動作も再実行しません。結果は不明であり、厳密な一回完了を保証しません。
