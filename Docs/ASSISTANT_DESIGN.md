# Document assistant design

The assistant keeps the PDF visible while the reader asks questions, summarizes its text, finds key details, explains a selected passage, translates a selection, or browses original evidence. The implementation uses Swift, SwiftUI, PDFKit, FoundationModels, URLSession, and macOS Keychain. No third-party SDK is required.

## Providers and deliberate generation

| Provider | Connection and configuration | Behavior |
| --- | --- | --- |
| Ollama | Loopback HTTP/HTTPS, default `http://localhost:11434`; editable model/address; installed-model picker | `GET /api/tags` discovers local models. `POST /api/show` checks a model's metadata before any PDF text is sent. Remote hosts/model aliases are refused. `POST /api/chat`, nonstreaming, uses a 16,384-token requested context. |
| OpenAI | Fixed `https://api.openai.com/v1/responses`; editable model; API key | Responses API with `store:false`, `stream:false`, and `truncation:disabled`. Default example model is `gpt-4.1-mini`; model access depends on the user's account. |
| Claude | Fixed `https://api.anthropic.com/v1/messages`; editable model; API key and optional workspace ID | Messages API with system instructions, a user input, bounded `max_tokens`, `Authorization: Bearer`, and `anthropic-version: 2023-06-01`. Default example model is `claude-haiku-4-5-20251001`. |
| Apple Intelligence | System on-device model | Availability reasons distinguish unsupported hardware, disabled Apple Intelligence, and an unready model. No cloud model is selected. |

The panel starts with **Ask your PDF**, a question composer, direct **Summarize** and **Key details** actions, and an always-visible provider selector. A local/cloud label states where processing happens. Provider settings remain collapsed until needed; cloud providers with no saved key show an **Add key** link. Installed Ollama model discovery selects an available model if the prior selection is absent, while preserving a valid choice. Explain, translate, and source-only search live in the composer's **More actions** menu.

For Ollama and Apple Intelligence, **Ask** reads the evidence and generates locally in one explicit action. `DocumentAssistantController.submit` enforces the distinction: OpenAI and Claude always stop after local preparation, even if a caller supplies a generator. Their **Review before sending** card exposes original passages and page links, with coverage, model name, request count, source bytes, and output-token allowance in request details. A separate **Send to OpenAI API** or **Send to Claude API** button authorizes paid generation. Pricing and charge descriptions remain visible before that send. Preparation, model discovery, and choosing a provider never upload PDF text or invoke paid generation. There are no automatic retries; cancellation cannot revoke requests already accepted remotely.

Answers show clickable source-page buttons immediately, followed by expandable original passages and coverage. The newest answer stays open; older answers sit under **Earlier answers** to keep the composer and current result usable in the 380-point panel. Completed questions clear from the composer for follow-ups. Local failures keep their prepared evidence and offer source-only search plus setup access. This prioritizes asking, reading, and checking sources while keeping configuration and technical request details available.

The protocol is deliberately stateless at the provider: each request contains only the current bounded evidence and task. The previous successful user question is retained as follow-up context within the same document and provider, without reusing model-generated assertions as evidence. Changing providers immediately cancels any reviewed request and clears the hidden follow-up context; existing answers remain visible. For same-provider follow-ups, the review visibly shows the exact previous question included in the transmitted prompt. Translation review also states its target language. The interface retains the latest 12 responses in memory, with an explicit count if older responses are removed. Closing the assistant does not write conversation text into the PDF.

## Evidence, limits, and completeness

`DocumentAssistantIndex` visits every PDF page on the main actor, yielding between pages so PDFKit objects are not passed across threads and cancellation stays responsive. Locked PDFs and copying restrictions are checked before and during extraction and generation. `PDFPageText` provides the same extraction for AI and text/Excel conversion: attributed page text first, followed by labeled visible FreeText boxes and filled text/choice widgets in displayed top-to-bottom, left-to-right order. This preserves live edits without pretending to reconstruct their surrounding paragraphs. Hidden/off-page annotations, Annotate marker badges, and password fields are excluded; choice export codes map to their visible labels. Text-box contents include retained overflow text. Coverage and conversion UI disclose supplemental ordering. Pages with neither selectable text nor these visible values are counted explicitly and need OCR; the assistant does not silently treat an image-only page as understood.

