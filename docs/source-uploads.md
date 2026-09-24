# Source document uploads

Workspace editors can upload PDF, Word (.docx), PowerPoint (.pptx), saved HTML, plain-text or Markdown documents from the shared knowledge workspace. Each upload stores the original file, a SHA-256 fingerprint and extracted text together as one immutable evidence version. The extracted text can be reviewed and cited without replacing the original record.

## Upload a document

1. Sign in and choose **Add document**.
2. Leave **Existing document** set to **Create a new document**.
3. Choose the workspace, document number, name, owner and classification.
4. Select other workspace members who need permission to read and cite the source.
5. Choose a file and select **Review extracted text** and then **Save reviewed source** after checking the preview.

After confirmation, the source becomes available in **Attach source evidence** on an SOP draft. The original file is limited to 10 MB. Files must contain readable text; encrypted PDFs, image-only PDFs, legacy .doc/.ppt files, and scanned Office documents without text are not supported. Saved HTML is parsed as text without scripts or styling. Live website fetching and meeting-service connectors are future work.

## Add a newer source version

Choose **Add document**, select an existing document, and upload its newer file. Knowledge Catalog creates the next numbered version and leaves every earlier version unchanged. Existing SOP citations continue pointing to the exact evidence version that was reviewed. A revised SOP can deliberately attach the newer source version.

## Access and governance

Only an authenticated human with edit access to the selected workspace can upload. The uploader always receives source access. Other selected people must already have access to that workspace. Organization isolation, row-level security and the source access list apply to the artifact and all its versions.

The source document records its owning workspace, human owner, active governed classification and configuration revision. Effective dates describe when the source applies; they do not silently remove existing citations. Raw file bytes stay behind the application boundary and are omitted from workspace API responses.

The current local implementation stores files in PostgreSQL so the transaction, hash and immutable history remain testable together. A production object-storage adapter can later replace the byte storage while retaining provider-independent identifiers, hashes, access checks and version semantics.

## Browse the Source Library

Open **Library** in the workspace to search document numbers, names, file names and extracted text. A document page shows its owner, classification, workspace, effective dates, fingerprints and every version you may read. Earlier versions are labeled superseded; a version past its end date is labeled expired. The **Cited by** section links to SOP versions you are allowed to see, and identifies versions with no visible citations.

Workspace editors who already have source access can upload a newer version or open **Manage readers**. The reader list contains active members of that workspace. Giving or removing access updates all versions immediately, including visibility of SOPs that cite the source. The editor cannot remove their own access or the source owner's access. Changes are audited. The Source Library does not yet provide a separate download of the original file; it shows extracted text and original-file fingerprints.
