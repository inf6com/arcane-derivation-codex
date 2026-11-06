# Inline Formula Input Design

## Decision

There is no fixed formula pad, dedicated formula canvas, formula-only window, or second input box. The normal chat composer is the one editable surface for prose and mathematics. The same composer handles new messages and editing an existing message. “Magic pad” names the context-aware recognition and editing capability; it is not a visible pad widget. Assistance appears at the active caret or selection only when relevant and never moves the user's writing into a prescribed rectangle.

The application may show temporary candidate controls anchored to the active insertion point. It must not show a permanent blank canvas, duplicate preview editor, or detached formula entry region. A formula is typeset inline in the same message editor after its structure is confirmed and validated.

The text keyboard and graphic keyboard are both available within this same composer. The text keyboard enters ordinary Japanese, alphabetic text, and prose. The graphic keyboard provides mathematical symbols and graphical candidate choices at the active formula range; it is contextual and does not create a second editor or fixed canvas. The Firebird fairy is the visible, functional guide for that composition state. While the user is entering a mathematical range, it moves around that active range and presents graphical symbol/formula choices in a nearby speech bubble. These are provisional graphics, not committed MathML. Tapping a choice fixes only that selected symbol as a MathML node in the working expression; the user can continue typing ordinary letters, prose, or additional mathematics in the same composer. Finalizing the expression validates its structure and replaces only the active range with inline MathML. The fairy and bubble must track the active range, stay clear of the text and caret, and communicate available choices rather than act as decoration.

## IME-style formula composition

Formula conversion operates during input, like Japanese IME conversion. It is a temporary composition state attached to the active range in the ordinary chat composer, not a post-entry-only command and not another editor. When mathematical intent is established, the range shows provisional symbol and structure candidates. The user can revise candidates and nested structure there, then explicitly commit or cancel. Commit replaces only that range with validated inline MathML; cancel restores the original text and selection. Normal prose and Japanese IME composition continue to work without being captured as mathematics.

For keyboard input, the composition owns only the text/range explicitly identified as mathematical input. For Pencil, finger, or pointer input, it additionally retains real stroke coordinates and sends those strokes through the declared handwriting model and position/similarity stages. Candidate updates remain provisional and are never persisted as confirmed message content. Composition state is bound to message identity and editor revision; stale inference cannot overwrite later edits.

## User operation contract

| Part | Contract |
|---|---|
| Input | Text-keyboard Japanese/alphabetic text, graphic-keyboard mathematical symbols and graphical candidates, pasted content, or Pencil/pointer strokes associated with the active insertion point or selection in the normal composer. Existing-message editing uses the same path. |
| Processing | Preserve message ID, caret/selection, editor revision, source context, and original strokes. Route actual stroke data to the selected handwritten formula engine; route typed prose and alphabetic input through ordinary editing. |
| Verified output | Keep graphical model candidates provisional. Expand shape-similar alternatives without coordinates, then apply the separate position stage to the expanded choices using original coordinates. Preserve the model ranking, similarity provenance, and position evidence separately. Tapping a speech-bubble choice fixes that symbol as a MathML node; validating the completed expression inserts it inline. |
| Saved artifact | Persist message content, inline MathML structure, source stroke evidence when handwritten, model/rule versions, candidate evidence, validation state, and optional source entity ID under User Setting Root. Reopen the same message in an editable state. |

The operation is incomplete if the input becomes only an image, if a symbol candidate is silently treated as a confirmed formula, if an old recognition result is inserted after the editor changed, or if the verified expression cannot be saved and reopened.

## Inline interaction

1. The user places the caret or selects a range in the normal composer, in a new message or an existing message being edited.
2. The user types, pastes, or writes there. Ordinary prose and Japanese IME conversion remain ordinary text unless mathematical intent is established.
3. On mathematical intent, the composer starts a temporary formula composition at that range and snapshots message ID, editor revision, selection, source context, input-spec version, and any stroke coordinates.
4. Recognition and structure construction update provisional graphical choices in a speech bubble beside the active range. For handwriting, the selected model returns ranked candidates; a coordinate-independent similarity stage expands those labels before the position stage applies original-coordinate evidence. Processing is cancellable and does not lock unrelated prose editing.
5. The user can tap a graphical choice to fix that symbol as a MathML node, correct it, continue entering prose or symbols, build nested structures, finalize the expression, or cancel. Until a choice is tapped it remains provisional and is not saved as confirmed message content.
6. Commit is accepted only if the originating message and editor revision still match. The structure editor validates MathML, then replaces only the composition range with one inline formula object. Surrounding prose, formatting, and source context remain intact.
7. On cancellation or stale revision, the prior text and selection are restored; stale candidates are not applied. The retained input can be retried or discarded explicitly.
8. The committed message and its formula evidence are saved and can be reopened. The inline formula can be selected to reopen the same structure editor, revised, revalidated, and committed in place.

The assistant may operate on the formula range or the whole message only when the user explicitly selects that scope. Context, paper/source IDs, and selection must not be widened or dropped silently.

## Recognition-engine connection

