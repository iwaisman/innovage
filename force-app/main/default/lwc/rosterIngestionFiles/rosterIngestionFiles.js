import { LightningElement, api } from 'lwc';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getFiles from '@salesforce/apex/RosterIngestionFileController.getFiles';
import attachUploadedFile from '@salesforce/apex/RosterIngestionFileController.attachUploadedFile';
import discardUpload from '@salesforce/apex/RosterIngestionFileController.discardUpload';

// fileType values must match the keys in RosterIngestionFileController.FIELD_BY_TYPE
const FILE_TYPES = [
    { fileType: 'personnel', label: 'Personnel File' },
    { fileType: 'relationships', label: 'Relationships File' }
];

export default class RosterIngestionFiles extends NavigationMixin(LightningElement) {
    @api recordId;

    files = {};
    fileUrls = {};
    busyTypes = new Set();
    error;

    connectedCallback() {
        this.loadFiles();
    }

    // getFiles is not cacheable on purpose: new versions are uploaded on the file page,
    // so the component must re-query whenever it is shown or refreshed.
    loadFiles = async () => {
        try {
            this.files = await getFiles({ recordId: this.recordId });
            this.error = undefined;
            await this.generateFileUrls();
        } catch (e) {
            this.error = reduceError(e);
        }
    };

    async generateFileUrls() {
        const entries = await Promise.all(
            Object.values(this.files).map(async (file) => [
                file.contentDocumentId,
                await this[NavigationMixin.GenerateUrl](filePageRef(file.contentDocumentId))
            ])
        );
        this.fileUrls = Object.fromEntries(entries);
    }

    get slots() {
        return FILE_TYPES.map(({ fileType, label }) => {
            const file = this.files[fileType];
            return {
                fileType,
                label,
                busy: this.busyTypes.has(fileType),
                uploadLabel: `Upload ${label.toLowerCase()}`,
                file: file && {
                    ...file,
                    url: this.fileUrls[file.contentDocumentId],
                    fileName: file.fileExtension ? `${file.title}.${file.fileExtension}` : file.title
                }
            };
        });
    }

    async handleUploadFinished(event) {
        const fileType = event.target.dataset.fileType;
        const [uploaded] = event.detail.files;
        if (!uploaded) {
            return;
        }

        this.setBusy(fileType, true);
        try {
            await attachUploadedFile({
                recordId: this.recordId,
                fileType,
                contentDocumentId: uploaded.documentId
            });
            await this.loadFiles();
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            this.toast('success', `${uploaded.name} uploaded.`);
        } catch (e) {
            // The upload itself succeeded, so remove the stray document before reporting.
            await discardUpload({ contentDocumentId: uploaded.documentId }).catch(() => {});
            this.error = reduceError(e);
            this.toast('error', this.error);
        } finally {
            this.setBusy(fileType, false);
        }
    }

    handleOpenFile(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate](filePageRef(event.currentTarget.dataset.documentId));
    }

    setBusy(fileType, busy) {
        const next = new Set(this.busyTypes);
        if (busy) {
            next.add(fileType);
        } else {
            next.delete(fileType);
        }
        this.busyTypes = next;
    }

    toast(variant, message) {
        this.dispatchEvent(
            new ShowToastEvent({ title: variant === 'success' ? 'File saved' : 'Upload failed', message, variant })
        );
    }
}

/** The standard file detail page, which has the "Upload New Version" action. */
function filePageRef(contentDocumentId) {
    return {
        type: 'standard__recordPage',
        attributes: { recordId: contentDocumentId, objectApiName: 'ContentDocument', actionName: 'view' }
    };
}

function reduceError(error) {
    if (Array.isArray(error?.body)) {
        return error.body.map((e) => e.message).join(', ');
    }
    return error?.body?.message || error?.message || 'Unknown error';
}
