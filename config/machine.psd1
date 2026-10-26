@{
    # ------------------------------------------------------------------ identity
    GitUserName  = 'Joshua'
    GitUserEmail = 'josh@serialcables.com'

    # ------------------------------------------------------------------ storage
    # Create the Dev Drive yourself first (Settings > System > Storage > Advanced storage
    # settings > Disks & volumes > Create dev drive). Scripts fall back to C:\ if it's missing.
    DevDriveLetter = 'D'
    DevRootName    = 'dev'       # D:\dev     - repos, venvs, uv/npm/HF caches
    ModelRootName  = 'models'    # D:\models  - GGUF / safetensors, one folder per alias
    ToolsRootName  = 'tools'     # D:\tools   - llama.cpp builds, llama-swap
    MinFreeGBAfterPull = 60      # 51-PullModels refuses to leave less than this free

    # ------------------------------------------------------------------ unified memory (set in the NVIDIA app)
    # The GPU's model budget is the DEDICATED split you choose in the NVIDIA app (128 GB units ship 64/64;
    # reviews show up to 96 GB dedicated). CUDA allocations land in dedicated memory first and spill into the
    # shared segment (smaller pages, slower) only when it is full - so the main model + resident set must fit
    # in dedicated. sc-research (65 GB) + the resident set (~13 GB) + KV cache needs the 96 GB split.
    # At 96/32 Windows itself sees ~30 GB, hence WslMemoryGB 12 below.
    GpuDedicatedTargetGB = 96        # 00-Preflight / 90-Validate compare the real split against this
    # CUDA allocations also count against Windows' commit limit (RAM Windows sees + page file). With 96 GB
    # dedicated the default page file is too small to load ~85 GB of weights (NVIDIA forum report, Oct 2026,
    # unconfirmed by NVIDIA). 10-WindowsBase sets a fixed page file on C: of this size; 0 = leave Windows-managed.
    # It is reserved address space, not written in normal use. 90-Validate measures commit headroom.
    PageFileGB = 80

    # ------------------------------------------------------------------ local inference
    LlamaCppTag        = 'latest'                      # or pin e.g. 'b11435'; NVIDIA's porting page lists b10360
    LlamaCppAssetRegex = 'bin-win-cuda-13\.\d+-arm64\.zip$'
    CudartAssetRegex   = '^cudart-llama-bin-win-cuda-13\.\d+-arm64\.zip$'
    LlamaSwapTag       = 'latest'
    LlamaSwapAssetRegex = 'windows_arm64'
    LlamaSwapListen    = '127.0.0.1:8080'              # loopback only; WSL reaches it via mirrored networking
    InstallOllama      = $false                        # NVIDIA ships a Windows-on-Arm Ollama; optional convenience

    # Path to the CUDA 13.4+ Windows-on-Arm installer you download from developer.nvidia.com.
    # Leave empty to skip (llama.cpp ships its own cudart; the toolkit is only needed for nvcc/CUDA dev).
    CudaInstallerPath  = ''

    # ------------------------------------------------------------------ toolchain
    # Stage 20 installs Visual Studio (the MSVC toolset is also needed for wheels without win_arm64 builds)
    # plus the matching SDK + WDK for driver work.
    #   Version '2026' pairs with the current WDK (10.0.28000); '2022' pairs with WDK 26100.6584.
    #   Edition 'BuildTools' = compiler only; 'Community' = the IDE (needed for driver projects + debugger UI).
    VisualStudio = @{                                # decided Oct 26, 2026: VS 2026 Community
        Version = '2026'
        Edition = 'Community'
    }
    VsComponents    = @(
        'Microsoft.VisualStudio.Workload.NativeDesktop'
        'Microsoft.VisualStudio.ComponentGroup.NativeDesktop.Core'
        'Microsoft.VisualStudio.Component.VC.Tools.ARM64'
        'Microsoft.VisualStudio.Component.VC.Tools.ARM64EC'
        'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'          # x64 cross tools: customer drivers target x64
        'Microsoft.VisualStudio.Component.VC.Runtimes.ARM64.Spectre'  # WDK builds need Spectre-mitigated libs
        'Microsoft.VisualStudio.Component.VC.Runtimes.ARM64EC.Spectre'
        'Microsoft.VisualStudio.Component.VC.Runtimes.x86.x64.Spectre'
        'Microsoft.VisualStudio.Component.VC.ATL.ARM64.Spectre'
        'Microsoft.VisualStudio.Component.VC.ATL.Spectre'
    )
    InstallWdk      = $true      # driver work moves to this machine; SDK + WDK versions follow VisualStudio.Version
    PythonVersions  = @('3.12', '3.13')
    UvTools         = @('huggingface_hub[cli]', 'ruff', 'pre-commit')

    # ------------------------------------------------------------------ WSL2
    WslDistro       = 'Ubuntu-24.04'
    WslMemoryGB     = 12         # Windows sees only ~30 GB at the 96/32 split; raise only with a 64/64 split
    WslSwapGB       = 16
    WslProcessors   = 16
    WslVhdMaxGB     = 256

    # ------------------------------------------------------------------ network peers (DGX Spark = extension of this box)
    SparkHost        = 'spark'                         # Tailscale MagicDNS name of the DGX Spark
    SparkLiteLLMUrl  = 'http://spark:4000/v1'
    SparkLangfuseUrl = 'http://spark:3000'             # leave empty to disable trace export
    SparkQdrantUrl   = 'http://spark:6333'             # source for offline replicas (API key: env SPARK_QDRANT_KEY)
    LiteLLMPort      = 4000
    OpenWebUIPort    = 3000

    # MCP servers hosted on the Spark (streamable HTTP over the tailnet, bearer token per server).
    # Zone decides who may use it:
    #   'nda'      - vendor NDA material. Local clients ONLY. Never registered with any Claude product.
    #   'licensed' - member-licensed specs (PCI-SIG, NVMe, CXL). Local by default; set ClaudeCode = $true
    #                only if you accept short spec excerpts going to the cloud.
    #   'public'   - safe for Claude Code.
    # Ports/paths below are placeholders - match them to the Spark (see spark/README.md).
    # Tokens: 'licensed'/'public' read a user env var (TokenEnv); 'nda' tokens live in the NDA workspace
    # (TokenFile, relative to D:\nda), which Claude Code is denied.
    SparkMcp = @(
        @{ Name = 'specs';   Url = 'http://spark:8701/mcp'; Zone = 'licensed'; TokenEnv  = 'SPARK_MCP_SPECS_TOKEN'; ClaudeCode = $false }
        @{ Name = 'nda-rag'; Url = 'http://spark:8702/mcp'; Zone = 'nda';      TokenFile = 'secrets\spark-nda-rag.token'; ClaudeCode = $false }
    )

    # Offline mode: Qdrant collections copied to the laptop before a trip (tools/Sync-ResearchReplica.ps1),
    # and the local MCP commands that serve them when the Spark is unreachable (tools/Set-ResearchMode.ps1).
    # Zone 'nda' collections restore into the NDA-session Qdrant (127.0.0.1:6335, key in D:\nda\secrets);
    # the rest into the everyday Qdrant (127.0.0.1:6333).
    ReplicaCollections = @(
        # @{ Name = 'pcie-6.2';    Zone = 'licensed' }
        # @{ Name = 'vendor-acme'; Zone = 'nda' }
    )
    ReplicaMcp = @(
        # @{ Name = 'specs';   Zone = 'licensed'; Command = 'uv'; Args = @('run', '--directory', 'D:\dev\src\serialcables-mcp', 'spec-mcp'); Env = @{ QDRANT_URL = 'http://127.0.0.1:6333' } }
        # @{ Name = 'nda-rag'; Zone = 'nda';      Command = 'uv'; Args = @('run', '--directory', 'D:\dev\src\serialcables-mcp', 'nda-rag-mcp'); Env = @{ QDRANT_URL = 'http://127.0.0.1:6335' } }
    )

    # ------------------------------------------------------------------ NDA workspace + guard (rules, no vault)
    # NDA SDKs/docs are research material only: they live here, outside every project and outside
    # Claude Code's working directories, and are never copied into a repo. Projects ship our own API.
    #   D:\nda\terms\<vendor>.txt     protected terms ("REAL => ALIAS" per line)
    #   D:\nda\docs\<vendor>\        vendor SDKs, PDFs, headers
    #   D:\nda\projects\<name>\      research projects (plan pipeline workspace)
    #   D:\nda\secrets\               Spark NDA tokens, NDA Qdrant key
    NdaRootName     = 'nda'                            # under the Dev Drive (or C:\) root
    NdaQdrantPort   = 6335                             # NDA Qdrant runs only during an NDA session (tools/NdaSession.ps1)
    NdaLiteLLMPort  = 4001                             # NDA gateway: same routes, NO trace export; runs only during an NDA session
    # Recall (if Windows offers it on this unit) is opt-in and keeps snapshots on the device, so it does not
    # break the cloud rule. 'UserChoice' leaves it to you; 'Disable' turns it off by policy.
    RecallPolicy    = 'UserChoice'

    # ------------------------------------------------------------------ ccn: Claude Code on local models (NDA research)
    # A second, separate Claude Code profile: its own config dir inside the NDA workspace (settings, MCP list,
    # transcripts), pointed at the NDA gateway with that gateway's key (never your Max login), nonessential
    # traffic off. Started with `ccn` or the red "NDA | LOCAL" Windows Terminal profile.
    Ccn = @{
        ConfigDirName = '.claude'                      # -> D:\nda\.claude
        ModelOnline   = 'spark/research'               # when the Spark answers
        ModelOffline  = 'sc-research'
        FastModel     = 'sc-fast'                      # Claude Code's background/haiku slot
        TabColor      = '#B00020'
    }

    # ------------------------------------------------------------------ storage tiers
    # hot  = internal Gen5 SSD (everything that runs)
    # nas  = model library + archive. First reachable root wins (LAN name, LAN IP, then a Tailscale name if you add one).
    # cold = SanDisk Extreme Fit (USB 3.2 Gen 1) travel cache, found by volume label; nothing ever runs from it.
    NasRoots        = @('\\home-nas\surface-ultra', '\\192.168.5.203\surface-ultra')
    NasModelsSubdir = 'models'
    NasArchiveSubdir = 'archive'
    ColdVolumeLabel = 'SU-COLD'
    ColdRootName    = 'surface-ultra'
    TravelModels    = @('sc-research-alt')             # extra models to carry on the flash drive for trips

    # ------------------------------------------------------------------ workspace
    # Fill in your real remotes. Empty Url entries are skipped.
    Repos = @(
        @{ Name = 'serialcables-atlas3'; Url = '' }
        @{ Name = 'serialcables-hydra';  Url = '' }
        @{ Name = 'serialcables-hermes'; Url = '' }
        @{ Name = 'sphinx-mctp';         Url = '' }
        @{ Name = 'serialcables-mcp';    Url = '' }
        @{ Name = 'calypso';             Url = '' }
        @{ Name = 'hcc';                 Url = '' }
    )

    # ------------------------------------------------------------------ apps beyond the terminal (stage 22, optional)
    # Terminal first. These are installed so they're there when a project needs them.
    InstallIdes        = $true
    IdeApps = @(
        @{ Id = 'JetBrains.Toolbox'; Note = 'install PyCharm + CLion from it; licenses follow your JetBrains account' }
        @{ Id = 'Microsoft.WinDbg';  Note = 'kernel debugging (kdnet to an x64 test box)' }
    )
    TerminalTools = @('Helix.Helix', 'BurntSushi.ripgrep.MSVC', 'sharkdp.bat', 'dandavison.delta', 'charmbracelet.glow', 'junegunn.fzf')
    # Old x64 PC kept as a lab host: x64 driver test target (kdnet), x64 build fallback, Veeam file-level restores.
    LabHostX64 = ''                                    # its hostname, once you've decided

    # Claude Code agent personas (Vega, Dr. Lane Prescott, I2C/I3C OOB engineer) - folder of .md files to copy
    # into %USERPROFILE%\.claude\agents. Typically a folder inside one of the repos above.
    AgentPersonaSource = ''

    # MCP servers registered with Claude Code (cloud model) at user scope. Command runs natively on Windows.
    # Only servers whose data may reach the cloud: HIL control of Serial Cables' own hardware is fine;
    # anything in the 'nda' zone is refused by 70-ClaudeCode.ps1.
    ClaudeMcpServers = @(
        # @{ Name = 'serialcables'; Command = 'uv'; Args = @('run', '--directory', 'D:\dev\src\serialcables-mcp', 'serialcables-mcp') }
    )
}
