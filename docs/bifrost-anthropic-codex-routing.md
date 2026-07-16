# Bifrost Anthropic-to-Codex routing

Research date: 2026-07-16

## Conclusion

The configured route is an intended Bifrost feature, not an accidental use of
the API. Bifrost documents Claude Code using an Anthropic endpoint while
pinning an OpenAI model, and its transport converts Anthropic Messages requests
to Bifrost Responses requests before provider dispatch.

The downstream response identifies the rejected field precisely:

```json
{"detail":"System messages are not allowed"}
```

The failing Claude Code request contains a leading `system` message and a
later `system` reminder. Replaying the same request succeeds when the later
role is changed to `developer`, which is OpenAI's documented application
instruction role. The compatibility rule therefore belongs in this plugin's
private Codex-provider boundary. It is not evidence that
`ANTHROPIC_BASE_URL`, Bifrost's Anthropic conversion, the provider prefix, or
the custom-provider request path is wrong.

## Verified behavior

- `ANTHROPIC_BASE_URL` should be `http://127.0.0.1:8080/anthropic`, without
  `/v1`. Claude Code appends `/v1/messages`; Bifrost's own example uses the
  same base URL. ([Bifrost Claude Code guide](https://github.com/maximhq/bifrost/blob/c0909f9752156121c6c775694df6e656a6ad3860/docs/cli-agents/claude-code.mdx#L108-L115),
  [Claude Code gateway verification](https://code.claude.com/docs/en/llm-gateway-connect#verify-the-connection))

- Bifrost intentionally handles `/anthropic/v1/messages` as a Responses
  request: the route declares `ResponsesRequest`, calls
  `ToBifrostResponsesRequest`, then converts the response or stream back to
  Anthropic format. ([Bifrost Anthropic transport](https://github.com/maximhq/bifrost/blob/c0909f9752156121c6c775694df6e656a6ad3860/transports/bifrost-http/integrations/anthropic.go#L61-L95),
  [stream conversion](https://github.com/maximhq/bifrost/blob/c0909f9752156121c6c775694df6e656a6ad3860/transports/bifrost-http/integrations/anthropic.go#L116-L168))

- A model string is also the routing key. Bifrost splits a known
  `provider/model` prefix, so `codex-subscription/gpt-5.6-sol` routes to the
  custom provider and sends `gpt-5.6-sol` as the model. Its Claude Code guide
  explicitly documents the same pattern with `openai/gpt-5.5`.
  ([model parser](https://github.com/maximhq/bifrost/blob/c0909f9752156121c6c775694df6e656a6ad3860/core/schemas/utils.go#L96-L105),
  [Anthropic request routing](https://github.com/maximhq/bifrost/blob/c0909f9752156121c6c775694df6e656a6ad3860/core/providers/anthropic/responses.go#L3165-L3173),
  [Bifrost Claude Code guide](https://github.com/maximhq/bifrost/blob/c0909f9752156121c6c775694df6e656a6ad3860/docs/cli-agents/claude-code.mdx#L188-L203))

- `allowed_requests` is restrictive when present: unspecified request types
  become false. Therefore enabling only `responses_stream` is correct for the
  streaming-only Codex backend. `request_path_overrides.responses_stream =
  "/responses"` changes the default OpenAI path relative to the configured
  base URL. ([allowed-request semantics](https://github.com/maximhq/bifrost/blob/c0909f9752156121c6c775694df6e656a6ad3860/docs/providers/custom-providers.mdx#L20-L28),
  [request-path override semantics](https://github.com/maximhq/bifrost/blob/c0909f9752156121c6c775694df6e656a6ad3860/docs/providers/custom-providers.mdx#L260-L298))

- Bifrost preserves the role and position of messages while converting
  Anthropic messages to Responses input. Top-level Anthropic `system` content
  is emitted first as a Responses `system` message; an inline system role is
  cast through like other message roles. OpenAI's official Responses schema
  accepts `user`, `assistant`, `system`, and `developer` input roles.
  ([top-level system conversion](https://github.com/maximhq/bifrost/blob/c0909f9752156121c6c775694df6e656a6ad3860/core/providers/anthropic/responses.go#L4005-L4034),
  [inline role preservation](https://github.com/maximhq/bifrost/blob/c0909f9752156121c6c775694df6e656a6ad3860/core/providers/anthropic/responses.go#L4745-L4769),
  [OpenAI Responses schema](https://github.com/openai/openai-openapi/blob/bcb644949593744091c6cef593fd8d9e45b37eaa/openapi.yaml#L37242-L37296))

- OpenAI's current text-generation guide uses `developer` messages for
  application instructions and describes them as higher priority than user
  messages. Rewriting Codex-bound `system` input roles to `developer` preserves
  the intended instruction authority while satisfying the private endpoint.
  ([OpenAI text-generation guide](https://developers.openai.com/api/docs/guides/text#message-roles-and-instruction-following))

- Claude Code's own gateway protocol warns that translating an
  Anthropic-format body to a non-Anthropic upstream can produce hard `400`
  errors when a beta header/body-field pair or newer request field is not
  translated correctly. It also says Claude Code can retry rejected thinking,
  thinking signatures, and mid-conversation system messages only when the
  upstream error wording is forwarded intact. ([Claude Code gateway protocol](https://code.claude.com/docs/en/llm-gateway-protocol#feature-pass-through),
  [automatic retry](https://code.claude.com/docs/en/llm-gateway-protocol#automatic-retry-and-error-forwarding))

## Version check

The package pins Bifrost `c0909f9`. Bifrost's `dev` branch still points at that
commit. `main` is 12 commits ahead at `8970efa`, but the Anthropic transport and
Anthropic Responses converter have identical Git blob hashes at both commits;
the intervening changes do not update this routing path. Updating to current
`main` alone therefore would not fix this `400`.

Sources: [pinned-to-dev comparison](https://github.com/maximhq/bifrost/compare/c0909f9752156121c6c775694df6e656a6ad3860...dev),
[pinned-to-main comparison](https://github.com/maximhq/bifrost/compare/c0909f9752156121c6c775694df6e656a6ad3860...8970efaec70bb83768d062d8148bdd13601277a7).

## Model-list implication

Bifrost does not translate a friendly Claude tier into a Codex model catalog.
The configured `ANTHROPIC_DEFAULT_*_MODEL` value is parsed and forwarded. To
serve the current subscription models, configure the exact backend IDs with
the `codex-subscription/` prefix; no Bifrost source patch or static model
registry is required for routing. Model availability remains controlled by the
private ChatGPT Codex backend and the account's rollout.
