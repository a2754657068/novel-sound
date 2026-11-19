//! 分类浏览：`/reading/bookapi/new_category/landing/v` 的封装。
//!
//! 这个接口的 `offset`/`limit` 在服务端被忽略（永远回 10 条、`offset` 恒为 10），
//! 但**每次请求返回的是该分类池子里的一批轮换样本**，并且 `sub_category_id` /
//! `sort_by` / `book_status` / `word_number` 是真正生效的筛选维度。
//! 所以「加载更多」不能靠翻页，而要靠轮换「子分类 × 排序」组合反复采样，
//! 由客户端按 book_id 去重累积。

use futures::future::BoxFuture;
use serde_json::{json, Value};

use crate::endpoints::base::HOST_FQNOVEL;
use crate::endpoints::base::{dragon_read_headers, Upstream, UpstreamMode, UpstreamRequestSpec};
use crate::endpoints::{Ctx, Params, Server};
use crate::endpoints::home::reading724_params;
use crate::error::{ApiError, ApiResult};

const LANDING_PATH: &str = "/reading/bookapi/new_category/landing/v";

fn build_params(params: &Params) -> (Params, i64) {
    let category_id = params.get_str("id");
    let gender = params.get_str("gender");
    let sub = params.get_str("sub");
    let status = params.get_str("status");
    let words = params.get_str("words");
    let sort = params.get_str("sort");

    let mut p = reading724_params();
    p.set("category_id", category_id);
    p.set("query_gender", if gender.is_empty() { "1".to_string() } else { gender });
    p.set("sub_category_id", if sub.is_empty() { "0".to_string() } else { sub });
    p.set("book_status", if status.is_empty() { "2".to_string() } else { status });
    p.set("word_number", if words.is_empty() { "0".to_string() } else { words });
    p.set("sort_by", if sort.is_empty() { "0".to_string() } else { sort });
    p.set("limit", "10".to_string());
    p.set("offset", "0".to_string());
    p.set("client_req_type", "1".to_string());
    p.set("page_version", "0".to_string());
    p.set("selected_items", String::new());
    p.set("selected_order", String::new());
    p.set("is_merged_landing_page", "false".to_string());
    p.set("no_need_all_tag", "false".to_string());

    let cid = p.get_str("category_id").parse::<i64>().unwrap_or(0);
    (p, cid)
}

use futures::stream::{FuturesUnordered, StreamExt};
use std::collections::HashMap;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;

/// 学到的下拉选项（子分类 / 排序）缓存：并发采样要知道该轮换哪些值。
static OPTIONS: Mutex<Option<(Instant, HashMap<i64, (Vec<String>, Vec<String>)>)>> =
    Mutex::const_new(None);

/// 整份响应缓存：同一组条件的重复请求（切筛选切回来）直接命中。
static RESULTS: Mutex<Option<(Instant, HashMap<String, Value>)>> = Mutex::const_new(None);

const OPTIONS_TTL: Duration = Duration::from_secs(600);
const RESULTS_TTL: Duration = Duration::from_secs(90);
const RESULTS_MAX: usize = 96;
const DEFAULT_SORTS: [&str; 4] = ["0", "24", "76", "12"];

fn cache_key(params: &Params, batch: usize) -> String {
    format!(
        "{}|{}|{}|{}|{}|{}|{}",
        batch,
        params.get_str("id"),
        params.get_str("gender"),
        params.get_str("sub"),
        params.get_str("status"),
        params.get_str("words"),
        params.get_str("sort"),
    )
}

async fn cached_result(key: &str) -> Option<Value> {
    let guard = RESULTS.lock().await;
    let (at, map) = guard.as_ref()?;
    if at.elapsed() > RESULTS_TTL {
        return None;
    }
    map.get(key).cloned()
}

async fn store_result(key: String, value: Value) {
    let mut guard = RESULTS.lock().await;
    let now = Instant::now();
    let expired = guard.as_ref().map(|(at, _)| at.elapsed() > RESULTS_TTL).unwrap_or(true);
    if expired {
        *guard = Some((now, HashMap::new()));
    }
    if let Some((_, map)) = guard.as_mut() {
        if map.len() >= RESULTS_MAX {
            map.clear();
        }
        map.insert(key, value);
    }
}

async fn known_options(category_id: i64) -> Option<(Vec<String>, Vec<String>)> {
    let guard = OPTIONS.lock().await;
    let (at, map) = guard.as_ref()?;
    if at.elapsed() > OPTIONS_TTL {
        return None;
    }
    map.get(&category_id).cloned()
}

async fn learn_options(category_id: i64, subs: Vec<String>, sorts: Vec<String>) {
    if subs.is_empty() && sorts.is_empty() {
        return;
    }
    let mut guard = OPTIONS.lock().await;
    let now = Instant::now();
    let expired = guard.as_ref().map(|(at, _)| at.elapsed() > OPTIONS_TTL).unwrap_or(true);
    if expired {
        *guard = Some((now, HashMap::new()));
    }
    if let Some((_, map)) = guard.as_mut() {
        let entry = map.entry(category_id).or_insert_with(|| (Vec::new(), Vec::new()));
        if !subs.is_empty() {
            entry.0 = subs;
        }
        if !sorts.is_empty() {
            entry.1 = sorts;
        }
    }
}

