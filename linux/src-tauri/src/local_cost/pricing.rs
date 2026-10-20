//! Per-model USD estimate tables for the local cost readers — port of the
//! macOS ClaudeModelPrice / GeminiModelPrice / CopilotModelPrice tables
//! plus LocalCostPricing. Unknown models count tokens at $0.

use serde_json::Value;

use super::parsing;

/// Per-million-token USD prices for Claude models (mirrors CodexBar's
/// CostUsagePricing plus the provider-backed Claude Code models BirdNion
/// can write into settings.json).
#[derive(Clone, Copy)]
pub struct ClaudeModelPrice {
    pub input_per_m: f64,
    pub cache_read_per_m: f64,
    pub output_per_m: f64,
}

/// Hapo exposes provider-prefixed ids from /v1/models, but no rate card.
/// Keep this narrow to Hapo's ids so unrelated Claude-compatible backends
/// do not gain an inferred price. OpenAI's rate card has no cache-write
/// tier, so the Anthropic-shaped cache-creation counter uses fresh-input
/// pricing; cached reads retain their public discounted rate.
fn hapo_price(model: &str, input_side_tokens: i64) -> Option<ClaudeModelPrice> {
    if model.starts_with("openai.gpt-5.6-") {
        let long_context = input_side_tokens > 272_000;
        if model.contains("luna") {
            return Some(ClaudeModelPrice {
                input_per_m: if long_context { 2.0 } else { 1.0 },
                cache_read_per_m: if long_context { 0.20 } else { 0.10 },
                output_per_m: if long_context { 9.0 } else { 6.0 },
            });
        }
        if model.contains("terra") {
            return Some(ClaudeModelPrice {
                input_per_m: if long_context { 5.0 } else { 2.5 },
                cache_read_per_m: if long_context { 0.50 } else { 0.25 },
                output_per_m: if long_context { 22.5 } else { 15.0 },
            });
        }
        if model.contains("sol") {
            return Some(ClaudeModelPrice {
                input_per_m: if long_context { 10.0 } else { 5.0 },
                cache_read_per_m: if long_context { 1.0 } else { 0.5 },
                output_per_m: if long_context { 45.0 } else { 30.0 },
            });
        }
        return None;
    }

    // Hapo's current id is minimax.minimax-m2.5; retain its older
    // minimax-m2.5-ultra-* spelling so existing session logs reprice.
    if model.starts_with("minimax.minimax-m2.5") || model.starts_with("minimax-m2.5-ultra") {
        let high_speed = model.contains("highspeed");
        return Some(ClaudeModelPrice {
            input_per_m: if high_speed { 0.60 } else { 0.30 },
            cache_read_per_m: 0.03,
            output_per_m: if high_speed { 2.40 } else { 1.20 },
        });
    }
    None
}

impl ClaudeModelPrice {
    pub fn price_for(model: &str, input_side_tokens: i64) -> Option<ClaudeModelPrice> {
        let m = model.to_lowercase();
        if let Some(price) = hapo_price(&m, input_side_tokens) {
            return Some(price);
        }
        // Fable 5.1 discounts cached reads to $0.25/M; plain Fable 5 stays at
        // $1.00/M. Checked first so the fable-5 prefix below cannot claim it.
        if m.contains("fable-5-1") {
            return Some(ClaudeModelPrice {
                input_per_m: 10.0,
                cache_read_per_m: 0.25,
                output_per_m: 50.0,
            });
        }
        // Fable 5 — $10/$50 per-M. Cache pricing follows Anthropic's current
        // 1.25x write / 0.1x read ratios because local logs split those fields.
        if m.contains("fable-5") {
            return Some(ClaudeModelPrice {
                input_per_m: 10.0,
                cache_read_per_m: 1.0,
                output_per_m: 50.0,
            });
        }
        // MiniMax-M3 Standard: <=512k input-side tokens is $0.30/$1.20/$0.06,
        // >512k doubles. MiniMax only documents a cache-read discount for M3,
        // so cache writes are priced as fresh input.
        if m.contains("minimax-m3") {
            let over_512k = input_side_tokens > 512_000;
            let input = if over_512k { 0.60 } else { 0.30 };
            return Some(ClaudeModelPrice {
                input_per_m: input,
                cache_read_per_m: if over_512k { 0.12 } else { 0.06 },
                output_per_m: if over_512k { 2.40 } else { 1.20 },
            });
        }
        // Opus 4 and 4.1 kept the original $15/$75 card; only Opus 4.8 and
        // Opus 5 moved to $5/$25. Matched ahead of the generic opus branch.
        if m.contains("opus-4-1") || m.contains("opus-4-2025") {
            return Some(ClaudeModelPrice {
                input_per_m: 15.0,
                cache_read_per_m: 1.50,
                output_per_m: 75.0,
            });
        }
        // Opus 4.8 / Opus 5 — $5 / $6.25 / $0.50 / $25 per-M.
        if m.contains("opus") {
            return Some(ClaudeModelPrice {
                input_per_m: 5.0,
                cache_read_per_m: 0.50,
                output_per_m: 25.0,
            });
        }
        // Haiku 4.x — $1 / $1.25 / $0.10 / $5 per-M.
        if m.contains("haiku") {
            return Some(ClaudeModelPrice {
                input_per_m: 1.0,
                cache_read_per_m: 0.10,
                output_per_m: 5.0,
            });
        }
        // Sonnet 5 — $2 / $2.50 / $0.20 / $10 per-M, cheaper than Sonnet 4.x.
        // Matched ahead of the generic sonnet branch.
        if m.contains("sonnet-5") {
            return Some(ClaudeModelPrice {
                input_per_m: 2.0,
                cache_read_per_m: 0.20,
                output_per_m: 10.0,
            });
        }
        // Sonnet 4.x / 3.x — $3 / $3.75 / $0.30 / $15 per-M.
        if m.contains("sonnet") {
            return Some(ClaudeModelPrice {
                input_per_m: 3.0,
                cache_read_per_m: 0.30,
                output_per_m: 15.0,
            });
        }
        None
    }
}

