# StoryWriter

A native, local-first Mac app for writing stories and collecting reference material. Requires macOS 14 or later. GitHub releases include a universal app for Apple Silicon and Intel Macs.

## Downloads and app updates

Download the ZIP from the [latest release](https://github.com/Lacrowx/StoryWriter/releases/latest), extract it, and move **StoryWriter.app** into Applications. Install this release once to add the updater to older builds.

Choose **StoryWriter → Check for Updates…** to find, download, and install a newer version. **Settings → App updates** controls automatic checking and automatic download/installation, both enabled by default. Background checks run about once a day; downloaded updates finish installing when the app quits. StoryWriter saves before quitting, and a failed save keeps the app open unless you explicitly discard the unsaved changes. Projects remain in the app's separate local library.

Updates use [Sparkle](https://sparkle-project.org/documentation/). Both the update feed and app archive carry Ed25519 signatures, verified with the public key bundled in the app. The updater contacts GitHub for releases; writing, project files, and AI review remain local.

These builds are ad-hoc signed and are not Apple-notarized. On the first download, macOS may require you to approve the app in **System Settings → Privacy & Security**. A Developer ID certificate and notarization are required for distribution without that first-install warning; certificates also disclose the registered developer identity.

## Character continuity beside your manuscript

Open the writing sidebar and choose **Continuity**, or choose **Character continuity** in the project menu. The panel follows your cursor and the current scene's viewpoint; choose another character to pin their snapshot. **Knows**, **Has**, **Needs to do**, and **Must follow** show recorded information at that point. With no scene viewpoint, the panel names the first character it is displaying. Finished tasks and past possessions can be shown with **Show finished and past items**.

Select a manuscript passage and right-click **Track a character change** for actions such as **Maya learns this…**. **Track something** in the sidebar also records a change at the cursor. Find and select an existing shared item before creating another. Names, alternate names, descriptions, and overlapping words help find possible matches; suggested matches are not automatic semantic judgments. Exact names and alternate names reuse the existing identity. Vague words such as “history” show candidates without silently choosing one.

**Has** also lists items already defined under **World**, labeled **World item**. Choose one directly instead of recreating it. An existing tracked possession with an unambiguous matching name or alternate name keeps its passage history. Linked names and alternate names follow the World profile. An item becomes a character possession only after you save a **Gets** change; merely defining it or opening the picker does not assign it to anyone.

Changes apply after their selected source passage, or at the cursor for an empty selection. **Before the story** records starting conditions. **Planned for this chapter** stays separate from established state until attached to a passage. The same character cannot learn already-known information again; choose **Is reminded**, **Confirms**, or track a separate detail of the topic. Beliefs and suspicions are labeled distinctly from learned information. Learning a topic does not automatically grant every detail recorded beneath it.

Click an entry, or **All items**, to see each character's first recorded learning or acquisition and the full passage history. Edit the shared name and alternate names there. **Merge this item with…** combines duplicate identities while preserving both histories. Use an entry's action menu to complete tasks, record losses, give possessions to another character, or add a new detail. Breaking a rule does not release the character from it.

Continuity follows scene timeline numbers when present, with chapter/scene order as the fallback, matching **Story timeline**. Set scene timeline numbers for flashbacks. Passage anchors move with edits before them and scene reordering; a changed or deleted source is marked **Needs review** and excluded from established state until reattached through its history menu. Continuity records autosave, survive portable copies and revisions, and stay out of manuscript exports. Chapter recovery restores missing shared items from the same revision.

## Open the app

Open `dist/StoryWriter.app`. You can move the app into your Applications folder. A sample story, **The House at Low Tide**, demonstrates the layout; create your own with **File → New Story** or ⌘N.

## A place for the whole story

- **Write:** formatted chapter editor, searchable outline, chapter synopses, drafting status, word counts, and focus mode (⇧⌘F). Reorder chapters by dragging, or use a chapter's right-click menu. That menu also duplicates chapters and changes their status.
- **Story:** premise, full synopsis, themes, author or pen name, genre, audience, word goal, and publishing notes.
- **Characters:** appearance, voice, wants and needs, conflicts, secrets, character arcs, relationships, and continuity notes.
- **World:** places, culture, history, objects, rules and systems, and connections to the manuscript.
- **References:** imported files, web links, and research notes, with titles, tags, and searchable annotations.

Use **File → New Reference Collection** (⇧⌘N) to collect sources without creating a manuscript. Rename stories or collections through the project menu next to Export. Archive a project from that menu or its library right-click menu; archived projects remain available through **Archived projects**.

## Make StoryWriter your own

Open **StoryWriter → Settings…** (⌘,). Six sections keep preferences together, with changes saved automatically on this Mac:

- **General:** reopen the last project/chapter/workspace or start in the library; start in focus mode; show the chapter outline, focus-mode status bar, and passage-selection quick actions.
- **Appearance:** System/Light/Dark appearance, five accent colors, translucent or opaque chrome, Warm/White/Sepia paper, dim paper, paper grain, reading width, display zoom, margins, and pencil comments. A paper preview follows your choices. macOS Reduce Transparency takes priority.
- **Editor:** default font family, size, and line spacing for empty chapters and the Body style; native spelling/grammar checks, automatic spelling correction, smart quotes/dashes, and website detection in manuscript and planning fields. Existing formatted passages and older plain-text chapters keep their typography.
- **Writing Review:** English/German language, local backend and model, automatic review and its 1–10 second delay, style suggestions, name recognition, and Osaurus connection controls.
- **Saving & Sync:** reveal the local library; choose the autosave delay, automatic revision interval, and backup interval; manage the selected project's portable backup folder and iCloud Drive sync. ⌘S saves immediately and quitting still saves first. Intervals apply to subsequent saves or scheduled backups; revisions and backups run only when writing changes.
- **Updates:** automatic update checks/downloads and a manual check.

General, Appearance, Editor, and saving timings have their own reset buttons. Resets preserve project data, backup folders, sync connections, and review/update choices. Preferences stay outside portable projects and revisions. Hiding the focus status bar still shows save failures, backup errors, and sync conflicts. Display changes never alter exported manuscript formatting.

## Formatted writing

The Mac menu bar now includes **Project**, **Navigate**, and **Writing** for the active project. The labeled **Project** menu beside Export uses the same actions, with saved revisions and automatic backups in their own submenus. **View** contains **Enter / Exit Focus Mode** (⇧⌘F) and manuscript display settings; **Edit → Find in Project** (⇧⌘G) also works in focus mode.

Beside the chapter title, **Chapter** contains notes, drafting status, passage comments, and copy for website. **Sidebar** chooses research, scenes, comments, or continuity; **Review** offers passage/chapter/manuscript review and its settings. Checkmarks identify the open panels and enabled review options. The chapter and formatting controls use compact icons when space is tight, retaining their labels for accessibility and their hover hints.

Right-click in the manuscript, planning fields, project lists, or workspace to reach app functions and **Settings…**. The manuscript menu adds passage comments, scene splitting, chapter status, proofreading, formatting, and character/world tags alongside standard Mac editing commands. Shared submenus provide navigation, writing panels, reading controls, project search, saving, revision history, export, backups, and review settings. Right-click within selected text to keep that passage selected; unavailable actions are disabled. Existing list menus retain their item-specific actions.

The workspace uses consistent system typography, neutral menu labels, and clearly selected navigation tabs. Story, character, world, and research fields share rounded cards and focus outlines; every sidebar search has a clear button. Utility sheets use the same spacing and surfaces, with explanatory empty states. Green accents mark objects, progress, and active controls.

The writing workspace uses a warm paper surface with subtle grain and a soft shadow. The sheet and formatting toolbar fill the available workspace, including in focus mode; text reflows with the window and keeps modest paper margins. Translucent sidebars and floating controls surround the manuscript. On macOS 26 and later, the controls use native Liquid Glass; earlier macOS versions use standard translucent materials. The interface follows your chosen appearance and the macOS Reduce Transparency setting. Paper styling is only part of the editor and is excluded from exports.

Selecting a manuscript passage opens a quick-action bubble beside its first visible selected line. Use **Bold**, **Italic**, **Underline**, **Comment**, **Review**, **Tag**, **Continuity**, or **Copy selection** without returning to the toolbar. The Tag menu suggests matching project objects and opens profiles for tags anywhere in the selected passage; removal is offered only when the passage contains tags. **Suggestions** appears when pending corrections lie within the selection. Actions preserve the selected passage. The bubble waits until dragging finishes and closes on Escape, scrolling, typing, or clicking elsewhere. Keyboard selections work too, in regular and focus mode.

Select text to change its font, size, bold (⌘B), italic (⌘I), underline (⌘U), alignment, spacing, or heading style. The font menu opens the Mac font panel for additional fonts. **Style** offers body text and headings. **Paragraph** groups alignment, spacing, and both list types, with checkmarks for the current alignment and spacing. **Insert** groups project tags and web links; **Format** groups strikethrough, text color, and highlighting. Unavailable removal actions are disabled, and removing a web link preserves project tags in the same selection. Paste formatted text from Word, or drop an image into the editor. Undo and redo use the standard Mac Edit menu and shortcuts.

The magnifying glass opens native find and replace inside the current chapter (⌘F). **Find in manuscript** filters the outline by chapter title, synopsis, and body text. Open **Chapter → Chapter notes** for the synopsis, or **Chapter → Draft status** to update its status.

StoryWriter remembers your selected project, chapter, and workspace tab on this Mac. Returning to a project resumes that chapter; if it has been removed, the first remaining chapter opens. These navigation preferences stay outside portable projects and saved revisions.

The chapter outline labels each drafting status and lets you filter by **Planned**, **Drafting**, **Revising**, or **Ready**. Search works within the chosen status; **Show all chapters** clears both filters. Drag to reorder with **All chapters** selected, or use **Move up / Move down** from a chapter's menu. The status menu below the paper changes the current chapter's status directly.

Choose **Sidebar** beside the chapter title to open research, scenes, revision comments, or character continuity beside your writing. Click the word progress control in the bottom bar for manuscript totals, chapter counts by status, and **Edit goal**. A goal of 0 turns off the word target; goals autosave with the project and remain available under **Story**. Library rows show progress toward each story's word goal.

Import chapters through the outline's + menu. Supported chapter imports are DOCX, RTF, RTFD, HTML, UTF-8 text, and Markdown. Markdown imports currently preserve the source as plain text, rather than interpreting its syntax.

## Tagging objects in your writing

Type **@** in a chapter to find characters, locations, items, and other world entries from the current project. Keep typing to narrow the suggestions; use the arrow keys and Return or Tab to choose an object, or click a suggestion. Put **@** immediately before or after an existing name to tag those words without inserting the name again: **Cole @** or **@Akademia Atorus**. Full names, aliases, and character first names keep their existing wording and formatting. Each suggestion offers **Insert as** buttons for the full name and alternate names; click the wording you want. With **@Cole**, Space, Return, or Tab keeps **Cole** and links it to **Cole Skorp**. Space adds an untagged space so you can keep writing. It tags an exact, unambiguous name or alias; spaces inside incomplete multiword names remain ordinary text. After choosing an object or wording with the arrow keys, Space also accepts that choice. Use ← / → to choose another name, or click **Cole Skorp** to insert the full name. A partial query such as **@Col** completes to the full name by default. Escape closes the suggestions.

**Insert → Character & world tag** in the formatting toolbar also offers the existing objects in grouped submenus. Select existing words before choosing an object to tag a nickname or phrase without changing its wording or formatting. With no selection, a matching name beside the cursor is tagged; otherwise, the object's name is inserted.

Click tagged text to show a detail bubble beside the words with its name, type, aliases, and saved character or world details. Choose **Open full profile** in the bubble to view and edit its complete record in the research sidebar. Click elsewhere or press Escape to dismiss the bubble; scrolling or typing also dismisses it. Option-click places the cursor for editing the prose. **Remove tag from selection** removes the connection while keeping the text. Connections survive saving, portable copies, and renaming the object; renaming does not rewrite the prose. If an object is deleted, its tagged words remain and the details panel explains that the object is missing.

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

## Write across Macs with iCloud Drive

In **Settings → Sync across Macs → Choose sync folder…**, select a dedicated folder such as **iCloud Drive/StoryWriter**. Install StoryWriter on your other Macs and select the same folder there. This uses ordinary user-selected files; it does not require an app-specific iCloud container or a paid Apple developer account. All stories and reference collections in each connected library are shared, including archived projects. Existing portable imports remain separate stories: syncing does not identify or combine projects by their names.

Writing keeps autosaving in the local library, including while offline or when the sync folder is unavailable. Saved changes are queued for syncing after a short pause. StoryWriter checks for incoming versions about every five seconds while open and when the app becomes active. **Project → Sync across Macs → Sync now** checks immediately. Finder's **Keep Downloaded**, where available, can keep the shared folder available offline.

Compatible edits merge automatically against their shared starting version: separate chapters, separate passages within a chapter, independent character/world fields, new records, and compatible chapter reordering. Rich text, project tags, and embedded attachments are preserved. Comments, scenes, and continuity passages are rebased through each text edit; changed source passages require review. Large or complex text differences may require choosing a complete writing version rather than automatic passage merging.

Overlapping passage edits, conflicting formatting, deletion versus editing, incompatible ordering, and dependent continuity changes remain available for review. Click **Changes need review** in the workspace or the library. Choose a version for each overlap; compatible passage and field edits are still combined. **Keep both stories** combines compatible edits using this Mac for conflicts and saves the incoming Mac's complete version as another story. If you continue editing while a review is open, it refreshes before accepting any choice. Local revisions checkpoint the working story before incoming changes are installed.

The status **Available in sync folder** means StoryWriter has written its versions to the selected folder; it does not confirm that iCloud has uploaded them or another Mac has downloaded them. Incomplete incoming versions wait for their parents and reference files instead of replacing local writing. iCloud can delay transfers. Navigation preferences, AI connection settings, backup settings, and the chosen sync folder remain local to each Mac.

The shared folder retains immutable versions in **Versions** and deduplicated reference files in **Assets**. Do not edit or remove these while using sync; the history is needed to compare offline branches. Shared versions are retained without automatic pruning. **Disconnect** stops syncing and keeps both the local library and shared files. Portable copies continue to work independently of sync.

## Publishing

**Export** (⇧⌘E) exports the whole story or current chapter as:

- Word (DOCX)
- PDF
- EPUB 3, with chapter navigation
- HTML, with inline images
- Markdown
- Rich text (RTF)
- Plain UTF-8 text

Planning notes and sources are excluded from manuscript exports. **Chapter → Copy formatted chapter for website** copies plain text, rich text, and HTML together, letting publishing websites choose their supported format. The website controls which formatting it retains. Markdown preserves emphasis, underline as HTML, strikethrough, links, and images; it cannot represent every Word layout feature. EPUB is a reflowable publication, rather than a fixed page layout.

## English / German grammar and style review

Mac spelling marks work without a model. Set the writing language under **StoryWriter → Settings**: Automatic, English, or Deutsch. Local AI review covers chapter text and titles, story planning, character profiles, worldbuilding, and reference notes.

Choose **Osaurus · local server** or **Apple · on-device** in Settings or the chapter's writing-review panel. **Suggest style improvements** is enabled by default; switch it off to request spelling and grammar corrections alone.

- **Osaurus:** start its local API server, then refresh and select an installed local model. The default address is `http://127.0.0.1:1337/v1`. StoryWriter connects only to loopback addresses, refuses redirects, and lists locally owned models. It does not download models or run agent tools.
- **Apple:** uses Apple's Foundation Models framework directly on this Mac, without an Osaurus server. Requires macOS 26 or later, a compatible Mac, enabled Apple Intelligence, and a ready on-device model. The app displays availability or language-support problems. Apple's model may decline some passages; the app reports that rather than changing your writing.

### Your project's writing brief

Choose **AI writing brief…** from the project menu next to Export, or edit **AI writing brief** in the Story tab. Describe your preferred tone, tense, point of view, pacing, dialogue, and language. Explain the subject and details you want the editor to preserve. The brief is saved with your project and included in portable copies.

Reviews include the brief plus short summaries of the premise, synopsis, chapter, and world. Each passage searches every project character record by name, including characters added later in the list. Matching character names, author-specified pronouns, and short profile summaries are sent as authoritative context. Names absent from the project are preserved as written rather than replaced with a similar cast member. Osaurus receives up to 3,000 brief characters and 3,500 background characters. Apple receives up to 1,500 brief characters and 1,800 background characters to fit its smaller context. These are bounded summaries, not the entire manuscript or your reference attachments.

### Reviewing and accepting suggestions

1. With automatic review enabled, pausing after editing reviews the changed paragraph (two seconds by default; adjustable in Settings). The **Auto** switch or Settings turns this off.
2. Suggestions appear directly in the edited field: orange dotted marks for spelling and grammar, blue for style. Click a marked passage, or the suggestion count, to see the original, proposed replacement, category, and explanation.
3. **Accept** or **Dismiss** handles one suggestion. Accepting a suggestion opens the next pending suggestion in the same field, wrapping to earlier pending suggestions when necessary; the card closes when the last one is accepted. The field's **Accept** menu handles pending suggestions in the sentence, paragraph, selected passage, or entire field. A batch is one Undo action; formatting is retained where the wording stays unchanged.
4. The **Review** menu checks a sentence, paragraph, selection, or entire field on demand. The chapter's writing-review button opens the larger panel with language, backend, and model controls. Long texts are reviewed in consecutive sections.
5. Choose **Review entire manuscript** from the project menu to review all chapters, then accept individually, by chapter, or across the manuscript. **Undo last acceptance** reverses the latest batch; saved revisions provide additional recovery.

Osaurus returns only changed excerpts and their categories, without generating explanations or copying unchanged prose. Apple proposes a revised passage, which the app converts into sentence-level suggestions. Identical Osaurus reviews reuse up to 32 recent results in memory; changes to the text, language, model, server, style setting, or project context require a new request. Whitespace-only model edits (such as trimming a trailing space) are ignored, so unchanged wording does not produce a correction card. Responses explicitly reporting that no corrections are needed in English or German are also rejected as edits, even if the model inconsistently rewrites the text. A native spelling check also supplements recognizable repeated-letter typos such as **Kindd → Kind**, while protecting character names and world titles. Accepting a correction preserves project tags on their exact original labels, including when a sentence is reordered; surrounding replacement prose does not inherit the tag. These marks are temporary and excluded from saved writing and exports. Later edits invalidate affected suggestions; whole-manuscript acceptance stops if the reviewed chapter changed.

Both backends check proposed edits against project names and detected personal names. Isolated name or gender-pronoun substitutions are removed while independent grammar edits remain; more complex identity-changing rewrites are discarded. Editing character records invalidates previous review suggestions. This does not check every kind of story continuity or guarantee perfect model accuracy.

All AI review is local and all proposed edits require acceptance. **No suggestions returned** means the model offered no changes, not that the passage is error-free. Accuracy varies: testing found that both small Osaurus models and Apple's model can miss German idioms or propose wording that changes an action or pronoun reference. Inspect the replacement before accepting it. Errors and unavailable models leave writing and saving available.

References: [Osaurus API guide](https://github.com/osaurus-ai/osaurus/blob/main/docs/OpenAI_API_GUIDE.md), [Apple Foundation Models](https://developer.apple.com/documentation/foundationmodels).

## Build and verification

Xcode or its command-line tools are required to rebuild. Swift Package Manager downloads the pinned Sparkle dependency; `Package.resolved` is committed.

```sh
zsh scripts/build-app.sh
zsh scripts/test.sh
```

The build script creates a release app in `dist`, embeds Sparkle and its license, generates its icon, and signs all nested helpers and the app locally. It uses a temporary build directory to work within restricted workspace environments. Set `STORYWRITER_UNIVERSAL=1` to build both architectures. `STORYWRITER_VERSION` and `STORYWRITER_BUILD_NUMBER` override the bundle version for release builds.

### GitHub pipeline

`.github/workflows/release.yml` tests pull requests. Every push to `main` runs the Swift tests and release-feed tests, builds both architectures, packages the universal app, verifies its update signature against the key in the app, and publishes a GitHub release containing the ZIP and signed `appcast.xml`. Failed checks prevent publication. Versions are `0.2.<workflow run number>` with build numbers starting at 1001. Manual workflow runs are supported, and re-running a published version leaves its assets intact. GitHub's latest-release selection uses release dates and semantic versions so older builds finishing later do not become the preferred update.

The repository secret **SPARKLE_PRIVATE_KEY** holds the base64 Ed25519 signing seed. Only its public key belongs in `Resources/update-public-key.txt`; never commit the seed. Keep a secure backup of the seed before changing repositories or secrets, since existing installations trust this key. Pull-request jobs cannot access the signing secret or publish releases. Optional `STORYWRITER_SIGNING_IDENTITY` supports an already-installed signing certificate during local builds; no Developer ID certificate is included or configured in CI.

Native German name-recognition checks run only when macOS reports German name-tagging support. GitHub runner images may omit those assets; the deterministic discovery, tagging, continuity, saving, and export tests still run. Live Osaurus and Apple model checks require their separately documented opt-in settings.

The tests cover rich text and imported references surviving save/reopen and portable import, revision restoration, source-only collections and debounced autosave, corrupt-file preservation, all publication exports, formatting/correction undo, safe media paths, local endpoint validation, model filtering, exact correction matching, saved project briefs and bounded story context, revision-to-suggestion conversion, repeated-letter spelling checks, Unicode-safe long-document review, inline annotation rebasing, grouped acceptance and undo, preservation of formatting, and whole-manuscript acceptance with stale-text protection.

Set `STORYWRITER_DATA_DIR` when launching the executable to use a separate library for development or testing.

Optional live model checks exercise English/German corrections, the screenshot passage, and style changes. These are quality checks: a model can connect successfully but fail to catch an idiom or preserve meaning. Choose an installed Osaurus model with `STORYWRITER_TEST_MODEL`:

```sh
STORYWRITER_TEST_OSAURUS=1 zsh scripts/test.sh --filter testLiveOsaurusEnglishAndGerman
STORYWRITER_TEST_OSAURUS=1 STORYWRITER_TEST_MODEL=qwen3.8-27b-jang_4d zsh scripts/test.sh --filter testLiveGermanScreenshotAndWritingStyle
STORYWRITER_TEST_APPLE=1 zsh scripts/test.sh --filter testLiveAppleOnDeviceWritingReview
```

## Connected writing tools

- **Beside your writing:** the **Sidebar** menu beside the chapter title opens Research, Scenes, revision comments, and character continuity. Choose a character, world entry, or reference to pin it beside your manuscript. Choose **Open full profile** in an object tag’s detail bubble to open its details in this panel. Characters, world entries, and reference lists also offer **Pin beside manuscript** in their right-click menus.
- **Aliases and appearances:** character and world profiles accept comma-separated aliases. Tag suggestions and local name recognition understand those aliases. **Appears in** lists explicitly tagged passages and name matches separately; click an entry to select that passage. A name match is a navigation aid, not proof of the character's identity.
- **Passage search:** the outline now shows matching passage previews rather than only filtering chapter titles. **Search** at the top of the project (⇧⌘G) also finds character profiles, world details, and reference notes. Choose a result to open and select its matching text.
- **Scenes:** open the writing panel's Scenes tab. Place the cursor inside a chapter and choose **Split at cursor**, or add a single scene for the entire chapter. Scene cards offer Move earlier/later, Merge with previous, and details for synopsis, viewpoint, location, status, story time, and timeline order. Moving scenes preserves formatted text, tags, and comments, adding paragraph spacing at new joins when needed. Splitting and merging preserve the continuous manuscript; scene labels are not added to exports.
- **Passage comments:** select text and use the speech-bubble menu or right-click **Add comment to selection**. A handwritten note opens in the page margin beside its passage; type there to edit it. Colored pencil underlines and loose hand-drawn connecting lines link notes to the prose. Use the small colored dot to choose Rose, Blue, Green, or Amber ink, and the checkmark to resolve a note. The writing column leaves room for side notes, and closely spaced comments stack without covering text. The **View → Pencil comments on page** toggle hides the layer. Notes also lists comments by chapter or across the project. Edits before a passage move its anchor. If the passage itself changes, the note stays in the queue for reattachment and leaves the page. Resolved notes remain available in the queue. Comments and the space they occupy on screen are excluded from manuscript exports.
- **Reading view:** the formatting toolbar's **Display** menu offers Narrow, Medium, or Full width, display zoom from 75% to 150%, and dim paper. These settings affect the writing display without changing saved font sizes, text colors, or exports. On narrower windows, opening the writing panel temporarily hides the chapter outline to leave space for the manuscript.
- **Quieter proofreading:** planning and research fields retain inline marks and small suggestion badges. A single review strip follows the currently focused field, instead of repeating the full review toolbar beneath every field.

## Revision comparisons and recovery

**Saved revisions** now previews a saved chapter and highlights changes from that save to the current chapter. Select text in the saved preview and **Recover selection** to append its original formatting to a chosen current chapter. **Recover this chapter** replaces only that chapter (or restores it if deleted); **Restore entire project** recovers the whole saved project. Current work is checkpointed first.

Name a checkpoint to keep a recognizable milestone. The app retains 30 automatic revisions and does not automatically prune named checkpoints. Named checkpoints travel in portable copies. Imported portable projects still start a new local history because their project identifier changes.

## Automatic portable backups

Use the project menu's **Choose automatic backup folder** to opt into dated portable copies. Backups run after a successful save, at most once per configured interval while the project changes (five minutes by default), with a first copy after setup. **Back up now** requests an immediate copy. The bottom bar shows the last successful backup time or a failure indicator; the project menu shows the full status.

Choose a folder separate from the app library, preferably on another drive. A backup becomes visible only after its copy and manifest validation finish; a missing drive or failed copy leaves the working project intact. Copies include research files and history. Dated backups are retained until you remove them. The selected folder and backup status are local to this Mac and are not imported with portable projects. Automatic backups can be turned off in the project menu.

## Story timeline

Open **Story timeline** from the project menu. Scene events are sorted by their optional timeline number, independently of their order in the manuscript. **Story time** can describe dates, times, or relative events such as “Day 2 · morning.” Unnumbered scenes appear after numbered scenes in manuscript order. Use Details to change an event or Go to scene to return to its passage. Chapters without scene metadata can be initialized as one scene each.