The composer depends on a versioned recognition-engine contract rather than a concrete Core ML model class. A compatible engine accepts canonical stroke data and returns stroke-group IDs, ranked vocabulary candidates, scores, and model/version identifiers. The contract fixes coordinate origin, axis direction, units, scale, trace boundaries, point validity, resampling, shape, dtype, and vocabulary identity. An incompatible model is rejected with its specific mismatch; it is not silently adapted through OCR or a fallback recognizer.

The existing Hinotori/Hinotori shape stage can be supplied through this contract. Position and similar-symbol handling remain downstream of shape recognition and consume the model's candidates plus original geometry; they may reorder candidates and add evidence but may not fabricate model scores or confirm a symbol. A future compatible recognizer can replace the engine without changing composer behavior. The engine boundary does not imply that a model is connected to the chat UI; that connection must be separately implemented and demonstrated end to end.

TexTeller's printed formula-crop API is a distinct image path. It is not the inline handwriting provider and must not be mislabeled as such.

## Mixed text and mathematics

- Plain prose and formulas coexist in one message body.
- Confirmed math is represented as a structured inline object, not raw caret/underscore pseudo-notation or a raster screenshot.
- Formatting operations (bold, marker, color) retain their selected text range and do not flatten or corrupt adjacent MathML.
- Selecting an existing inline formula reopens its composition and nested structure editor in the same message. Recommit replaces that object in place; it does not create a duplicate message or separate pad.
- Copying a source equation into the composer inserts at the current caret/selection and preserves its source entity ID; selecting a source item alone does not insert it.
- A user may leave a recognized formula provisional, discard it, or continue editing prose without losing original text or stroke evidence.

## Errors and recovery

- Missing model resources, input-contract mismatches, recognition errors, cancellation, stale editor revisions, candidate ambiguity, invalid MathML, and persistence errors remain distinct visible failures.
- Failures preserve the user's prior text and the original captured strokes. Unverified intermediate results are not saved as final content.
- Retry starts from the retained input and the specific failed stage; it does not clear or replace the surrounding message.
- Ordinary text entry remains available when the formula model is unavailable. No formula recognition success is claimed in that state.

## Acceptance evidence

The design is implemented only after evidence shows:

- no fixed or secondary formula pad is reachable in the Codex;
- typing, paste, and handwriting all target the normal composer at the active caret/selection;
- Japanese IME composition and formula composition coexist: ordinary Japanese conversion remains text, while mathematical intent enters a cancellable provisional formula composition at the current range;
- candidate updates remain provisional, and explicit commit/cancel correctly replaces or restores only the composition range;
- both a new message and an existing message edit use the same route;
- actual handwriting stroke evidence reaches the selected model with the declared input spec;
- model candidates, source coordinates, position/similarity evidence, and ambiguity are preserved;
- a user-confirmed nested expression is validated and typeset inline without losing surrounding text or formatting, and selecting that object reopens the same nested structure editor;
- cancellation, stale editor revisions, model failure, and validation failure preserve prior content and can be recovered;
- save and application restart restore the same message, formula structure, source context, and editability from User Setting Root.

Until all relevant evidence exists, report the behavior as unimplemented or unverified; do not call the composer-model connection complete merely because the model API is injectable or the app builds.

## Current implementation evidence (2026-11-02)

- The normal chat composer captures direct-touch, Apple Pencil, and indirect-pointer stroke geometry at the insertion location and sends the resulting `PKDrawing` to the existing Hinotori recognition path. Vision text OCR is not used for this route. This is a stroke-capture path, not proof of live IME-style formula composition during ordinary typing.
- Recognition candidates remain provisional and use the existing position/similarity evidence and nested-structure confirmation UI. The insertion is rejected if the composer text/range or source entity context changed while inference was running. The current path does not establish that candidates update as an IME-style composition while input is in progress.
- Confirmed output is MathML-validated, its original drawing/evidence is stored through `DerivationStore` below the User Setting Root, and an inline formula token is inserted at the captured UTF-16 selection in the same composer. `NSTextAttachmentViewProvider` renders the validated MathML inline; source LaTeX is not rendered as ordinary text. The token maps to the expression and MathML in the persisted chat record, and is expanded to LaTeX only when constructing the AI prompt.
- Source formula copy actions use the same inline MathML attachment path. The attachment is currently atomic in the text editor: selecting, deleting, replacing, and surrounding-text editing are available, but opening the formula's nested structure editor directly from that attachment is not yet implemented or verified.
- No fixed canvas, second editor, or detached white formula preview is used by this path. The normal text keyboard remains available.
- Verification performed in cycle 518: `swiftc -parse inf6/inf6LibraryView2.swift`, `git diff --check`, generic iOS `xcodebuild`, and the My Mac Designed for iPad destination build all succeeded with dedicated DerivedData and signing disabled. No Simulator was launched. The live rendering, text selection around attachments, save/reload, and real Designed for iPad interaction were not exercised, so these builds do not establish end-to-end UI completion.
- Remaining incomplete requirements: implement and verify IME-style provisional formula composition during input, including coexistence with Japanese IME; reopen and edit an existing inline formula's MathML structure in place; verify inline rendering and text formatting around attachments in the live Designed for iPad app; and exercise save/reload, commit/cancel, and stale-result recovery end to end. The magic-pad capability and application are not complete.
