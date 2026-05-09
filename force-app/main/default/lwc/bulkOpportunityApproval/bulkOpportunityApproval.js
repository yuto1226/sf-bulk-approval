import { LightningElement, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getMyPendingOpportunityApprovals from '@salesforce/apex/BulkApprovalController.getMyPendingOpportunityApprovals';
import processWorkitems from '@salesforce/apex/BulkApprovalController.processWorkitems';

const COLUMNS = [
    { label: '商談名', fieldName: 'name', type: 'text' },
    { label: 'フェーズ', fieldName: 'stageName', type: 'text' },
    {
        label: '金額',
        fieldName: 'amount',
        type: 'currency',
        cellAttributes: { alignment: 'right' }
    },
    { label: '申請者', fieldName: 'submitterName', type: 'text' },
    {
        label: '申請日時',
        fieldName: 'submittedDate',
        type: 'date',
        typeAttributes: {
            year: 'numeric',
            month: '2-digit',
            day: '2-digit',
            hour: '2-digit',
            minute: '2-digit'
        }
    }
];

export default class BulkOpportunityApproval extends LightningElement {
    columns = COLUMNS;
    @track rows = [];
    @track selectedIds = [];
    @track errors = [];
    comments = '';
    isLoading = false;
    wiredResult;

    @wire(getMyPendingOpportunityApprovals)
    wiredApprovals(result) {
        this.wiredResult = result;
        if (result.data) {
            this.rows = result.data;
        } else if (result.error) {
            this.rows = [];
            this.showToast('エラー', this.reduceError(result.error), 'error');
        }
    }

    get hasRows() {
        return this.rows && this.rows.length > 0;
    }

    get hasSelection() {
        return this.selectedIds.length > 0;
    }

    get actionDisabled() {
        return this.isLoading || !this.hasSelection;
    }

    get selectedCountLabel() {
        return `選択中: ${this.selectedIds.length} 件`;
    }

    get hasErrors() {
        return this.errors.length > 0;
    }

    get keyField() {
        return 'workitemId';
    }

    handleRowSelection(event) {
        const selected = event.detail.selectedRows || [];
        this.selectedIds = selected.map((row) => row.workitemId);
    }

    handleCommentsChange(event) {
        this.comments = event.target.value;
    }

    handleApprove() {
        return this.runAction('Approve', '一括承認結果');
    }

    handleReject() {
        return this.runAction('Reject', '一括却下結果');
    }

    async runAction(action, toastTitle) {
        if (!this.hasSelection) {
            return;
        }
        this.isLoading = true;
        this.errors = [];
        try {
            const results = await processWorkitems({
                workitemIds: this.selectedIds,
                action,
                comments: this.comments
            });
            const successCount = results.filter((r) => r.success).length;
            const failureCount = results.length - successCount;
            this.errors = results
                .filter((r) => !r.success)
                .map((r) => {
                    const row = this.rows.find(
                        (x) => x.workitemId === r.recordId
                    );
                    return {
                        id: r.recordId,
                        label: row ? row.name : r.recordId,
                        message: r.message
                    };
                });

            this.showToast(
                toastTitle,
                `成功 ${successCount} 件 / 失敗 ${failureCount} 件`,
                failureCount === 0 ? 'success' : 'warning'
            );

            const datatable = this.template.querySelector('lightning-datatable');
            if (datatable) {
                datatable.selectedRows = [];
            }
            this.selectedIds = [];
            this.comments = '';
            await refreshApex(this.wiredResult);
        } catch (e) {
            this.showToast('エラー', this.reduceError(e), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    handleRefresh() {
        return refreshApex(this.wiredResult);
    }

    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({ title, message, variant })
        );
    }

    reduceError(error) {
        if (!error) {
            return '不明なエラー';
        }
        if (Array.isArray(error.body)) {
            return error.body.map((e) => e.message).join(', ');
        }
        if (error.body && typeof error.body.message === 'string') {
            return error.body.message;
        }
        if (typeof error.message === 'string') {
            return error.message;
        }
        return JSON.stringify(error);
    }
}
