import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import getRuns from '@salesforce/apex/RosterIngestionRunController.getRuns';
import startRun from '@salesforce/apex/RosterIngestionRunController.startRun';
import cancel from '@salesforce/apex/RosterIngestionRunController.cancel';

// Status values must match RosterIngestionRunService.STATUS_*
const ACTIVE_STATUSES = new Set(['Queued', 'Running']);
const STATUS_CLASSES = {
    Completed: 'slds-theme_success',
    'Completed with Errors': 'slds-theme_warning',
    Failed: 'slds-theme_error'
};
const POLL_INTERVAL_MS = 3000;

export default class RosterIngestionRuns extends NavigationMixin(LightningElement) {
    @api recordId;

    runs = [];
    busy = false;
    error;
    pollTimer;

    connectedCallback() {
        this.loadRuns();
    }

    disconnectedCallback() {
        this.stopPolling();
    }

    // Runs progress in the background, so the list is re-queried (not cached) and polled while one is active.
    loadRuns = async () => {
        try {
            this.runs = await getRuns({ recordId: this.recordId });
            this.error = undefined;
        } catch (e) {
            this.error = reduceError(e);
        }
        this.updatePolling();
    };

    get hasRuns() {
        return this.runs.length > 0;
    }

    get rows() {
        return this.runs.map((run) => ({
            ...run,
            isActive: ACTIVE_STATUSES.has(run.Status__c),
            statusClass: STATUS_CLASSES[run.Status__c] ?? '',
            summary: summarize(run)
        }));
    }

    updatePolling() {
        const anyActive = this.runs.some((run) => ACTIVE_STATUSES.has(run.Status__c));
        if (anyActive && !this.pollTimer) {
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this.pollTimer = setInterval(this.loadRuns, POLL_INTERVAL_MS);
        } else if (!anyActive) {
            this.stopPolling();
        }
    }

    stopPolling() {
        clearInterval(this.pollTimer);
        this.pollTimer = undefined;
    }

    async handleStart() {
        if (!(await confirmIngest('Ingest the latest version of the personnel file? Providers will be created and updated.'))) {
            return;
        }
        await this.act(() => startRun({ recordId: this.recordId }), 'Ingestion started.');
    }

    async handleCancel(event) {
        const runId = event.currentTarget.dataset.id;
        await this.act(() => cancel({ runId }), 'Run cancelled. Rows already processed stay processed.');
    }

    async act(action, successMessage) {
        this.busy = true;
        try {
            await action();
            this.toast('success', successMessage);
        } catch (e) {
            this.toast('error', reduceError(e));
        } finally {
            this.busy = false;
        }
        await this.loadRuns();
    }

    handleOpenRun(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: event.currentTarget.dataset.id, objectApiName: 'RosterIngestionRun__c', actionName: 'view' }
        });
    }

    toast(variant, message) {
        this.dispatchEvent(new ShowToastEvent({ title: variant === 'success' ? 'Roster ingestion' : 'Action failed', message, variant }));
    }
}

function summarize(run) {
    return [
        run.Total_Rows__c == null ? `${run.Rows_Processed__c ?? 0} rows` : `${run.Rows_Processed__c ?? 0} of ${run.Total_Rows__c} rows`,
        `${run.Inserted__c ?? 0} inserted`,
        `${run.Updated__c ?? 0} updated`,
        `${run.Unchanged__c ?? 0} unchanged`,
        `${run.Errored__c ?? 0} with errors`,
        `${run.Rows_With_Warnings__c ?? 0} with warnings`
    ].join(' · ');
}

function confirmIngest(message) {
    return LightningConfirm.open({ message, label: 'Ingest Providers', theme: 'warning' });
}

function reduceError(error) {
    if (Array.isArray(error?.body)) {
        return error.body.map((e) => e.message).join(', ');
    }
    return error?.body?.message || error?.message || 'Unknown error';
}
