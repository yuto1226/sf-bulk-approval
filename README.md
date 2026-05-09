# sf-bulk-approval

Salesforce 標準承認プロセスを LWC から **任意のオブジェクト** に対して一括で
呼び出すサンプル実装。承認プロセスが有効なオブジェクトを画面上のドロップダウン
から選択して、一括申請 / 一括承認 / 一括却下が行える。

## 構成

```
force-app/main/default/
├── classes/
│   ├── BulkApprovalController.cls       # AuraEnabled API 一式（汎用）
│   └── BulkApprovalControllerTest.cls   # 単体テスト
├── lwc/
│   ├── bulkRecordSubmit/                # 一括申請画面
│   └── bulkRecordApproval/              # 一括承認/却下画面
└── tabs/
    ├── Bulk_Record_Submit.tab-meta.xml
    └── Bulk_Record_Approval.tab-meta.xml
```

## 機能概要

### 一括申請画面（bulkRecordSubmit）
- 「対象オブジェクト」コンボボックスで、有効な承認プロセスを持つオブジェクトを
  選択
- 自分が所有 (OwnerId、無ければ CreatedById) かつ承認プロセス未提出
  (Pending な ProcessInstance なし) のレコードを一覧表示
- 列は **名称 / 作成日 / 最終更新日 / 所有者** （所有者は OwnerId を持つ
  オブジェクトのみ）
- 複数選択 + コメント → `Approval.process` で一括 Submit
- `allOrNone=false` のため部分成功を許容、失敗件はエラーメッセージを表示

### 一括承認画面（bulkRecordApproval）
- 「オブジェクト絞り込み」コンボボックスで全オブジェクト or 特定オブジェクトに
  フィルタ可能（既定は「すべて」）
- 自分が ActorId かつ ProcessInstance.Status='Pending' のワークアイテム一覧
- 列は **オブジェクト / レコード名 / 申請者 / 申請日時**
- 複数選択 + コメント → 一括 Approve / Reject

## 設計メモ

- 対応オブジェクトの一覧は `ProcessDefinition (Type='Approval', State='Active')`
  から導出。標準オブジェクトは API 名で、カスタムオブジェクトは
  `EntityDefinition.DurableId` で名前解決する。
- レコード取得は対象オブジェクトの `Schema.DescribeSObjectResult` を見て
  `isNameField()` の field を「名称」として動的 SOQL で取得する。
- `Apex` の動的 SOQL は describe で得たフィールド名のみを連結し、
  ユーザー入力の objectApiName は `Schema.getGlobalDescribe()` で実在性を検証
  したうえで使用するため、SOQL インジェクションは発生しない。

## 前提

- 対象組織に少なくとも 1 つ以上の有効な承認プロセスが存在すること
- 実行ユーザーが該当承認プロセスへの提出 / 承認権限を持つこと
- カスタムオブジェクトを扱う場合、Apex 実行ユーザーが `EntityDefinition` に
  アクセスできること（標準で可）

## デプロイ

```bash
sf project deploy start --source-dir force-app
sf apex run test --class-names BulkApprovalControllerTest --result-format human
```

デプロイ後、各カスタムタブをアプリビルダーやプロファイルから可視化してください。
