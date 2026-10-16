import { LightningElement, api } from 'lwc';
import getIssues from '@salesforce/apex/RosterIngestionIssueController.getIssues';

const COLUMNS = [
    { label: 'Row', fieldName: 'Row_Number__c', type: 'number', initialWidth: 80, cellAttributes: { alignment: 'left' } },
    { label: 'Severity', fieldName: 'Severity__c', initialWidth: 100 },
    { label: 'Code', fieldName: 'Code__c', initialWidth: 200 },
    { label: 'Column', fieldName: 'Column__c', initialWidth: 180, wrapText: true },
    { label: 'Message', fieldName: 'Message__c', wrapText: true },
    {
        label: 'Provider',
        fieldName: 'providerUrl',
        type: 'url',
        initialWidth: 200,
        typeAttributes: { label: { fieldName: 'providerName' }, target: '_self' }
    }
];

// Values must match RosterIngestionIssue__c.Severity__c ('' = all).
const SEVERITY_OPTIONS = [
    { label: 'All', value: '' },
    { label: 'Errors', value: 'Error' },
    { label: 'Warnings', value: 'Warning' }
];

export default class RosterIngestionIssues extends LightningElement {
    @api recordId;

    columns = COLUMNS;
    severityOptions = SEVERITY_OPTIONS;
    severity = '';
    issues = [];
    totalCount = 0;
    loading = false;
    loaded = false;
    error;

    connectedCallback() {
        this.reload();
    }

    get title() {
        return this.loaded ? `Issues (${this.totalCount})` : 'Issues';
    }

    get hasIssues() {
        return this.issues.length > 0;
    }

    get hasMore() {
        return this.issues.length < this.totalCount;
    }

    get rows() {
        return this.issues.map((issue) => ({
            ...issue,
            providerUrl: issue.Provider__c ? `/lightning/r/Account/${issue.Provider__c}/view` : undefined,
            providerName: issue.Provider__r?.Name
        }));
    }

    handleSeverityChange(event) {
        this.severity = event.detail.value;
        this.reload();
    }

    handleRefresh() {
        this.reload();
    }

    handleLoadMore() {
        const last = this.issues[this.issues.length - 1];
        this.load(last.Row_Number__c, last.Id);
    }

    reload() {
        this.issues = [];
        this.load(null, null);
    }

    // Each page continues after the last Issue shown (see RosterIngestionIssueController).
    async load(afterRowNumber, afterIssueId) {
        this.loading = true;
        try {
            const page = await getIssues({
                runId: this.recordId,
                severity: this.severity,
                afterRowNumber,
                afterIssueId
            });
            this.issues = [...this.issues, ...page.issues];
            this.totalCount = page.totalCount;
            this.error = undefined;
        } catch (e) {
            this.error = reduceError(e);
        } finally {
            this.loading = false;
            this.loaded = true;
        }
    }
}

function reduceError(error) {
    if (Array.isArray(error?.body)) {
        return error.body.map((e) => e.message).join(', ');
    }
    return error?.body?.message || error?.message || 'Unknown error';
}
