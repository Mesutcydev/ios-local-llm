# Aider setup

The local API can generate Aider configuration for the currently active model.
The endpoint is authenticated with the same local bearer key as the other API
routes:

```bash
curl "$OPENAI_BASE_URL/aider/config" \
  -H "Authorization: Bearer $OPENAI_API_KEY"
```

Save the returned `metadata_json` as `.aider.model.metadata.json` and
`settings_yaml` as `.aider.model.settings.yml`. The generated model name is
`openai/<exact-model-id>`; do not add the `openai/` prefix a second time.

The settings file contains `extra_params.max_tokens`, which configures Aider's
outgoing request. Typing a JSON object containing `"max_tokens"` into Aider's
chat only sends that JSON as prompt text.

Use the generated launch command, replacing `YOUR_LOCAL_API_KEY` with the
existing local API key through an environment variable or your private shell
configuration. Do not commit the key or either generated file:

```bash
export OPENAI_BASE_URL="http://DEVICE_ADDRESS:11434/v1"
export OPENAI_API_KEY="YOUR_LOCAL_API_KEY"
aider --model-metadata-file .aider.model.metadata.json \
  --model-settings-file .aider.model.settings.yml \
  --model openai/LOCAL_MODEL_ID
```

Inside Aider, run `/tokens` to verify that the loaded model metadata reports a
non-zero context limit. The server also exposes the runtime values through
`GET /v1/models` and `GET /v1/models/{id}`.
