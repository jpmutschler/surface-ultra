# DGX Spark: the laptop's extension

The full, phased overhaul (for Claude Code on the Spark to execute) is `spark-overhaul-plan.md` in the DGX repo. This page is the laptop-side summary.

The Spark is on-prem hardware you control, so it sits inside the NDA perimeter with the laptop. It takes the heavy and shared work that can tolerate network latency. The laptop keeps anything interactive, hardware-bound or needed offline.

| Runs on the Spark | Why |
| --- | --- |
| Spec MCP (PCIe / NVMe / CXL), already running | Big index, shared, always on |
| NDA vendor RAG MCP + Qdrant collections (one per vendor: `vendor-<name>`) | One place to maintain the indexes; laptop gets replicas before trips |
| Ingestion: PDF parsing (tables, register maps), chunking, embedding, cross-reference resolution | Compute-heavy and long-prompt-heavy, where the laptop is weakest |
| Big models behind the Spark's LiteLLM (`spark/<model>` from the laptop) | Too big for the laptop's ~90 GB GPU budget |
| Langfuse, scheduled re-indexing, batch evals | Always-on jobs |

## Checklist

- [ ] **Same embedding model as the laptop.** The laptop's `sc-embed` (Qwen3-Embedding-4B) must match what built each collection, or offline replicas return garbage.
- [ ] **MCP over streamable HTTP**, one port per server. Match `SparkMcp` in `config/machine.psd1` (placeholders: `specs` on 8701, `nda-rag` on 8702).
- [ ] **A bearer token per MCP server.** The `nda-rag` token goes only into the laptop's NDA workspace (`D:\nda\secrets\spark-nda-rag.token`), never into an env var, a repo or a Claude config.
- [ ] **Qdrant API key on.** Set `SPARK_QDRANT_KEY` as a user env var on the laptop for snapshot sync.
- [ ] **Bind to the tailnet, not the office LAN,** if anyone else shares that network. Tailscale ACLs below.
- [ ] **NDA fence by permissions.** A dedicated `nda` service account owns the NDA paths and services; the cloud-facing agents on the Spark (Claude Code, Hermes/scout) can't read them. See Phase 1 of the Spark overhaul plan.
- [ ] **A no-content-logging LiteLLM key for the laptop** (`ultra-nda`). It goes into `D:\nda\secrets\spark-litellm-nda.key`; the laptop's NDA gateway uses it for `spark/*`.
- [ ] **No cloud fallbacks.** Make sure the Spark's LiteLLM has no cloud-provider route that NDA traffic could fall back to.
- [ ] **Citations in payloads.** Store `doc`, `page`, `section` and `table_id` in every chunk payload, so answers can cite and the bake-off can check citations.
- [ ] **Retrieval quality.** Prose and cross-references were the weak spot. Add per-chunk section headers (contextual chunking), parent-section retrieval, a pass that rewrites "see Table 7-12" into a link to that chunk, and reranking before the answer.
- [ ] **Snapshot hygiene.** `tools/Sync-ResearchReplica.ps1` deletes the snapshots it creates. Prune any others from the Qdrant snapshots dir.

## Tailscale ACL sketch

Only your own devices can reach the Spark's service ports. Adapt the users and tags to your tailnet.

```json
{
  "tagOwners": { "tag:spark": ["autogroup:admin"] },
  "acls": [
    { "action": "accept", "src": ["josh@serialcables.com"], "dst": ["tag:spark:22,3000,4000,6333,8701,8702"] }
  ]
}
```

## Research model tier

The Spark's `research` model (Nemotron 3 Super 120B-A12B NVFP4 on vLLM until the bake-off says otherwise) is the laptop's `spark/research`. `ccn` uses it whenever the Spark answers. Offline, the laptop's `sc-research` (the same family, a 4-bit GGUF) takes over.
