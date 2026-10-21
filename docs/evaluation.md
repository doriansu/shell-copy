# AI evaluation

[← README](../README.md)

### Verify real AI decisions

`swift test` uses intercepted HTTP responses. It verifies request coverage, strict validation, reconstruction, model vetoes of locally joinable text, and clipboard safety, not model quality. Run the opt-in harness against synthetic/reported fixtures for real service evaluation:

```sh
swiftc -parse-as-library -module-cache-path .build/module-cache \
  Sources/ShellCopyCore/*.swift \
  scripts/evaluate-ai.swift -o .build/evaluate-ai
.build/evaluate-ai bjev /path/to/key.txt fixtures/ai-boundaries.json
# Evaluation-only override; the app still uses its five-second deadline.
.build/evaluate-ai bjev /path/to/key.txt fixtures/ai-boundaries.json 15 compare
```

Use `jev` for TypeSafe. This command sends the fixture texts to the selected service, never reads the clipboard/keychain, and prints only case IDs, decisions, timing and pass/fail counts. Keys and raw text are not printed. A mismatch or service failure returns a nonzero exit code. The fixtures include the reported identifier, English word/prose, Chinese fragments, paths, URLs, list wraps, and intentional code/list/log breaks. Small fixture results are not a general accuracy estimate.

The optional timeout is in seconds and defaults to the app's five-second limit. The last optional argument is `ai`, `hybrid` (default), or `compare`. Comparison evaluates both policies from the exact same response, avoiding separate-call output variation. The harness compares response resolution only: it does not simulate the controller's rules-first short circuit or optional failure fallback. In the app, rules-first mode now stops without requesting AI whenever local rules change the copy. The harness also records DNS, connection, TLS, upload, post-upload first-byte wait, and download timings. Connection time includes TLS, so those fields must not be added together. Missing phases can indicate connection reuse or unavailable measurements. First-byte wait includes network and service work; it does not isolate model inference time. Redirects remain blocked.

