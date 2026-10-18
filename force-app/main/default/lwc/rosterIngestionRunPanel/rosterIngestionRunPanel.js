import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { RefreshEvent } from 'lightning/refresh';
import LightningConfirm from 'lightning/confirm';
import getActiveRun from '@salesforce/apex/RosterIngestionRunController.getActiveRun';
import startRun from '@salesforce/apex/RosterIngestionRunController.startRun';
import cancel from '@salesforce/apex/RosterIngestionRunController.cancel';

const POLL_INTERVAL_MS = 3000;

/* The wording for each file type. listLabel must match the related list's label on the page. */
const LABELS = {
    Personnel: {
        title: 'Provider Ingestion',
        startLabel: 'Ingest Providers',
        confirmMessage: 'Ingest the latest version of the personnel file? Providers will be created and updated.',
        listLabel: 'Provider Ingestion Runs'
    },
    Relationships: {
        title: 'Relationship Ingestion',
        startLabel: 'Ingest Relationships',
        confirmMessage:
            'Ingest the latest version of the relationships file? Relationships between Providers and facilities will be created and terminated.',
        listLabel: 'Relationship Ingestion Runs'
    }
};

/**
 * Ingestion control panel for one of the roster's files (the fileType property,
 * set in App Builder): starts and cancels runs of that file and shows the active
 * run's progress, refreshing every few seconds. Finished runs are listed by a
 * standard related list on the same page.
 */
export default class RosterIngestionRunPanel extends NavigationMixin(LightningElement) {
    @api recordId;
    @api fileType = 'Personnel';

    activeRun;
    busy = false;
    error;
    pollTimer;

    connectedCallback() {
        this.loadActiveRun();
    }

    disconnectedCallback() {
        this.stopPolling();
    }

    // Re-queried (not cached) and polled while a run is active, since it progresses in the background.
    loadActiveRun = async () => {
        const previousRun = this.activeRun;
        try {
            this.activeRun = await getActiveRun({ recordId: this.recordId, fileType: this.fileType });
            this.error = undefined;
        } catch (e) {
            this.error = reduceError(e);
        }
        if (previousRun && previousRun.Id !== this.activeRun?.Id) {
            this.handleRunEnded(previousRun);
        }
        this.updatePolling();
    };

    get labels() {
        return LABELS[this.fileType] ?? LABELS.Personnel;
    }

    get idleMessage() {
        return `No ingestion in progress. Finished runs are listed in ${this.labels.listLabel}.`;
    }

    get startDisabled() {
        return this.busy || Boolean(this.activeRun);
    }

    get hasTotal() {
        return this.activeRun?.Total_Rows__c != null;
    }

    get percentDone() {
        const total = this.activeRun?.Total_Rows__c;
        return total ? Math.round(((this.activeRun.Rows_Processed__c ?? 0) * 100) / total) : 0;
    }

    get progressSummary() {
        const run = this.activeRun;
        return [
            `${run.Rows_Processed__c ?? 0} of ${run.Total_Rows__c} rows`,
            `${run.Inserted__c ?? 0} inserted`,
            `${run.Updated__c ?? 0} updated`,
            ...(this.fileType === 'Relationships' ? [`${run.Terminated__c ?? 0} terminated`] : []),
            `${run.Unchanged__c ?? 0} unchanged`,
            `${run.Errored__c ?? 0} with errors`,
            `${run.Rows_With_Warnings__c ?? 0} with warnings`
        ].join(' · ');
    }

    // A run that leaves the panel has finished, failed or been cancelled: refresh the page's
    // standard components so it appears in the runs list and the header counts.
    // A cancel (busy) already has its own toast.
    handleRunEnded(run) {
        this.dispatchEvent(new RefreshEvent());
        if (!this.busy) {
            this.toast('info', `${run.Name} has finished. See ${this.labels.listLabel} for the result.`);
        }
    }

    updatePolling() {
        if (this.activeRun && !this.pollTimer) {
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this.pollTimer = setInterval(this.loadActiveRun, POLL_INTERVAL_MS);
        } else if (!this.activeRun) {
            this.stopPolling();
        }
    }

    stopPolling() {
        clearInterval(this.pollTimer);
        this.pollTimer = undefined;
    }

    async handleStart() {
        const confirmed = await LightningConfirm.open({
            message: this.labels.confirmMessage,
            label: this.labels.startLabel,
            theme: 'warning'
        });
        if (confirmed) {
            await this.act(() => startRun({ recordId: this.recordId, fileType: this.fileType }), 'Ingestion started.');
        }
    }

    async handleCancel() {
        await this.act(() => cancel({ runId: this.activeRun.Id }), 'Run cancelled. Rows already processed stay processed.');
    }

    async act(action, successMessage) {
        this.busy = true;
        try {
            await action();
            this.toast('success', successMessage);
        } catch (e) {
            this.toast('error', reduceError(e));
        }
        await this.loadActiveRun();
        this.busy = false;
    }

    handleOpenRun(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: this.activeRun.Id, objectApiName: 'RosterIngestionRun__c', actionName: 'view' }
        });
    }

    toast(variant, message) {
        const titles = { success: this.labels.title, info: this.labels.title, error: 'Action failed' };
        this.dispatchEvent(new ShowToastEvent({ title: titles[variant], message, variant }));
    }
}

function reduceError(error) {
    if (Array.isArray(error?.body)) {
        return error.body.map((e) => e.message).join(', ');
    }
    return error?.body?.message || error?.message || 'Unknown error';
}
