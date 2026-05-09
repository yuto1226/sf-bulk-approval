import { LightningElement, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getSubmittableOpportunities from '@salesforce/apex/BulkApprovalController.getSubmittableOpportunities';
import submitForApproval from '@salesforce/apex/BulkApprovalController.submitForApproval';

const COLUMNS = [
    { label: '商談名', fieldName: 'name', type: 'text', sortable: true },
    { label: '取引先', fieldName: 'accountName', type: 'text' },
    { label: 'フェーズ', fieldName: 'stageName', type: 'text' },
    {
        label: '金額',
        fieldName: 'amount',
        type: 'currency',
        cellAttributes: { alignment: 'right' }
    },
    { label: '完了予定日', fieldName: 'closeDate', type: 'date-local' },
    { label: '所有者', fieldName: 'ownerName', type: 'text' }
];

export default class BulkOpportunitySubmit extends LightningElement {
    columns = COLUMNS;
    @track rows = [];
    @track selectedIds = [];
    @track errors = [];
    comments = '';
    isLoading = false;
    wiredResult;

    @wire(getSubmittableOpportunities, { maxRows: 200 })
    wiredOpps(result) {
        this.wiredResult = result;
        if (result.data) {
            this.rows = result.data;
        } else if (result.error) {
            this.rows = [];
            this.showToast(
                'エラー',
                this.reduceError(result.error),
                'error'
            );
        }
    }

    get hasRows() {
        return this.rows && this.rows.length > 0;
    }

    get hasSelection() {
        return this.selectedIds.length > 0;
    }

    get submitDisabled() {
        return this.isLoading || !this.hasSelection;
    }

    get selectedCountLabel() {
        return `選択中: ${this.selectedIds.length} 件`;
    }

    get hasErrors() {
        return this.errors.length > 0;
    }

    handleRowSelection(event) {
        const selected = event.detail.selectedRows || [];
        this.selectedIds = selected.map((row) => row.id);
    }

    handleCommentsChange(event) {
        this.comments = event.target.value;
    }

    async handleSubmit() {
        if (!this.hasSelection) {
            return;
        }
        this.isLoading = true;
        this.errors = [];
        try {
            const results = await submitForApproval({
                recordIds: this.selectedIds,
                comments: this.comments
            });
            const successCount = results.filter((r) => r.success).length;
            const failureCount = results.length - successCount;
            this.errors = results
                .filter((r) => !r.success)
                .map((r) => {
                    const opp = this.rows.find((row) => row.id === r.recordId);
                    return {
                        id: r.recordId,
                        label: opp ? opp.name : r.recordId,
                        message: r.message
                    };
                });

            this.showToast(
                '一括申請結果',
                `成功 ${successCount} 件 / 失敗 ${failureCount} 件`,
                failureCount === 0 ? 'success' : 'warning'
            );

            // Clear selection on the datatable.
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
