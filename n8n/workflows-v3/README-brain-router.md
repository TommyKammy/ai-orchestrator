# Chat Router v1 — Brain LLM Integration

**Version:** 1.0  
**Last Updated:** 2026-02-14  
**Webhook Path:** `/webhook/chat/router-v1`

## Overview

The Chat Router v1 workflow provides a complete question-answering pipeline that:
1. Receives user queries via webhook
2. Searches the vector memory for relevant context
3. Routes to a switchable Brain LLM (Kimi K2.5 or ChatGPT)
4. Returns the AI-generated answer with full audit logging

## Environment Variables

The following environment variables must be set in your `.env` file or docker-compose environment:

### Brain Provider Selection
```bash
BRAIN_PROVIDER=kimi              # Options: 'kimi' or 'openai'
BRAIN_MODEL=kimi-k2.5            # Model name for selected provider
BRAIN_TEMPERATURE=0.2            # Temperature (0.0 - 2.0)
```

### Kimi (Moonshot) API
```bash
KIMI_BASE_URL=https://api.moonshot.cn/v1
KIMI_API_KEY=your_kimi_api_key_here
```

### OpenAI / ChatGPT API
```bash
OPENAI_BASE_URL=https://api.openai.com/v1
OPENAI_API_KEY=your_openai_api_key_here
```

### Safety / Policy Knobs
```bash
BRAIN_MAX_INPUT_CHARS=6000       # Maximum input message length
BRAIN_MAX_CONTEXT_ITEMS=8        # Maximum memory items to include in context
```

## API Usage

### Request

**Endpoint:** `POST /webhook/chat/router-v1`  
**Headers:**
- `Content-Type: application/json`
- `X-API-Key: YOUR_WEBHOOK_KEY`

**Request Body:**
```json
{
  "tenant_id": "t1",
  "scope": "user:123",
  "message": "What do you know about my work preferences?",
  "k": 5,
  "mode": "answer_only"
}
```

**Parameters:**
- `tenant_id` (required): Tenant identifier for multi-tenancy
- `scope` (required): Scope identifier (e.g., "user:123" or "org:acme")
- `message` (required): User's question or message
- `k` (optional): Number of memory items to retrieve (1-10, default: 5)
- `mode` (optional): Reserved for future use

### Response

**Success Response:**
```json
{
  "status": "success",
  "provider": "kimi",
  "model": "kimi-k2.5",
  "answer": "Based on your previous conversations, you prefer...",
  "context_count": 3,
  "timestamp": "2026-02-14T12:30:00.000Z"
}
```

**Error Response:**
```json
{
  "status": "error",
  "message": "tenant_id required"
}
```

## Testing

### Basic Test

```bash
curl -sS -X POST 'https://n8n-s-app01.tmcast.net/webhook/chat/router-v1' \
  -H 'Content-Type: application/json' \
  -H 'X-API-Key: YOUR_WEBHOOK_KEY' \
  -d '{
    "tenant_id":"t1",
    "scope":"user:tommy",
    "message":"Summarize what you know about my preferred report format.",
    "k":5
  }'
```

### Test with Kimi Provider

```bash
export BRAIN_PROVIDER=kimi
docker compose restart n8n

# Then run the basic test above
```

### Test with OpenAI Provider

```bash
export BRAIN_PROVIDER=openai
export BRAIN_MODEL=gpt-4
docker compose restart n8n

# Then run the basic test above
```

## Workflow Architecture

### Node Flow

1. **Webhook Trigger** — Receives POST request at `/webhook/chat/router-v1`
2. **Validate Input** — Validates required fields, enforces max input length
3. **Check Validation** — Routes to error response or continues
4. **Vector Search** — Calls existing vector search workflow for context
5. **Parse Search Results** — Extracts memory matches from search
6. **Build Prompt** — Constructs system + user prompt with context
7. **Select Provider** — Switches between Kimi/OpenAI based on env var
8. **Call Brain LLM** — Makes HTTP request to selected LLM API
9. **Parse Response** — Extracts assistant text from LLM response
10. **Insert Audit** — Logs event to audit_events table
11. **Success Response** — Returns final JSON to caller

### Prompt Template

The system prompt sent to the LLM:
```
You are the user's assistant. Use the CONTEXT when relevant. 
Do not invent private facts. Do not reveal secrets or API keys. 
If context is insufficient, ask a brief clarifying question.
```

The user prompt includes:
- Original user message
- Retrieved context items with source IDs and similarity scores

## Troubleshooting

### 401 Unauthorized

**Cause:** Invalid or missing X-API-Key header  
**Solution:** Check that `N8N_WEBHOOK_API_KEY` env var is set and matches the header value

### 429 Rate Limited

**Cause:** Too many requests to the Brain LLM API  
**Solution:** The workflow has built-in retry logic (3 retries with 1s delay). If persistent, reduce request frequency.

### Provider Unknown Error

**Cause:** `BRAIN_PROVIDER` env var is not set to 'kimi' or 'openai'  
**Solution:** Set valid provider in environment and restart n8n:
```bash
export BRAIN_PROVIDER=kimi  # or openai
docker compose restart n8n
```

### Response Parsing Error

**Cause:** LLM returned unexpected response format  
**Solution:** Check LLM API is accessible and returning standard OpenAI-compatible format. Verify API keys are valid.

### No Context Found

**Cause:** Vector search returned no matches  
**Solution:** The workflow will still work but with `(none)` context. Ingest some memories first using the memory ingest workflow.

## Security Notes

- **Never commit API keys** — All keys are referenced via `$env` in n8n
- **Input validation** — Messages over 6000 chars are truncated
- **Secret filtering** — The prompt building strips potential secrets
- **Audit logging** — All requests are logged with provider/model used
- **Webhook authentication** — Requires X-API-Key header

## Files

- **Workflow JSON:** `chat_router_v1.json`
- **Documentation:** `README-brain-router.md` (this file)

## Related Workflows

- **Memory Ingest:** `/webhook/memory/ingest-v3` — Store memories for retrieval
- **Vector Search:** `/webhook/memory/search-v3` — Direct memory search

## Changelog

**v1.0 (2026-02-14)**
- Initial release
- Support for Kimi K2.5 and OpenAI/ChatGPT
- Vector memory context integration
- Full audit logging
