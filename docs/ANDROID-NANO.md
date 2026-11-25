# Gemini Nano release decision

Readr keeps Google's datatransport runtime and CCT upload backend excluded from the app. This matches the app's existing privacy promise; it is not a claim that a closed-source SDK can be proven to have no other behavior from static inspection.

`genai-prompt:1.0.0-beta4` and its GenAI/common dependencies are proprietary ML Kit SDKs. AICore owns the model and performs explicit model downloads requested from Settings. Readiness checks do not request downloads. Book passages and questions enter the local generation API, not Readr's model-download paths.

The instrumented `mergedAppHasNoTelemetryUploadComponents` check verifies the final installed package has no `ACCESS_NETWORK_STATE` permission and no datatransport service/receiver. The build and unsupported-device probe pass with the exclusions. Neither check proves that real generation on a supported phone will avoid resolving an excluded class; that remains a mandatory physical-device check.

Before enabling the release claim, validate on a supported device: model installation, actual grounded answers, reported context window, streaming completion, caller/SDK cancellation, background interruption and retry, and network behavior. The API 35 emulator used for this implementation has no production AICore and cannot perform that validation. No physical Android phone was available. Keep PR111 draft until this evidence and CI/review gates are complete.

Sources: [Google Prompt API setup](https://developers.google.com/ml-kit/genai/prompt/android/get-started), [GenAI overview and eligibility](https://developers.google.com/ml-kit/genai).
