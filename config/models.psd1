@{
    # One entry per llama-swap model. 51-PullModels.ps1 downloads entries with Pull = $true
    # (or the ones you name with -Alias / -All) into <ModelRoot>\<Alias>\ and regenerates
    # llama-swap.yaml. Repo/file names verified on Hugging Face 2026-10-08 (re-tiered for research 2026-10-26).
    # Coding is Claude's job now, so there is no local coder tier; the local stack is for private R&D.
    #
    # Group 'resident' : loaded together, never evicted (small/always-on models)
    # Group 'main'     : only one loaded at a time (the big models swap with each other)
    # TtlSeconds       : 0 = never unload; >0 = unload after that many idle seconds
    #
    # Common llama-server args are added by the generator: -ngl 999 --no-mmap --alias <Alias>
    # (--no-mmap avoids holding the file twice - page cache + GPU copy - on unified memory.)

    Models = @(
        # ---- 'main' group: one big model loaded at a time (they swap on demand) ----
        @{
            Alias       = 'sc-research'
            Description = 'Primary NDA research model: Nemotron 3 Super 120B-A12B (NVIDIA Open Model License), long context'
            Group       = 'main'
            Repo        = 'unsloth/NVIDIA-Nemotron-3-Super-120B-A12B-GGUF'
            Include     = @('UD-IQ4_XS/*')
            Main        = 'UD-IQ4_XS/*.gguf'      # first shard sorts first
            Args        = '-c 131072 -ctk q8_0 -ctv q8_0 --jinja'
            SizeGB      = 65
            License     = 'NVIDIA Open Model License'
            TtlSeconds  = 0
            Pull        = $true
        }
        @{
            Alias       = 'sc-analyst'
            Description = 'Fast analyst: Qwen3.6-35B-A3B (Apache-2.0), vision for tables/figures/scope shots, RAG drafting'
            Group       = 'main'
            Repo        = 'unsloth/Qwen3.6-35B-A3B-GGUF'
            Include     = @('Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf', 'mmproj-F16.gguf')
            Main        = 'Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf'
            Mmproj      = 'mmproj-F16.gguf'
            Args        = '-c 131072 -ctk q8_0 -ctv q8_0 --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0'
            SizeGB      = 23.3
            License     = 'Apache-2.0'
            TtlSeconds  = 0
            Pull        = $true
        }
        @{
            Alias       = 'sc-research-alt'
            Description = 'Bake-off challenger: gpt-oss-120b MXFP4 (Apache-2.0) - faster decode; check citation faithfulness'
            Group       = 'main'
            Repo        = 'ggml-org/gpt-oss-120b-GGUF'
            Include     = @('gpt-oss-120b-MXFP4*.gguf')
            Main        = 'gpt-oss-120b-MXFP4*.gguf'
            Args        = '-c 131072 --jinja'
            SizeGB      = 63.4
            License     = 'Apache-2.0'
            TtlSeconds  = 900
            Pull        = $false
        }
        # ---- 'resident' group: small models that stay loaded together ----
        @{
            Alias       = 'sc-fast'
            Description = 'Router / query rewriting / summaries: Nemotron 3 Nano 4B Q8'
            Group       = 'resident'
            Repo        = 'unsloth/NVIDIA-Nemotron-3-Nano-4B-GGUF'
            Include     = @('NVIDIA-Nemotron-3-Nano-4B-Q8_0.gguf')
            Main        = 'NVIDIA-Nemotron-3-Nano-4B-Q8_0.gguf'
            Args        = '-c 32768 --jinja'
            SizeGB      = 4.3
            License     = 'NVIDIA Open Model License'
            TtlSeconds  = 0
            Pull        = $true
        }
        @{
            Alias       = 'sc-embed'
            Description = 'Query-time embeddings: Qwen3-Embedding-4B Q8 (must match the Spark index model)'
            Group       = 'resident'
            Repo        = 'Qwen/Qwen3-Embedding-4B-GGUF'
            Include     = @('Qwen3-Embedding-4B-Q8_0.gguf')
            Main        = 'Qwen3-Embedding-4B-Q8_0.gguf'
            Args        = '--embedding --pooling last -c 8192 -ub 8192 -b 8192'
            SizeGB      = 4.3
            License     = 'Apache-2.0'
            TtlSeconds  = 0
            Pull        = $true
        }
        @{
            Alias       = 'sc-rerank'
            Description = 'Reranker (required for research RAG): Qwen3-Reranker-4B Q8 (Apache-2.0)'
            Group       = 'resident'
            Repo        = 'QuantFactory/Qwen3-Reranker-4B-GGUF'   # community quant - verify scores vs the Spark reranker in the bake-off
            Include     = @('*Q8_0.gguf')
            Main        = '*Q8_0.gguf'
            Args        = '--reranking -c 8192 -ub 8192 -b 8192'
            SizeGB      = 4.3
            License     = 'Apache-2.0'
            TtlSeconds  = 0
            Pull        = $true
        }
    )
}
