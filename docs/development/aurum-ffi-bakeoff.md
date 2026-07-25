# Aurum-ffi vs WhisperKit bake-off

**Date:** 2026-07-24  
**Machine:** Apple Silicon (M5-class host used for ZephyrFlow)  
**Fixtures:** macOS `say` → 16 kHz mono f32le (5 utterances)  
**Runs:** 5 warm timed decodes per fixture after 1 warm-up; stress 30× on `sentence`

## Setup

| Engine | Model | Host |
|--------|--------|------|
| **aurum-ffi** | `tiny-q5_1` (ggml, Metal via whisper-rs) | Rust bakeoff binary linking `aurum-ffi` |
| **WhisperKit** | `openai_whisper-tiny` (Core ML) | Swift SPM executable |

Spike commands (repro):

```bash
# Aurum
cd /tmp/aurum-read && cargo build -p aurum-ffi --release
cd /tmp/aurum-bakeoff && cargo run --release

# WhisperKit
cd /tmp/aurum-bakeoff/whisperkit-bench && swift run -c release WhisperKitBench
```

## Results

### Load / size

| Metric | aurum-ffi tiny-q5_1 | WhisperKit tiny |
|--------|--------------------:|----------------:|
| Cold preload | **10351 ms** (incl. ~31 MB download) | **12175 ms** (download/load) |
| Cache on disk | **~32 MB** (32152758 B) | **~73 MB** (measured hub cache) |
| Stress 30× | **30/30 OK** (6533 ms total) | **30/30 OK** (2190 ms total) |

### Warm finalize latency (ms)

| Fixture | audio_s | Aurum p50 | Aurum p95 | WK p50 | WK p95 |
|---------|--------:|----------:|----------:|-------:|-------:|
| short | 1.32 | 130 | 146 | **52** | **75** |
| sentence | 2.53 | 216 | 300 | **66** | **75** |
| fillers | 2.24 | 279 | 481 | **69** | **73** |
| numbers | 2.75 | 193 | 211 | **75** | **79** |
| negation | 2.02 | 204 | 231 | **67** | **71** |
| **overall** | | **204** | **347** | **68** | **77** |

WhisperKit is ~**3× faster** warm finalize on this host/fixtures.

### Text quality (side-by-side)

| Fixture | Reference | Aurum hyp | WhisperKit hyp |
|---------|-----------|-----------|----------------|
| short | Testing one two three. | testing 1 2 3. | testing 1 2 3 |
| sentence | Please send the invoice… | **exact** | **exact** |
| fillers | Um I think we should ship… | on my think we should ship it today you know. | **I think we should ship it today you know.** |
| numbers | …seventeen minutes in region one. | The Outage lasted 17 minutes and region 1. | The Outage lasted 17 minutes in region 1. |
| negation | Do not deploy… | do not deploy… (keeps negation) | do not deploy… (keeps negation) |

Both usable for dictation. WhisperKit slightly cleaner on fillers; both keep negation; both numeric-ize “seventeen”→17.

Aurum `cleanup_rules(Clean)` stripped trailing “you know” on fillers (good) but left “On my think…”.

### Integration cost (qualitative)

| Factor | aurum-ffi | WhisperKit |
|--------|-----------|------------|
| Language | Rust + C ABI → Swift | Native Swift SPM |
| Build | cmake + C++ + cargo | SPM only |
| Packaging | Need xcframework / static lib in app | Already in ZephyrFlow |
| Partials | Host loop + single-flight (documented) | Already implemented in branch |
| Apple Speech fallback | N/A | Exists |
| Dual binary size | +libaurum_ffi + ggml model | Status quo |

### Spike status

- [x] Built `libaurum_ffi` release  
- [x] E2E `transcribe_pcm` + preload + cancel-capable API exercised  
- [x] Bake-off table on shared PCM fixtures  
- [x] Stress: no failures  

## Recommendation

### **No-go for replacing WhisperKit as default (now)**

Reasons:

1. **Latency:** WhisperKit Tiny is clearly faster warm (~68 vs ~204 ms p50). Hold-to-talk finalize UX favors WK.  
2. **Integration cost:** ZephyrFlow is Swift/SPM; Aurum needs Rust toolchain in CI + embed packaging. Not justified without a win.  
3. **Quality:** No clear Aurum win on these fixtures; WK slightly better on fillers.  
4. **Product already ships WK** with partials path, model picker, Apple Speech fallback.

### **When to revisit**

- Need smaller first download than Core ML Tiny and accept slower decode  
- Want shared model cache with Aurum CLI users  
- Aurum ships official xcframework + versioned ABI and wins a re-bake on device class we care about  
- WhisperKit stability issues force an alternate engine  

### **Optional mild coupling (not required)**

- Keep **policy constants** aligned (1s / 15s / 1.2s) — already true  
- Cross-link READMEs: Aurum = files/CLI; ZephyrFlow = live dictation  
- Do **not** add aurum-ffi to ZephyrFlow Package.swift until a go decision  

## Decision

**Defer Aurum engine integration.** Keep WhisperKit. Re-open only with new evidence or packaging milestone.
