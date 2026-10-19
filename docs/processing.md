# Processing rules

[← README](../README.md)

## What gets joined locally

Standalone hyphenated names also join without an added space: `seedmux-lite-\n  team` becomes `seedmux-lite-team`. The entire selection must form one ASCII name starting with a letter, using only letters, digits, underscores and single hyphens between nonempty segments. The first line must be unindented, every continuation must have the same padding of at least two ordinary spaces, and every removed break must follow a hyphen. An optional final LF/CRLF is preserved. This rule does not apply inside prose, paths, commands, lists or fenced text. An intentional break within a name can look identical; use Restore Original Text if needed.

Each blank-line-separated block must have a long, unindented prose first line, at least 48 approximate display columns and either 12 Chinese characters or eight alphabetic words. Every following line must have the same continuation indentation of at least two ordinary spaces. A prose block with recognizable code, commands, logs, tabs or nested indentation is left alone. List items are handled separately: long prose continuations aligned with the text after a bullet or numbered marker can join within that item. Titles, blank lines, new list items and nested markers keep their boundaries. Leading tab padding is also accepted for Chinese list continuations; internal tabs remain protected. Original list markers, initial indentation and Markdown text are retained. Fenced text makes the whole copy ineligible. Sentence endings and ambiguous boundary punctuation also prevent joining. The two-space minimum covers copied terminal prose with shallow hanging indentation; the other checks still apply.

If a selection begins directly at a list marker, the first line's original padding may be missing while continuation padding remains. For that opening item only, when its content includes Chinese and the first continuation starts with a Chinese character, deeper space indentation is inferred from the first continuation instead of requiring marker alignment. Subsequent space continuations must use that same indentation. The long-prose, sentence-ending and structured-text checks still apply. Later items and items with retained leading spaces keep the strict alignment rule. This is a heuristic: a deliberately indented Chinese paragraph after an unfinished opening list item can look identical in plain text; use Restore Original Text if needed.

When the opening prose block contains a locally recognized wrap, its continuation padding can also identify copied terminal padding on later paragraphs. Later prose blocks whose lines all have that same space padding can join under the existing length, punctuation and structured-text checks. Their initial padding and blank paragraph separators stay exact. Standalone indented blocks, mismatched or nested indentation, and opening list items do not establish this inference. Plain text cannot distinguish a deliberately indented prose block with the same padding; Restore Original Text remains available.

Chinese fragments join without an extra space; English words get one separating space. Internal spacing, including column alignment within the first line, remains intact. Blank paragraphs and surviving LF/CRLF line endings remain exact. A no-op never rewrites the clipboard.

Within an eligible prose block or list item, punctuation protects only its own boundary, not the entire block. For example, local mode keeps a newline after a colon but can join later wrapped lines. Untouched boundaries retain their original line endings, trailing spaces and continuation indentation, including accepted list padding.

For example, with 32 spaces before the second line:

```text
示例段落    这是一段用于演示文本换行合并的虚构内容。当终端窗口宽度不足时，一句话可能被折成多行，复制后需要将这些片段重新连接，才能得到完整的
                                句子。
```

becomes:

```text
示例段落    这是一段用于演示文本换行合并的虚构内容。当终端窗口宽度不足时，一句话可能被折成多行，复制后需要将这些片段重新连接，才能得到完整的句子。
```

The fences above illustrate the clipboard content; copying the fences themselves intentionally prevents conversion. These rules are structural, not matched to the example's wording. Independent Chinese and English examples are covered by tests.

## What the cloud services judge

The providers share the same bounded request and deterministic reconstruction:

| Provider | Endpoint | Model | Initial join threshold |
| --- | --- | --- | --- |
| Jev / TypeSafe | `https://api.typesafe.ai/v1/systemone` | `jev-1.13.0` | 0.98 |
| bjev / ByteDance | Internal service (configured in the app) | `bjev` | 0.80 |

AI mode sends the **original text**. Each boundary between adjacent nonblank lines gets two independent TypeSafe `noul` questions in one request: whether to join, and whether a space belongs there if joined. The answers produce three possible actions:

- `keep`: preserve the original newline and whitespace.
- `join`: remove the newline and adjacent space/tab padding without inserting a space.
- `space`: replace the newline and adjacent space/tab padding with one ordinary space.

