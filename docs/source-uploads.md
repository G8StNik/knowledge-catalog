# Source document uploads

Workspace editors can upload a PDF, plain-text or Markdown document from the SOP workspace. Each upload stores the original file, a SHA-256 fingerprint and extracted text together as one immutable evidence version. The extracted text can be reviewed and cited without replacing the original record.

## Upload a document

1. Sign in and choose **Upload source**.
2. Leave **Existing document** set to **Create a new document**.
3. Choose the workspace, document number, name, owner and classification.
4. Select other workspace members who need permission to read and cite the source.
5. Choose a file and select **Upload immutable version**.

The source immediately becomes available in **Attach source evidence** on an SOP draft. The original file is limited to 10 MB. Files must contain readable text; encrypted PDFs and image-only PDFs are rejected until an approved OCR service is added.

## Add a newer source version

Choose **Upload source**, select an existing document, and upload its newer file. Knowledge Catalog creates the next numbered version and leaves every earlier version unchanged. Existing SOP citations continue pointing to the exact evidence version that was reviewed. A revised SOP can deliberately attach the newer source version.

## Access and governance

Only an authenticated human with edit access to the selected workspace can upload. The uploader always receives source access. Other selected people must already have access to that workspace. Organization isolation, row-level security and the source access list apply to the artifact and all its versions.

The source document records its owning workspace, human owner, active governed classification and configuration revision. Effective dates describe when the source applies; they do not silently remove existing citations. Raw file bytes stay behind the application boundary and are omitted from workspace API responses.

The current local implementation stores files in PostgreSQL so the transaction, hash and immutable history remain testable together. A production object-storage adapter can later replace the byte storage while retaining provider-independent identifiers, hashes, access checks and version semantics.