/// Per-million-token USD prices for Gemini models (Google rate card,
/// <=200k tier). Unknown models still count tokens but cost $0.
#[derive(Clone, Copy)]
pub struct GeminiModelPrice {
    pub input_per_m: f64,
    pub output_per_m: f64,
    pub cached_per_m: f64,
}

impl GeminiModelPrice {
    pub fn price_for(model: &str) -> Option<GeminiModelPrice> {
        let m = model.to_lowercase();
        if m.starts_with("gemini-2.5-flash-lite") || m.starts_with("gemini-flash-lite") {
            return Some(GeminiModelPrice {
                input_per_m: 0.10,
                output_per_m: 0.40,
                cached_per_m: 0.025,
            });
        }
        if m.starts_with("gemini-2.5-flash") || m.starts_with("gemini-flash-") {
            return Some(GeminiModelPrice {
                input_per_m: 0.30,
                output_per_m: 2.50,
                cached_per_m: 0.075,
            });
        }
        if m.starts_with("gemini-3") {
            return Some(GeminiModelPrice {
                input_per_m: 2.00,
                output_per_m: 12.00,
                cached_per_m: 0.20,
            });
        }
        if m.starts_with("gemini-2.5-pro")
            || m.starts_with("gemini-pro")
            || m.starts_with("gemini-2.0-pro")
        {
            return Some(GeminiModelPrice {
                input_per_m: 1.25,
                output_per_m: 10.00,
                cached_per_m: 0.31,
            });
        }
        if m.starts_with("gemini-2.0-flash") {
            return Some(GeminiModelPrice {
                input_per_m: 0.10,
                output_per_m: 0.40,
                cached_per_m: 0.025,
            });
        }
        if m.starts_with("gemini-1.5-pro") {
            return Some(GeminiModelPrice {
                input_per_m: 1.25,
                output_per_m: 5.00,
                cached_per_m: 0.31,
            });
        }
        if m.starts_with("gemini-1.5-flash") {
            return Some(GeminiModelPrice {
                input_per_m: 0.075,
                output_per_m: 0.30,
                cached_per_m: 0.02,
            });
        }
        None
    }

    pub fn cost(model: &str, input: i64, output: i64, cached: i64) -> f64 {
        match Self::price_for(model) {
            Some(p) => {
                (input as f64 * p.input_per_m
                    + output as f64 * p.output_per_m
                    + cached as f64 * p.cached_per_m)
                    / 1_000_000.0
            }
            None => 0.0,
        }
    }
}

/// Shared USD estimate across the extra local sources: Claude-family models
/// price through ClaudeModelPrice, Gemini-family through GeminiModelPrice,
/// everything else counts tokens at $0.
pub fn estimate_local_cost(
    model: &str,
    input: i64,
    cache_read: i64,
    cache_write: i64,
    output: i64,
) -> f64 {
    let m = model.to_lowercase();
    if m.contains("claude") {
        if let Some(p) = ClaudeModelPrice::price_for(&m, input + cache_write) {
            return ((input + cache_write) as f64 * p.input_per_m
                + cache_read as f64 * p.cache_read_per_m
                + output as f64 * p.output_per_m)
                / 1_000_000.0;
        }
    }
    if m.contains("gemini") {
        if let Some(p) = GeminiModelPrice::price_for(&m) {
            return ((input + cache_write) as f64 * p.input_per_m
                + cache_read as f64 * p.cached_per_m
                + output as f64 * p.output_per_m)
                / 1_000_000.0;
        }
    }
    0.0
}

