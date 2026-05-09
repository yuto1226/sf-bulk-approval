# sf-bulk-approval

Salesforce 標準承認プロセスを LWC から一括で呼び出すサンプル実装。
対象オブジェクトは **Opportunity（商談）**。

## 構成

```
force-app/main/default/
├── classes/
│   ├── BulkApprovalController.cls       # AuraEnabled API 一式
│   └── BulkApprovalControllerTest.cls   # 単体テスト
├── lwc/
│   ├── bulkOpportunitySubmit/           # 一括申請画面
│   └── bulkOpportunityApproval/         # 一括承認画面
└── tabs/
    ├── Bulk_Opportunity_Submit.tab-meta.xml
    └── Bulk_Opportunity_Approval.tab-meta.xml
```

## 機能概要

### 一括申請画面（bulkOpportunitySubmit）
- 自分が Owner かつ承認プロセス未提出（Pending な ProcessInstance を持たない）の Opportunity 一覧
- 複数選択 + コメント → `Approval.process` で一括 Submit
- `allOrNone=false` のため部分成功を許容、失敗件はエラーメッセージを表示

### 一括承認画面（bulkOpportunityApproval）
- 自分が ActorId かつ ProcessInstance.Status='Pending' のワークアイテム一覧
（TargetObject が Opportunity のみ）
- 複数選択 + コメント → 一括 Approve / Reject

## 前提

- 対象組織の Opportunity に有効な承認プロセスが1本以上存在すること
- 実行ユーザーが該当承認プロセスへの提出権限を持つこと

## デプロイ

```bash
sf project deploy start --source-dir force-app
sf apex run test --class-names BulkApprovalControllerTest --result-format human
```

デプロイ後、各カスタムタブをアプリビルダーやプロファイルから可視化してください。
