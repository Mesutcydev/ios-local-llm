# AI and agent integration

iOS Local LLM can act as a private local inference endpoint for development
tools and AI agents. These interfaces are opt-in and remain separate from the
app's normal on-device UI.

This document describes the implemented compatibility surface. It does not
claim complete compatibility with every option in the upstream APIs.

## Local API server

Open **Home → Local API Server** to manage the listener. The workspace follows
the app's Studio theme and shows listener state separately from model state.
The default port is `11434`; connection details, certificate pin, and client
recipes are available before starting. Entering the page does not start the
local API.

Start the server explicitly, then choose or load an installed local model.
API model controls never download weights implicitly and do not offer Apple
Private Cloud. The model shares the chat runtime and retains the same memory,
thermal, cancellation, and background-cleanup policies.

Choose OpenAI, Anthropic, or Ollama to copy a pinned HTTPS setup recipe. The
displayed recipe masks the API key until revealed; **Copy setup commands**
includes the actual key. Credential copies use the device-only clipboard.
Revealed credentials hide when leaving the page or backgrounding the app.
Rotating the key requires confirmation and clients must then update their key.

Every request requires either:

```http
Authorization: Bearer YOUR_IOS_LOCAL_LLM_KEY
```

or:

```http
x-api-key: YOUR_IOS_LOCAL_LLM_KEY
```

The key is generated locally, stored in Keychain, and can be rotated from the
app. Traffic uses HTTPS with a locally generated device certificate; clients
must trust that certificate or verify its public-key pin. Use the server only
on a trusted network. The listener stops when iOS backgrounds the app.

### Implemented routes

| Dialect | Method and route | Notes |
| --- | --- | --- |
| OpenAI | `GET /v1/models` | Lists locally available assistant models |
| OpenAI | `POST /v1/chat/completions` | Text chat, streaming, and supported tool calls |
| OpenAI | `POST /v1/responses` | Text input/output compatibility; no tool calling |
| Anthropic | `POST /v1/messages` | Text messages and supported tool-use blocks |
| OpenAI | `POST /v1/embeddings` | `input` string or string array, `encoding_format` `float` or `base64`; token-array input is rejected |
| Ollama | `POST /api/embed`, `POST /api/embeddings` | `input` array / legacy `prompt`; same embedder |
| Ollama | `GET /api/tags` | Lists available models |
| Ollama | `POST /api/show` | Returns local model information |
| Ollama | `POST /api/chat` | Chat and supported tool definitions |
| Ollama | `POST /api/generate` | Prompt-based text generation |

Unsupported request options are rejected explicitly rather than silently
ignored. The route implementation and decoding rules live in
`IOSLocalLLM/Services/Bridge/LocalAPIServer.swift`.

Clients must trust the device certificate or verify its public-key pin. The
examples replace CA/hostname validation with an explicit SPKI pin, so never omit
`--pinnedpubkey` when using `--insecure`. A generic SDK must be configured to
trust the certificate; changing the URL alone is insufficient.

### OpenAI-compatible example

```bash
export OPENAI_BASE_URL="https://IPHONE_IP:11434/v1"
export OPENAI_API_KEY="YOUR_IOS_LOCAL_LLM_KEY"
# Copy this pin from the iPhone screen through a trusted channel.
export IOS_LOCAL_LLM_TLS_PIN="sha256//PIN_SHOWN_ON_IPHONE"

curl --insecure --pinnedpubkey "$IOS_LOCAL_LLM_TLS_PIN" "$OPENAI_BASE_URL/models" \
  -H "Authorization: Bearer $OPENAI_API_KEY"

curl --insecure --pinnedpubkey "$IOS_LOCAL_LLM_TLS_PIN" "$OPENAI_BASE_URL/chat/completions" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "LOCAL_MODEL_ID",
    "messages": [{"role": "user", "content": "Explain this Swift error."}],
    "stream": false
  }'
```

The requested model must be installed and must match a model ID or repository
ID known to the app. Memory and thermal safety gates may refuse or shorten
work even when a request is otherwise valid.

## Tool calling

The OpenAI chat and Anthropic message decoders accept supported function/tool
definitions and normalize them into the app's internal tool-call format.
Tool-choice and parallel-call behavior differ by dialect. The Responses
compatibility route is currently text-only.

Treat a model's emitted tool call as untrusted input:

- validate the tool name and JSON arguments;
- preserve risk levels and approval requirements;
- do not execute shell or filesystem mutations merely because a model asks;
- return structured errors rather than fabricating successful results.

`IOSLocalLLM/Services/ToolRunner.swift` contains local output parsing.
`IOSLocalLLM/Services/Bridge/LocalAPIServer.swift` contains HTTP tool schemas and
response encoding.

## Paired Mac agent channel

The Mac bridge is a separate, pairing-authenticated channel for grounding an
iPhone assistant in the paired Mac's current context.

The wire protocol uses versioned JSON envelopes for:

- `tool_call`
- `tool_result`
- `tools_list`
- `heartbeat`
- protocol-level `error`

Risk levels are:

- `SAFE_READ`
- `LOW_RISK_ACTION`
- `MEDIUM_RISK_ACTION`
- `HIGH_RISK_ACTION`

The current iPhone flow focuses on safe read-only context, such as the
frontmost app, window title, selected text, and workspace path. A user can
request that context per message with `/mac`; the app does not continuously
observe the Mac.

The canonical iOS protocol types are in
`IOSLocalLLM/Services/Bridge/Agent/AgentProtocol.swift`. Changes must remain
compatible with the matching LocalCoderBridge implementation.

## Privacy and security boundaries

- All agent/local API features are disabled until the user enables or pairs
  them.
- The local API uses a distinct bearer key from Mac pairing.
- The paired agent channel pins identities and uses its own credentials.
- Prompt content, tool arguments, selected text, and model output must not be
  written to ordinary logs.
- Network compatibility does not imply cloud inference. Generation remains
  local unless a separately identified feature explicitly says otherwise.
- Do not expose the local HTTPS listener to an untrusted Wi-Fi network or the
  public internet.

## Guidance for integrations

An external agent should:

1. Query `/v1/models` before selecting a model.
2. Expect model availability to change as users download, unload, or delete
   models.
3. Handle `401`, `404`, validation failures, memory refusals, cancellation,
   and thermal throttling.
4. Prefer streaming for long responses and tolerate an early terminal event.
5. Avoid retry loops that could worsen memory or thermal pressure.
6. Keep user approval outside the model for any consequential tool action.

### Native LFM3 functions

LFM3 models receive function schemas in their native `<tools>` prompt section.
Complete `<tool_call><function=...><parameter=...>` responses are decoded into
the existing local/API call types. Unknown functions, missing required
arguments, duplicate parameters, invalid scalar types, incomplete calls, and
calls inside reasoning are rejected. API calls return to the client for
execution; local calls keep the existing consent, file-picker, web, parental,
and tool-depth policies. OpenAI, Anthropic, and Ollama response formats remain
the same. Audio/Omni checkpoints are non-reasoning; their voice output is
native 24 kHz PCM. The compatibility HTTP routes remain text-based; realtime
WebSocket audio and video input are outside this change.