/// Token counters of one Copilot usage snapshot. Component fields are
/// preferred; total_only carries a bare total when the log has no
/// breakdown (never added on top of components, which would double count).
#[derive(Clone, Copy, Default, PartialEq)]
pub struct CopilotTokenCounts {
    pub input: i64,
    pub output: i64,
    pub cache_read: i64,
    pub cache_write: i64,
    pub total_only: i64,
}

impl CopilotTokenCounts {
    pub fn from_usage(usage: &serde_json::Map<String, Value>) -> Self {
        let pick = |keys: &[&str]| -> i64 {
            for key in keys {
                if let Some(v) = usage.get(*key).and_then(parsing::int) {
                    return v;
                }
            }
            0
        };
        let input = pick(&["inputTokens", "input_tokens"]);
        let output = pick(&["outputTokens", "output_tokens"]);
        let cache_read = pick(&[
            "cacheReadTokens",
            "cache_read_tokens",
            "cacheReadInputTokens",
        ]);
        let cache_write = pick(&[
            "cacheWriteTokens",
            "cache_write_tokens",
            "cacheCreationTokens",
        ]);
        let total_only = if input + output + cache_read + cache_write == 0 {
            pick(&["totalTokens", "total_tokens", "total"])
        } else {
            0
        };
        Self {
            input,
            output,
            cache_read,
            cache_write,
            total_only,
        }
    }

    pub fn total(&self) -> i64 {
        self.input + self.output + self.cache_read + self.cache_write + self.total_only
    }

    /// Per-component growth since previous (counters are cumulative).
    pub fn delta(&self, previous: &CopilotTokenCounts) -> CopilotTokenCounts {
        CopilotTokenCounts {
            input: (self.input - previous.input).max(0),
            output: (self.output - previous.output).max(0),
            cache_read: (self.cache_read - previous.cache_read).max(0),
            cache_write: (self.cache_write - previous.cache_write).max(0),
            total_only: (self.total_only - previous.total_only).max(0),
        }
    }
}

/// USD estimate for Copilot CLI models: Claude-family via the shared Claude
/// price table, GPT-family via gpt_per_m, else $0 (tokens still count).
pub fn copilot_estimate(model: &str, counts: &CopilotTokenCounts) -> f64 {
    let m = model.to_lowercase();
    if m.contains("claude") {
        let Some(p) =
            ClaudeModelPrice::price_for(&m, counts.input + counts.total_only + counts.cache_write)
        else {
            return 0.0;
        };
        // A bare total has no input/output split; price it at the input
        // rate (the lower bound) instead of inventing a split.
        return ((counts.input + counts.total_only) as f64 * p.input_per_m
            + counts.cache_write as f64 * p.input_per_m
            + counts.cache_read as f64 * p.cache_read_per_m
            + counts.output as f64 * p.output_per_m)
            / 1_000_000.0;
    }
    match gpt_per_m(&m) {
        Some(per_m) => counts.total() as f64 * per_m / 1_000_000.0,
        None => 0.0,
    }
}

/// Blended per-million rate for GPT-family models (input+output mixed).
fn gpt_per_m(model: &str) -> Option<f64> {
    if model.starts_with("gpt-5") {
        return Some(3.75);
    }
    if model.starts_with("gpt-4.1") || model.starts_with("gpt-4o") {
        return Some(4.00);
    }
    if model.starts_with("gpt-4") {
        return Some(15.00);
    }
    if model.starts_with("o3") || model.starts_with("o4") {
        return Some(6.00);
    }
    if model.starts_with("gemini") {
        return Some(2.00);
    }
    None
}

/// Devin CLI transcript model rates (per million): input/output/cache_read —
/// the modelCostData table on docs.devin.ai/desktop/models.
pub fn devin_rates(model: &str) -> Option<(f64, f64, f64)> {
    match model {
        "swe-2-max" | "swe-2-high" | "swe-2-medium" => Some((0.75, 3.75, 0.075)),
        "swe-1-7" | "swe-1-7-medium" => Some((0.5, 2.5, 0.2)),
        "swe-1-7-lightning" | "swe-1-7-lightning-medium" => Some((2.5, 12.5, 1.0)),
        "swe-1-6" | "swe-1-6-fast" => Some((0.5, 2.5, 0.2)),
        _ => None,
    }
}

/// USD for one Devin step: uncached prompt x input + cached prompt x
/// cache-read + completion x output. cached_tokens is a subset of
/// prompt_tokens, so uncached = prompt - cached.
pub fn devin_usd_cost(
    model: &str,
    prompt_tokens: i64,
    cached_tokens: i64,
    completion_tokens: i64,
) -> f64 {
    let Some((input, output, cache_read)) = devin_rates(model) else {
        return 0.0;
    };
    let uncached = (prompt_tokens - cached_tokens).max(0);
    (uncached as f64 * input
        + cached_tokens as f64 * cache_read
        + completion_tokens as f64 * output)
        / 1_000_000.0
}
