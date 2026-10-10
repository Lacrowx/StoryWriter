# StoryWriter

A native, local-first Mac app for writing stories and collecting reference material. Requires macOS 14 or later. This initial build is for Apple Silicon; the Swift sources also support compiling on an Intel Mac.

## Open the app

Open `dist/StoryWriter.app`. You can move the app into your Applications folder. A sample story, **The House at Low Tide**, demonstrates the layout; create your own with **File → New Story** or ⌘N.

## A place for the whole story

- **Write:** formatted chapter editor, searchable outline, chapter synopses, drafting status, word counts, and focus mode (⇧⌘F). Reorder chapters by dragging, or use a chapter's right-click menu. That menu also duplicates chapters and changes their status.
- **Story:** premise, full synopsis, themes, author or pen name, genre, audience, word goal, and publishing notes.
- **Characters:** appearance, voice, wants and needs, conflicts, secrets, character arcs, relationships, and continuity notes.
- **World:** places, culture, history, objects, rules and systems, and connections to the manuscript.
- **References:** imported files, web links, and research notes, with titles, tags, and searchable annotations.

Use **File → New Reference Collection** (⇧⌘N) to collect sources without creating a manuscript. Rename stories or collections through the project menu next to Export. Archive a project from that menu or its library right-click menu; archived projects remain available through **Archived projects**.

## Formatted writing

Right-click in the manuscript, planning fields, project lists, or workspace to reach app functions and **Settings…**. The manuscript menu adds passage comments, scene splitting, chapter status, proofreading, formatting, and character/world tags alongside standard Mac editing commands. Shared submenus provide navigation, writing panels, reading controls, project search, saving, revision history, export, backups, and review settings. Right-click within selected text to keep that passage selected; unavailable actions are disabled. Existing list menus retain their item-specific actions.

The writing workspace uses a warm paper surface with subtle grain and a soft shadow. The sheet and formatting toolbar fill the available workspace, including in focus mode; text reflows with the window and keeps modest paper margins. Translucent sidebars and floating controls surround the manuscript. On macOS 26 and later, the controls use native Liquid Glass; earlier macOS versions use standard translucent materials. The interface follows the system appearance and Reduce Transparency setting. Paper styling is only part of the editor and is excluded from exports.

Select text to change its font, size, bold (⌘B), italic (⌘I), underline (⌘U), alignment, spacing, or heading style. The font menu opens the Mac font panel for additional fonts. The toolbar also inserts bullet and numbered lists; its additional options add links, strikethrough, text color, and highlighting. Paste formatted text from Word, or drop an image into the editor. Undo and redo use the standard Mac Edit menu and shortcuts.

The magnifying glass opens native find and replace inside the current chapter (⌘F). **Find in manuscript** filters the outline by chapter title, synopsis, and body text. Chapter notes and status are behind the notes icon beside the chapter title.

Import chapters through the outline's + menu. Supported chapter imports are DOCX, RTF, RTFD, HTML, UTF-8 text, and Markdown. Markdown imports currently preserve the source as plain text, rather than interpreting its syntax.

## Tagging objects in your writing

Type **@** in a chapter to find characters, locations, items, and other world entries from the current project. Keep typing to narrow the suggestions; use the arrow keys and Return or Tab to choose an object, or click a suggestion. Escape closes the suggestions.

The **tag icon** in the formatting toolbar also offers the existing objects in grouped submenus. Select existing words before choosing an object to tag a nickname or phrase without changing its wording or formatting. Otherwise, the object's name is inserted.

Click tagged text to view and edit its project details inside the writing window. Option-click places the cursor for editing the prose. **Remove tag from selection** removes the connection while keeping the text. Connections survive saving, portable copies, and renaming the object; renaming does not rewrite the prose. If an object is deleted, its tagged words remain and the details panel explains that the object is missing.

Manuscript exports and **Copy formatted chapter for website** keep the visible words and omit internal project links. Ordinary website links retain their usual behavior.

After a short pause, local name recognition checks prose and notes for unfamiliar people and places. Purple dashed marks and a **new names** button offer **Create character**, **Create location**, **Create item**, or **Ignore this name in this project**. Creating an object opens its details with the name filled in; it does not rewrite the passage or invent profile details. Existing full names and character first names or surnames are recognized from the project's records.