The complete extracted document has a limit of 10,000 pages and 8 MB of UTF-8 text. Exceeding either limit fails preparation with a visible explanation; it does not return a prefix-only index. Text is divided into approximately 1,400-byte passages, preserving every Unicode scalar in order and preferring whitespace boundaries. Citations use actual one-based PDF page indices. Source links navigate to pages through the reader model, never through a model-generated URL or page identifier.

Question retrieval scores every passage using case/diacritic-insensitive word and phrase matches. It returns a disclosed subset of approximately 5,600 bytes, including citation labels. It is lexical retrieval, so semantic matches using unrelated words can be missed. The original full passages remain inspectable even when AI is unavailable. A previous user question can supply retrieval terms for a short follow-up with no matches.

Full summaries and key-detail extraction process **every text passage**, in independent bounded sections. The combined answer is explicitly a section-by-section result, not a claim of an unlimited-context synthesis. Each section has a 768-token response allowance; questions, explanations, and translations have 1,024. A question is limited to 1,000 UTF-8 bytes and a selection to 4,000. Overlong inputs fail visibly rather than being silently shortened. A provider's incomplete/max-token response fails the generation and keeps reviewed source passages available.

Apple's model has a documented 4,096-token context. On macOS 26.4 and later, its tokenizer checks instructions plus prompt plus response allowance and a framing reserve before generation. Earlier macOS 26 releases use byte-bounded prompts and surface the framework's context error. Ollama models reporting fewer than 16,384 context tokens are rejected; unknown-context locally downloaded models depend on the server honoring the explicit context option. OpenAI and Claude may reject a custom model or an account's context limits; the UI reports failure without automatically retrying or dropping text.

Building this implementation requires a macOS 26.4 or newer SDK because the compiler must resolve `SystemLanguageModel.tokenCount(for:)` even behind its runtime availability check. The app's deployment target remains macOS 26. The verified development toolchain is Xcode 27 / Swift 6.4 with the macOS 27 SDK; older eligible SDKs have not been built in this session.

## Security and lifecycle

PDF text is untrusted quoted evidence, delimited separately from the user's requested operation. System instructions explicitly reject embedded commands, role labels, credential requests, and attempts to override the task. No provider receives tools, file access, URL fetching, or document mutation privileges. Generated output is displayed as plain text. Source pages and excerpt cards originate from PDFKit, so model-generated citations cannot redirect navigation. The UI asks readers to verify generated facts against the source; prompt constraints do not guarantee factuality or prevent every prompt-injection effect.

API keys are kept under the Keychain service `com.mweingar.Annotate.document-assistant`, with one account per provider and no synchronization. Settings store provider/model/address/workspace preferences in UserDefaults; keys and PDF text are never stored there. The key-entry UI uses a SecureField and clears its draft after saving, changing provider, or disappearing. Only Annotate's own service entries are queried; saved keys are read for an explicit Generate/Send action. Header values reject invalid/control characters.

HTTP uses an ephemeral URLSession with no cookie store, credential store, disk cache, or redirects. Responses are bounded to 1 MB and a finite timeout. Server error bodies are never echoed because they may contain document text or credentials. Incomplete, malformed, refused, empty, rate-limited, and authentication-failed responses remain failures rather than partial successful answers. The client never changes accounts, downloads Ollama models, or infers credentials from environment variables or unrelated applications.

Every task has an identity token and a cancellable Task. A document switch, document revision, provider/model change, new preparation, or panel disappearance cancels outstanding work. Late output from a cancellation-insensitive provider cannot append an answer to another document. PDF copying permissions are rechecked before requests and after completion. Generated results and evidence are cleared on document/revision changes.