Protocol reference: [TypeSafe Noul](https://docs.typesafe.ai/primitives/noul.md).

**Hybrid development comparison, October 19.** Both modes consumed the same responses, with unchanged prompts. The [five-second run](../fixtures/bjev-hybrid-comparison-2026-10-19.log) had 8 correct hybrid outputs, 1 mismatch and 5 request timeouts; AI-only had 6 correct outputs. A [15-second diagnostic run](../fixtures/bjev-hybrid-15s-comparison-2026-10-19.log) had 11 correct hybrid outputs, 2 mismatches and 1 request timeout; AI-only had 9 correct outputs. Both runs fixed the URL and wrapped-list cases that AI-only missed, with no regressions on completed cases. Each total includes one blank-paragraph case without a request. The reported identifier timed out in both runs, so its hybrid recovery is covered by replayed-score unit tests, not a successful live request in these runs. Split English-word spacing and short Chinese prose still failed in the 15-second run. These reused development fixtures are not an independent accuracy estimate. App timeout remains five seconds; the comparison harness does not apply optional failure fallback.

**Earlier AI-only evaluation.** The [October 18 development run](../fixtures/bjev-ai-results-2026-10-18.json) produced 6 correct outputs, 2 mismatches and 6 request timeouts out of 14 cases. All six correct outputs were intentional-keep cases, including one blank-paragraph case that made no request. No positive join case passed in that run. The reported identifier reached bjev with `wrap=0.7126` and `space-if-joined=0.613`: the 0.80 join threshold kept it unchanged, and merely lowering that threshold would insert an incorrect space. The fixtures were reused during prompt iteration; these are diagnostic observations, not an independent accuracy benchmark. Jev was not live-tested. Do not interpret passing unit tests or a built app as acceptance of the current model/prompt/deadline combination.

On October 19, the same fixtures and judgment policy were rerun with a 15-second evaluation timeout, followed by a fresh-process 2-second control:

| Run | Requests / timeouts | Correct / mismatched outputs | Request median / maximum |
| --- | --- | --- | --- |
| [15-second limit](../fixtures/bjev-ai-15s-2026-10-19.log) | 13 / 0 | 10 / 4 | 0.430 s / 1.346 s |
| [2-second control](../fixtures/bjev-ai-2s-control-2026-10-19.log) | 13 / 0 | 9 / 5 | 0.406 s / 1.282 s |

Each run also includes one correct blank-paragraph output without a request. All actual requests completed within two seconds, so this experiment did not reproduce the earlier timeouts or establish that raising the limit caused recovery. In the 15-second run, the first connection took 0.933 s including 0.728 s TLS; later requests reused it. Post-upload first-byte waits were 0.318-0.584 s. No server trace was captured, so historical timeout causes remain unknown. Both runs missed the reported identifier, URL, Chinese prose and wrapped list; the control additionally inserted an incorrect space inside the English word. The output difference is not evidence that a longer deadline improves judgment: these are single sequential runs, and exact serialized dictionary order and backend execution were not pinned. App timeout and clipboard behavior were not changed.

After this evaluation, the app's shared request/processing limit was raised to five seconds at the user's request. This leaves headroom above the observed 1.346-second maximum without adopting the 15-second diagnostic limit. It is an operational choice, not a measured latency guarantee or a fix for incorrect judgments. Prompts, thresholds, fallback preferences and newer-copy protection are unchanged.


**HTTP 451** means TypeSafe has refused the current network region. On October 13, 2026, an unauthenticated request from the development Mac returned `Typesafe is not available in your region.` This occurs before model judgment, so changing the join threshold cannot resolve it. Local fallback remains available; selecting **Local Rules** runs local rules without waiting for a network response. These diagnostics did not read the user's API key or clipboard. A native smoke test with synthetic English prose and an invalid test credential also received HTTP 451, then joined the text locally and restored the original in approximately 0.71 seconds. The user's reported Chinese example is covered by local regression tests; it was not sent by the diagnostic.

### bjev smoke evaluation — October 13, 2026

Historical binary-prose calibration, before the AI-led change: the initial Jev threshold of 0.98 missed clear synthetic continuations: bjev returned 0.8848 for a Chinese wrap and 0.9094 for an English wrap. Its initial threshold is therefore separate, at 0.80. The [30 synthetic cases](../fixtures/line-judgments.json) and [observed probabilities](../fixtures/bjev-results-2026-10-13.json) record this calibration. Both fixture splits were inspected when selecting the threshold; this is not an independent accuracy benchmark.

At 0.80, 14 of 15 intended joins were selected, all 15 intentional breaks stayed intact, and there were no false joins in this small sample. The remaining intended join started with `for`, which the existing command guard protected before any API call. This documents a conservative limitation; it does not prove a zero false-join rate on real clipboard text. A subsequent check through the final production client joined synthetic Chinese and English wraps, preserved an independent break, and joined/restored an isolated macOS pasteboard. Individual final smoke requests took approximately 0.17–0.25 seconds. No general clipboard contents were read for these checks.

### Historical local-first correction — version 1.0.1

The following describes version 1.0.1, not the current pipeline. Current cloud modes judge the original copy and optionally combine the validated response with local rules. See [Processing rules](processing.md).

A reported two-line Chinese paragraph met the existing local rules but bjev returned 0.6753 twice, below its 0.80 threshold. Removing complete sentences later in the second line changed the answer to 0.8097; the original pipeline allowed this unrelated context to prevent a local rule from joining the wrap. Prompt-only and sentence-fragment probes did not consistently fix both long and short inputs, so they were not shipped.

AI modes now run the existing conservative local normalizer first and submit only remaining candidate boundaries. The reported paragraph becomes one line without a network request in both Jev and bjev modes. Mixed copies still send unresolved boundaries to the selected provider in a single request. This is a policy change: locally recognized joins no longer require model approval. Local rules are still heuristic, and Restore remains available. Keys, cloud thresholds, prompts, and protections for structured content are unchanged. Regression tests cover the exact report, a low cloud score that must not block a local join, and partially normalized copies with both accepted and rejected cloud boundaries.