fn render(p: &Params, data: &Value) -> Value {
    let items = data
        .get("book_info")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let rule = data.get("rule").cloned().unwrap_or(Value::Null);
    let has_more = data
        .get("has_more")
        .and_then(|v| v.as_bool())
        .unwrap_or(!items.is_empty());
    let options = json!({
        "subCategories": rule.get("sub_category").and_then(|v| v.as_array()).cloned().unwrap_or_default(),
        "bookStatus": rule.get("book_status").and_then(|v| v.as_array()).cloned().unwrap_or_default(),
        "wordTypes": rule.get("word_type").and_then(|v| v.as_array()).cloned().unwrap_or_default(),
        "sortBy": rule.get("sort_by").and_then(|v| v.as_array()).cloned().unwrap_or_default(),
    });
    let _ = p;
    json!({
        "items": items,
        "hasMore": has_more,
        "options": options,
        "category": data.get("category").cloned().unwrap_or(Value::Null),
    })
}

fn values_of(options: &Value, key: &str) -> Vec<String> {
    options
        .get(key)
        .and_then(|v| v.as_array())
        .map(|list| {
            list.iter()
                .filter_map(|entry| entry.get("value"))
                .map(|value| match value {
                    Value::String(text) => text.clone(),
                    other => other.to_string(),
                })
                .filter(|text| !text.is_empty())
                .collect::<Vec<_>>()
        })
        .unwrap_or_default()
}

/// 并发打 `batch` 个轮换组合（子分类 × 排序），合并去重后一次返回。
fn handle<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let (base, category_id) = build_params(params);
        if category_id <= 0 {
            return Err(ApiError::BadRequest("missing category id".to_string()));
        }
        let batch = params
            .get_str("batch")
            .parse::<usize>()
            .unwrap_or(1)
            .clamp(1, 8)
            .min(8);

        // 单路请求直接走缓存；命中就不打上游。
        let key = cache_key(params, batch);
        if batch == 1 {
            if let Some(hit) = cached_result(&key).await {
                return Ok(hit);
            }
        }

        // 决定这一批要轮换的值：已有选项就按子分类铺开，没有就用排序兜底。
        let combos: Vec<(String, String)> = if batch <= 1 {
            vec![(
                base.get_str("sub"),
                base.get_str("sort"),
            )]
        } else if let Some((subs, sorts)) = known_options(category_id).await {
            let mut out = Vec::new();
            for sub in subs.iter().take(batch) {
                out.push((sub.clone(), base.get_str("sort")));
            }
            if out.len() < batch {
                for sort in sorts.iter() {
                    out.push((base.get_str("sub"), sort.clone()));
                    if out.len() >= batch {
                        break;
                    }
                }
            }
            if out.is_empty() {
                out.push((base.get_str("sub"), base.get_str("sort")));
            }
            out
        } else {
            (0..batch)
                .map(|index| {
                    (
                        base.get_str("sub"),
                        DEFAULT_SORTS[index % DEFAULT_SORTS.len()].to_string(),
                    )
                })
                .collect()
        };

        let mut futures = FuturesUnordered::new();
        for (sub, sort) in combos.clone() {
            let mut p = base.clone();
            p.set("sub_category_id", sub.clone());
            p.set("sort_by", sort.clone());
            let spec = UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                host: HOST_FQNOVEL.to_string(),
                path: LANDING_PATH.to_string(),
                params: p.to_pairs(),
                headers: dragon_read_headers(),
                ..Default::default()
            };
            let up = ctx.up.clone();
            futures.push(async move { Upstream::new(up).json(&spec).await });
        }

        let mut pages: Vec<Value> = Vec::new();
        let mut first_error: Option<ApiError> = None;
        while let Some(result) = futures.next().await {
            match result {
                Ok(raw) => pages.push(raw.get("data").cloned().unwrap_or(Value::Null)),
                Err(error) => {
                    if first_error.is_none() {
                        first_error = Some(error);
                    }
                }
            }
        }
        if pages.is_empty() {
            return Err(first_error.unwrap_or_else(|| ApiError::Internal("分类请求失败".to_string())));
        }

        // 学到子分类/排序，供下次并发铺开用。
        let first = pages.first().cloned().unwrap_or(Value::Null);
        let first_view = render(&base, &first);
        let options = first_view.get("options").cloned().unwrap_or(Value::Null);
        let subs = values_of(&options, "subCategories");
        let sorts = values_of(&options, "sortBy");
        if subs.len() > 1 || sorts.len() > 1 {
            learn_options(category_id, subs, sorts).await;
        }

        // 合并：按 book_id 去重，保持各页内顺序。
        let mut merged: Vec<Value> = Vec::new();
        let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
        let mut has_more = false;
        for data in &pages {
            let view = render(&base, data);
            if view.get("hasMore").and_then(|v| v.as_bool()).unwrap_or(false) {
                has_more = true;
            }
            if let Some(items) = view.get("items").and_then(|v| v.as_array()) {
                for item in items {
                    let id = item
                        .get("book_id")
                        .map(|v| match v {
                            Value::String(text) => text.clone(),
                            other => other.to_string(),
                        })
                        .unwrap_or_default();
                    if id.is_empty() || seen.insert(id) {
                        merged.push(item.clone());
                    }
                }
            }
        }

        let payload = json!({
            "items": merged,
            "hasMore": has_more,
            "options": options,
            "category": first_view.get("category").cloned().unwrap_or(Value::Null),
        });
        store_result(key, payload.clone()).await;
        Ok(payload)
    })
}

pub fn register(s: &mut Server) {
    s.add_route("category_feed", handle);
}