## Verification contract

The focused `Assistant*` tests cover lossless Unicode chunking, late-page retrieval, complete batching, image-page disclosure, copy restrictions, cancellation, unavailable-model fallback, preparation without generation, stale-answer isolation, source selection limits, and prompt/evidence separation. Transport-injected tests validate all provider request/response schemas, unsafe endpoint rejection, incomplete/refused responses, missing credentials, and no retry or secret echo on failure. These tests require no paid API calls.

The release privacy regression verifies that prior local questions are excluded when switching to either cloud provider, same-provider follow-ups expose the exact prior question sent, and a provider switch immediately invalidates a prepared send. The focused privacy, interaction, lifecycle, and composer run passed 16 test functions across 4 suites (core: 0.460 seconds; app: 0.004 seconds).

`AssistantInteractionTests` adds one-action local completion, enforced cloud review, cancellation before automatic local generation, and source-only recovery when a model is unavailable. `AssistantUXTests` covers meaningful action labels, disabled empty/busy submissions, and installed-model selection without touching credentials or a server.

Provider configuration UI, real local generation, and installed-app navigation require separate runtime checks. Paid-provider request fixtures are not proof that an arbitrary user's account/key/model is usable. Actual OpenAI or Claude generation is not performed unless the user explicitly supplies/configures credentials and authorizes the displayed request.

## Original API sources

This design references **12 original API sources**, separately from the 10-source product audit in `PDFGEAR_RESEARCH.md`:

1. [Apple: Generating content and performing tasks](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models) — on-device capabilities, availability, session behavior.
2. [Apple: Managing the context window](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window) — finite context and input/output budgeting.
3. [OpenAI: Text generation](https://developers.openai.com/api/docs/guides/text) — Responses API instructions, inputs, and output-message extraction.
4. [OpenAI: Create a model response](https://developers.openai.com/api/reference/cli/resources/responses/methods/create) — storage, truncation, output limits, and status fields.
5. [OpenAI: GPT-4.1 mini](https://developers.openai.com/api/docs/models/gpt-4.1-mini) — a configurable baseline supporting Responses.
6. [Anthropic: Create a Message](https://platform.claude.com/docs/en/api/messages/create) — system/messages shape, token limit, text blocks, and completion state.
7. [Anthropic: Authentication](https://platform.claude.com/docs/en/manage-claude/authentication) — current bearer-key authentication and optional workspace scope.
8. [Ollama: Chat API](https://docs.ollama.com/api/chat) — nonstreaming chat and runtime options.
9. [Ollama: Show model details](https://docs.ollama.com/api-reference/show-model-details) — local model metadata and context information.
10. [Ollama source: API types](https://github.com/ollama/ollama/blob/main/api/types.go) — `remote_model`/`remote_host` metadata used to reject cloud aliases.
11. [Ollama: List models](https://docs.ollama.com/api/tags) — installed model discovery.
12. [Anthropic: Models overview](https://platform.claude.com/docs/en/models/overview) — available model IDs and the configurable Haiku baseline.

## Runtime evidence, September 5, 2026

The coordinating agent exercised the installed application: Ollama's model discovery displayed 33 downloaded models; `granite4.1:8b` was selected. A question about keeping questions specific in the bundled reading guide prepared all four pages (4,083 bytes, one generation request), generated an answer in approximately 4.6 seconds, and showed the correct page-three quotation with source controls. This proves that installed UI-to-Ollama path for that fixture. It does not prove every model, document, language, or remote account. No paid API call was made.

The opt-in `AssistantLocalSmokeTests` also exercised the current URLSession client and model-metadata preflight against the downloaded `granite4.1:8b` model. It returned the fixture's codename, Cedar Compass, with the page-two reference and passed in 0.35 seconds after the model was already loaded. The smoke test is disabled in routine test runs; enable it with `ANNOTATE_LOCAL_AI_SMOKE=1` and optionally `ANNOTATE_LOCAL_AI_MODEL`.