Names, paths, URLs, short selections, punctuation, lists, code, logs and tabs do not filter out request candidates. The prompt asks the model to distinguish visual wrapping from intentional structure, including Markdown fences and shell continuations. Blank paragraph separators and the final newline stay fixed. The full original lines are shared as context in one request. The model cannot generate replacement text: non-whitespace characters, initial indentation, internal spacing, and all untouched boundaries retain their exact spelling. In AI-only mode, space selection comes solely from the model. Hybrid mode resolves the same validated answers using the rules below; it does not make another request or pre-edit the input.

The response must name the selected provider's model and contain exactly the expected `join_N` and `space_N` answers. Each must have type `noul` and a finite probability in [0, 1]. All answers, including spacing answers for kept boundaries, are validated before editing. In AI-only mode, a join applies only when the visual-wrap probability meets the provider's threshold; otherwise that boundary stays unchanged. For accepted joins, a spacing probability of at least 0.5 inserts one space; below 0.5 inserts none. The spacing question explicitly assumes joining and compares the two concrete spellings. These policies are not accuracy guarantees; old binary-prose calibration does not establish performance for the broader task.

### Hybrid decisions

The hybrid resolver applies this ordered policy to each original boundary:

1. Recognized code, fenced content, logs, headings and new list items keep their boundaries. A list continuation accepted by the existing local rule is not treated as a new item.
2. An AI wrap probability at or below 0.2 vetoes rule-based joining. This is a policy cutoff, not a measured guarantee that a break is intentional.
3. Otherwise, a join proposed by the existing local normalizer can supplement an uncertain AI score and supplies the boundary spacing. This covers standalone hyphenated identifiers and the existing long-prose/list rules. Proposals are aligned back to original line numbers; local output is never copied wholesale.
4. A whole selection that forms an ASCII path or HTTP(S) URL can join without spaces if its first line is unindented and all continuation lines have the same indentation of at least two spaces. Independent absolute paths/URLs and inconsistent indentation do not qualify for this rule.
5. If no join rule applies, use the normal AI threshold. When AI accepts a join between two CJK characters, insert no space. This spacing rule alone cannot authorize a join.

Last Copy Details shows both raw scores and the applied decision reason. Rule disagreement is not hidden behind an adjusted model probability. All other protections, the five-second limit, API failure handling, Pure Paste markers and undo remain unchanged. Switching hybrid mode cancels pending work and requires a new copy. Short ambiguous prose and split English words without an applicable rule can still be missed.

Cloud requests remain limited to **12 KiB of UTF-8 text and 64 candidate boundaries (128 questions)** per copy. Oversized copies, NUL-containing text, and copies without any adjacent nonblank lines are left unchanged without a request or a local pre-pass. The entire admitted plain-text copy is sent, including code and other context. HTML/RTF representations are kept locally for undo and are not sent. This is not a sensitive-data detector; select AI mode only for text you are willing to send to that service. The app never fails over to the other provider.

Missing keys, network failures, authentication errors, rate limits, invalid/missing answers, unexpected model versions, and timeouts keep the original copy by default. Explicitly enabling **Use Local Rules If AI Fails** allows the offline rules on failure only. Saved fallback preferences remain in effect, so uncheck this option if you previously enabled it and now want AI-only decisions. Clipboard-version and undo protections remain unchanged: late answers cannot overwrite a newer copy, and results arriving after the five-second deadline are discarded.

### Async consistency and availability

The clipboard remains the source of truth. A new copy, a mode change, or a key change cancels pending work. Before applying an answer, the controller checks its request ID, the enabled modes, deadline, and current pasteboard change count on the main thread. An old response cannot replace a newer copy, even before the next timer tick. Cancellation alone is not relied on for correctness.

This client/API design has no replicated shared database, so CP/AP is not a precise classification. During network failures it preserves copy/paste availability and uses conservative local correction when enabled. Otherwise it keeps the original. With connectivity it permits a bounded wait for a judgment, but never applies one to a different clipboard version. AppKit's existing non-atomic check/clear/write limitation still applies.

### Evaluating model quality

The automated tests verify request shape, response validation, text preservation, errors, cancellation, stale-response handling, and undo. They do not establish either provider's real-world accuracy or latency. Before relying on automatic cloud corrections, label representative Chinese, English, mixed-language, intentional-line-break, and structured-text examples. Measure false joins, missed joins, and end-to-end P95 latency with the pinned model. Tune the threshold against held-out examples, and repeat that evaluation before changing model versions. TypeSafe notes that its current model performs best in English.

Official references: [HTTP API](https://docs.typesafe.ai/api), [Noul](https://docs.typesafe.ai/primitives/noul), [models and language support](https://docs.typesafe.ai/models), [confidence and thresholds](https://docs.typesafe.ai/confidence).