Ignored names are saved with the project and portable copies. **Suggest ignored names again** in the project menu restores these suggestions. Recognition can miss invented or ambiguous names; typing **@Name** with no matching object offers the same creation choices manually and tags the inserted name. This local recognition also works when AI grammar review is unavailable.

## Sources and media

Add files using **References → + → Add files**, or drop files into the reference workspace. Files are copied into the project. Moving or deleting the original does not affect the imported copy.

Mac Quick Look previews supported images, PDFs, documents, audio, and video inside the app. Playback and preview support depend on the formats and codecs macOS can open. The source menu also opens the imported file in its default app or shows it in Finder. Imported files remain in their original formats.

Web links open in an embedded browser. Once a page finishes loading, **Save page offline** keeps a web archive of the loaded page and its available resources. Switch **Saved copy** off to view the live website. Login-dependent pages and dynamic services may not work fully from an offline archive. Link-only references require an internet connection.

## Saving and portable projects

Edits autosave shortly after you stop typing. The bottom bar reports whether saving succeeded. ⌘S saves immediately. Quitting also saves, and a failed save keeps the app open unless you choose to discard unsaved changes.

Your working library is stored in:

`~/Library/Application Support/StoryWriter/Projects/`

Each `.storywriter` project is a package containing a readable `project.json` manifest, formatted chapter data, original reference files in `Media`, offline web archives, and saved revisions in `History`. The app retains up to 30 previous saves, taking a checkpoint roughly every five minutes while a project changes. Open **Saved revisions** from the project menu to restore one; the current saved state is checkpointed before restoration. Reference files are retained when a reference is removed so older revisions still work.

**File → Save Portable Copy** (⇧⌘S) creates a complete project snapshot at a location you choose. Copy that `.storywriter` package to another Mac, an external drive, or a backup folder. **File → Open Project** imports a separate working copy into the app's local library. Edits to that working copy do not update the external snapshot. Save a new portable copy when you want to refresh your backup.

Autosave and local revisions are convenient recovery tools, not a substitute for a backup on another drive.

## Publishing

**Export** (⇧⌘E) exports the whole story or current chapter as:

- Word (DOCX)
- PDF
- EPUB 3, with chapter navigation
- HTML, with inline images
- Markdown
- Rich text (RTF)
- Plain UTF-8 text

Planning notes and sources are excluded from manuscript exports. The clipboard icon beside the chapter title copies plain text, rich text, and HTML together, letting publishing websites choose their supported format. The website controls which formatting it retains. Markdown preserves emphasis, underline as HTML, strikethrough, links, and images; it cannot represent every Word layout feature. EPUB is a reflowable publication, rather than a fixed page layout.

## English / German grammar and style review

Mac spelling marks work without a model. Set the writing language under **StoryWriter → Settings**: Automatic, English, or Deutsch. Local AI review covers chapter text and titles, story planning, character profiles, worldbuilding, and reference notes.

Choose **Osaurus · local server** or **Apple · on-device** in Settings or the chapter's writing-review panel. **Suggest style improvements** is enabled by default; switch it off to request spelling and grammar corrections alone.

- **Osaurus:** start its local API server, then refresh and select an installed local model. The default address is `http://127.0.0.1:1337/v1`. StoryWriter connects only to loopback addresses, refuses redirects, and lists locally owned models. It does not download models or run agent tools.
- **Apple:** uses Apple's Foundation Models framework directly on this Mac, without an Osaurus server. Requires macOS 26 or later, a compatible Mac, enabled Apple Intelligence, and a ready on-device model. The app displays availability or language-support problems. Apple's model may decline some passages; the app reports that rather than changing your writing.

### Your project's writing brief

Choose **AI writing brief…** from the project menu next to Export, or edit **AI writing brief** in the Story tab. Describe your preferred tone, tense, point of view, pacing, dialogue, and language. Explain the subject and details you want the editor to preserve. The brief is saved with your project and included in portable copies.

