import { LightningElement, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getApprovalEnabledObjects from '@salesforce/apex/BulkApprovalController.getApprovalEnabledObjects';
import getSubmittableRecords from '@salesforce/apex/BulkApprovalController.getSubmittableRecords';
import submitForApproval from '@salesforce/apex/BulkApprovalController.submitForApproval';

const BASE_COLUMNS = [
    { label: '名称', fieldName: 'name', type: 'text' },
    {
        label: '作成日',
        fieldName: 'createdDate',
        type: 'date',
        typeAttributes: {
            year: 'numeric',
            month: '2-digit',
            day: '2-digit',
            hour: '2-digit',
            minute: '2-digit'
        }
    },
    {
        label: '最終更新日',
        fieldName: 'lastModifiedDate',
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
const OWNER_COLUMN = { label: '所有者', fieldName: 'ownerName', type: 'text' };

export default class BulkRecordSubmit extends LightningElement {
    @track objectOptions = [];
    @track rows = [];
    @track columns = BASE_COLUMNS;
    @track selectedIds = [];
    @track errors = [];
    selectedObject;
    objectLabel;
    comments = '';
    isLoading = false;
    objectsError;
    wiredRecords;

    @wire(getApprovalEnabledObjects)
    wiredObjects({ data, error }) {
        if (data) {
            this.objectOptions = data.map((o) => ({
                label: `${o.label} (${o.apiName})`,
                value: o.apiName
            }));
            if (data.length && !this.selectedObject) {
                this.selectedObject = data[0].apiName;
            }
            this.objectsError = null;
        } else if (error) {
            this.objectOptions = [];
            this.objectsError = this.reduceError(error);
        }
    }

    @wire(getSubmittableRecords, {
        objectApiName: '$selectedObject',
        maxRows: 200
    })
    wiredSubmittable(result) {
        this.wiredRecords = result;
        if (result.data) {
            this.rows = result.data.rows || [];
            this.objectLabel = result.data.objectLabel;
            this.columns = result.data.hasOwner
                ? [...BASE_COLUMNS, OWNER_COLUMN]
                : BASE_COLUMNS;
        } else if (result.error) {
            this.rows = [];
            this.showToast('エラー', this.reduceError(result.error), 'error');
        }
    }

    get hasObjects() {
        return this.objectOptions.length > 0;
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

    get cardTitle() {
        return this.objectLabel
            ? `一括申請 - ${this.objectLabel}`
            : '一括申請';
    }

    get noObjectsMessage() {
        if (this.objectsError) {
            return this.objectsError;
        }
        return '有効な承認プロセスを持つオブジェクトが見つかりません。';
    }

    handleObjectChange(event) {
        this.selectedObject = event.detail.value;
        this.selectedIds = [];
        this.errors = [];
        this.comments = '';
        const datatable = this.template.querySelector('lightning-datatable');
        if (datatable) {
            datatable.selectedRows = [];
        }
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
                    const rec = this.rows.find((row) => row.id === r.recordId);
                    return {
                        id: r.recordId,
                        label: rec ? rec.name : r.recordId,
                        message: r.message
                    };
                });

            this.showToast(
                '一括申請結果',
                `成功 ${successCount} 件 / 失敗 ${failureCount} 件`,
                failureCount === 0 ? 'success' : 'warning'
            );

            const datatable = this.template.querySelector('lightning-datatable');
            if (datatable) {
                datatable.selectedRows = [];
            }
            this.selectedIds = [];
            this.comments = '';
            await refreshApex(this.wiredRecords);
        } catch (e) {
            this.showToast('エラー', this.reduceError(e), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    handleRefresh() {
        return refreshApex(this.wiredRecords);
    }

    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({ title, message, variant })
        );
    }

    reduceError(error) {
        if (!error) return '不明なエラー';
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