Reviews include the brief plus short summaries of the premise, synopsis, chapter, and world. Each passage searches every project character record by name, including characters added later in the list. Matching character names, author-specified pronouns, and short profile summaries are sent as authoritative context. Names absent from the project are preserved as written rather than replaced with a similar cast member. Osaurus receives up to 3,000 brief characters and 3,500 background characters. Apple receives up to 1,500 brief characters and 1,800 background characters to fit its smaller context. These are bounded summaries, not the entire manuscript or your reference attachments.

### Reviewing and accepting suggestions

1. With automatic review enabled, pausing for two seconds after editing reviews the changed paragraph. The **Auto** switch or Settings turns this off.
2. Suggestions appear directly in the edited field: orange dotted marks for spelling and grammar, blue for style. Click a marked passage, or the suggestion count, to see the original, proposed replacement, category, and explanation.
3. **Accept** or **Dismiss** handles one suggestion. Accepting a suggestion opens the next pending suggestion in the same field, wrapping to earlier pending suggestions when necessary; the card closes when the last one is accepted. The field's **Accept** menu handles pending suggestions in the sentence, paragraph, selected passage, or entire field. A batch is one Undo action; formatting is retained where the wording stays unchanged.
4. The **Review** menu checks a sentence, paragraph, selection, or entire field on demand. The chapter's writing-review button opens the larger panel with language, backend, and model controls. Long texts are reviewed in consecutive sections.
5. Choose **Review entire manuscript** from the project menu to review all chapters, then accept individually, by chapter, or across the manuscript. **Undo last acceptance** reverses the latest batch; saved revisions provide additional recovery.

The model proposes a revised passage, which the app converts into sentence-level suggestions. Whitespace-only model edits (such as trimming a trailing space) are ignored, so unchanged wording does not produce a correction card. Responses explicitly reporting that no corrections are needed in English or German are also rejected as edits, even if the model inconsistently rewrites the text. A native spelling check also supplements recognizable repeated-letter typos such as **Kindd → Kind**, while protecting character names and world titles. These marks are temporary and excluded from saved writing and exports. Later edits invalidate affected suggestions; whole-manuscript acceptance stops if the reviewed chapter changed.

Both backends check proposed edits against project names and detected personal names. Isolated name or gender-pronoun substitutions are removed while independent grammar edits remain; more complex identity-changing rewrites are discarded. Editing character records invalidates previous review suggestions. This does not check every kind of story continuity or guarantee perfect model accuracy.

All AI review is local and all proposed edits require acceptance. **No suggestions returned** means the model offered no changes, not that the passage is error-free. Accuracy varies: testing found that both small Osaurus models and Apple's model can miss German idioms or propose wording that changes an action or pronoun reference. Inspect the replacement before accepting it. Errors and unavailable models leave writing and saving available.

References: [Osaurus API guide](https://github.com/osaurus-ai/osaurus/blob/main/docs/OpenAI_API_GUIDE.md), [Apple Foundation Models](https://developer.apple.com/documentation/foundationmodels).

## Build and verification

No external Swift dependencies. Xcode or its command-line tools are required to rebuild.

```sh
zsh scripts/build-app.sh
zsh scripts/test.sh
```

The build script creates a release app in `dist`, generates its icon, and signs it locally. It uses a temporary build directory to work within restricted workspace environments. This personal build is locally signed, not notarized for public distribution.

The tests cover rich text and imported references surviving save/reopen and portable import, revision restoration, source-only collections and debounced autosave, corrupt-file preservation, all publication exports, formatting/correction undo, safe media paths, local endpoint validation, model filtering, exact correction matching, saved project briefs and bounded story context, revision-to-suggestion conversion, repeated-letter spelling checks, Unicode-safe long-document review, inline annotation rebasing, grouped acceptance and undo, preservation of formatting, and whole-manuscript acceptance with stale-text protection.

Set `STORYWRITER_DATA_DIR` when launching the executable to use a separate library for development or testing.

Optional live model checks exercise English/German corrections, the screenshot passage, and style changes. These are quality checks: a model can connect successfully but fail to catch an idiom or preserve meaning. Choose an installed Osaurus model with `STORYWRITER_TEST_MODEL`:

```sh
STORYWRITER_TEST_OSAURUS=1 zsh scripts/test.sh --filter testLiveOsaurusEnglishAndGerman
STORYWRITER_TEST_OSAURUS=1 STORYWRITER_TEST_MODEL=qwen3.8-27b-jang_4d zsh scripts/test.sh --filter testLiveGermanScreenshotAndWritingStyle
STORYWRITER_TEST_APPLE=1 zsh scripts/test.sh --filter testLiveAppleOnDeviceWritingReview
```

## Connected writing tools

- **Beside your writing:** the sidebar button beside the chapter title opens Research, Scenes, and Notes. Choose a character, world entry, or reference to pin it beside your manuscript. Clicking an object tag opens its details in this panel. Characters, world entries, and reference lists also offer **Pin beside manuscript** in their right-click menus.
- **Aliases and appearances:** character and world profiles accept comma-separated aliases. Tag suggestions and local name recognition understand those aliases. **Appears in** lists explicitly tagged passages and name matches separately; click an entry to select that passage. A name match is a navigation aid, not proof of the character's identity.
- **Passage search:** the outline now shows matching passage previews rather than only filtering chapter titles. **Search** at the top of the project (⇧⌘G) also finds character profiles, world details, and reference notes. Choose a result to open and select its matching text.
- **Scenes:** open the writing panel's Scenes tab. Place the cursor inside a chapter and choose **Split at cursor**, or add a single scene for the entire chapter. Scene cards offer Move earlier/later, Merge with previous, and details for synopsis, viewpoint, location, status, story time, and timeline order. Moving scenes preserves formatted text, tags, and comments, adding paragraph spacing at new joins when needed. Splitting and merging preserve the continuous manuscript; scene labels are not added to exports.
- **Passage comments:** select text and use the speech-bubble menu or right-click **Add comment to selection**. A handwritten note opens in the page margin beside its passage; type there to edit it. Colored pencil underlines and loose hand-drawn connecting lines link notes to the prose. Use the small colored dot to choose Rose, Blue, Green, or Amber ink, and the checkmark to resolve a note. The writing column leaves room for side notes, and closely spaced comments stack without covering text. The **View → Pencil comments on page** toggle hides the layer. Notes also lists comments by chapter or across the project. Edits before a passage move its anchor. If the passage itself changes, the note stays in the queue for reattachment and leaves the page. Resolved notes remain available in the queue. Comments and the space they occupy on screen are excluded from manuscript exports.
- **Reading view:** the formatting toolbar's **View** menu offers Narrow, Medium, or Full width, display zoom from 75% to 150%, and dim paper. These settings affect the writing display without changing saved font sizes, text colors, or exports. On narrower windows, opening the writing panel temporarily hides the chapter outline to leave space for the manuscript.
- **Quieter proofreading:** planning and research fields retain inline marks and small suggestion badges. A single review strip follows the currently focused field, instead of repeating the full review toolbar beneath every field.

## Revision comparisons and recovery

**Saved revisions** now previews a saved chapter and highlights changes from that save to the current chapter. Select text in the saved preview and **Recover selection** to append its original formatting to a chosen current chapter. **Recover this chapter** replaces only that chapter (or restores it if deleted); **Restore entire project** recovers the whole saved project. Current work is checkpointed first.

Name a checkpoint to keep a recognizable milestone. The app retains 30 automatic revisions and does not automatically prune named checkpoints. Named checkpoints travel in portable copies. Imported portable projects still start a new local history because their project identifier changes.

## Automatic portable backups

Use the project menu's **Choose automatic backup folder** to opt into dated portable copies. Backups run after a successful save, at most about every five minutes while the project changes, with a first copy after setup. **Back up now** requests an immediate copy. The bottom bar shows the last successful backup time or a failure indicator; the project menu shows the full status.

Choose a folder separate from the app library, preferably on another drive. A backup becomes visible only after its copy and manifest validation finish; a missing drive or failed copy leaves the working project intact. Copies include research files and history. Dated backups are retained until you remove them. The selected folder and backup status are local to this Mac and are not imported with portable projects. Automatic backups can be turned off in the project menu.

## Story timeline

Open **Story timeline** from the project menu. Scene events are sorted by their optional timeline number, independently of their order in the manuscript. **Story time** can describe dates, times, or relative events such as “Day 2 · morning.” Unnumbered scenes appear after numbered scenes in manuscript order. Use Details to change an event or Go to scene to return to its passage. Chapters without scene metadata can be initialized as one scene each.
