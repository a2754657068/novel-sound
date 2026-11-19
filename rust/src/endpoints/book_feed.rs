//! 首页「完结推荐 / 连载推荐 / 更多推荐」的统一数据源。
//!
//! 上游没有「全站推荐」这种接口，`new_category/landing/v` 必须带 `category_id`。
//! 所以这里在一级分类池里轮换采样：一次调用最多扫 `MAX_SWEEP` 个分类，按
//! `book_status` 过滤（服务端真生效），用调用方传来的 `exclude` 去重，凑够
//! `limit` 条就返回。`seed` 决定轮换起点，同一天内首页内容稳定。

use std::time::{Duration, Instant};

use futures::future::BoxFuture;
use serde_json::{json, Value};
use tokio::sync::Mutex;

use crate::endpoints::base::HOST_FQNOVEL;
use crate::endpoints::base::{dragon_read_headers, Upstream, UpstreamMode, UpstreamRequestSpec};
use crate::endpoints::home::reading724_params;
use crate::endpoints::util::default_val;
use crate::endpoints::{Ctx, Params, Server};
use crate::error::{ApiError, ApiResult};

const LANDING_PATH: &str = "/reading/bookapi/new_category/landing/v";
const FRONT_PATH: &str = "/reading/bookapi/new_category/front/v";
const MAX_SWEEP: usize = 8;
const SORTS: [&str; 4] = ["0", "24", "76", "12"];

static TILES: Mutex<Option<(Instant, Vec<(i64, String)>)>> = Mutex::const_new(None);

/// 偏好类型最多占几个采样名额（swEEP 里剩下的仍然是随机），这样既照顾口味
/// 又留出探索位，不至于越推越窄。
const MAX_PREFERRED_SWEEP: usize = 3;

/// 分类 id 列表，缓存 10 分钟。首页三类推荐共用它，避免每次进页面都先打一次
/// `new_category/front/v`。
async fn category_tiles(ctx: &Ctx) -> Vec<(i64, String)> {
    {
        let guard = TILES.lock().await;
        if let Some((at, tiles)) = guard.as_ref() {
            if at.elapsed() < Duration::from_secs(600) && !tiles.is_empty() {
                return tiles.clone();
            }
        }
    }
    let mut p = reading724_params();
    p.set("category_tab", "1".to_string());
    p.set("need_hot", "0".to_string());
    p.set("last_chose_tab", "1".to_string());
    p.set("source", "0".to_string());
    p.set("distinct_style", "0".to_string());
    p.set("new_category_tab", "1".to_string());
    p.set("sub_category_tab", "0".to_string());
    p.set("req_scene", "0".to_string());
    p.set("category_tab_v2", "1".to_string());
    p.set("last_choose_tab_v2", "1".to_string());
    let spec = UpstreamRequestSpec {
        mode: UpstreamMode::DeviceSigned,
        host: HOST_FQNOVEL.to_string(),
        path: FRONT_PATH.to_string(),
        params: p.to_pairs(),
        headers: dragon_read_headers(),
        ..Default::default()
    };
    let tiles = match Upstream::new(ctx.up.clone()).json(&spec).await {
        Ok(raw) => raw
            .get("data")
            .and_then(|d| d.get("down_category"))
            .and_then(|t| t.as_array())
            .map(|tiles| {
                tiles
                    .iter()
                    .filter_map(|tile| {
                        let id = tile.get("id").and_then(|v| match v {
                            Value::Number(n) => n.as_i64(),
                            Value::String(s) => s.parse::<i64>().ok(),
                            _ => None,
                        })?;
                        if id <= 0 {
                            return None;
                        }
                        let name = tile
                            .get("name")
                            .and_then(|v| v.as_str())
                            .unwrap_or_default()
                            .trim()
                            .to_string();
                        Some((id, name))
                    })
                    .collect::<Vec<(i64, String)>>()
            })
            .unwrap_or_default(),
        Err(_) => Vec::new(),
    };
    if !tiles.is_empty() {
        let mut guard = TILES.lock().await;
        *guard = Some((Instant::now(), tiles.clone()));
    }
    tiles
}

/// 采样顺序：命中偏好类型的分类排前面，其余保持原来的轮换顺序。
///
/// 匹配用双向包含（`玄幻脑洞` 与偏好词 `玄幻` 互相包含都算命中）——上游的
/// 分类名与书上的二级标签并不总是逐字相等，单向严格匹配会漏掉大半。
fn sweep_order(tiles: &[(i64, String)], start: usize, prefer: &[String]) -> Vec<(i64, String)> {
    let mut preferred: Vec<(i64, String)> = Vec::new();
    let mut rest: Vec<(i64, String)> = Vec::new();
    for offset in 0..tiles.len() {
        let index = (start + offset) % tiles.len();
        let (id, name) = &tiles[index];
        let hit = !prefer.is_empty()
            && prefer.iter().any(|p| {
                let p = p.trim();
                !p.is_empty() && (name.contains(p) || p.contains(name.as_str()))
            });
        if hit && preferred.len() < MAX_PREFERRED_SWEEP {
            preferred.push((*id, name.clone()));
        } else {
            rest.push((*id, name.clone()));
        }
    }
    preferred.extend(rest);
    preferred
}

async fn sample(
    ctx: &Ctx,
    category_id: i64,
    status: &str,
    sort: &str,
) -> ApiResult<Vec<Value>> {
    let mut p = reading724_params();
    p.set("category_id", category_id.to_string());
    p.set("query_gender", "1".to_string());
    p.set("sub_category_id", "0".to_string());
    p.set("book_status", status.to_string());
    p.set("word_number", "0".to_string());
    p.set("sort_by", sort.to_string());
    p.set("limit", "10".to_string());
    p.set("offset", "0".to_string());
    p.set("client_req_type", "1".to_string());
    p.set("page_version", "0".to_string());
    p.set("selected_items", String::new());
    p.set("selected_order", String::new());
    p.set("is_merged_landing_page", "false".to_string());
    p.set("no_need_all_tag", "false".to_string());
    let spec = UpstreamRequestSpec {
        mode: UpstreamMode::DeviceSigned,
        host: HOST_FQNOVEL.to_string(),
        path: LANDING_PATH.to_string(),
        params: p.to_pairs(),
        headers: dragon_read_headers(),
        ..Default::default()
    };
    let raw = Upstream::new(ctx.up.clone()).json(&spec).await?;
    Ok(raw
        .get("data")
        .and_then(|d| d.get("book_info"))
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default())
}

fn handle<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let status_text = default_val(&params.get_str("status"), "any");
        let book_status = match status_text.as_str() {
            "finished" => "0",
            "serial" => "1",
            _ => "2",
        };
        let limit: usize = params
            .get_str("limit")
            .parse::<usize>()
            .unwrap_or(10)
            .clamp(1, 30);
        let seed: u64 = params.get_str("seed").parse::<u64>().unwrap_or(1);
        let page: u64 = params.get_str("page").parse::<u64>().unwrap_or(0);
        let exclude: Vec<String> = params
            .get_str("exclude")
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();
        let mut seen: std::collections::HashSet<String> = exclude.into_iter().collect();

        let prefer: Vec<String> = params
            .get_str("prefer")
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .take(MAX_PREFERRED_SWEEP)
            .collect();

        let tiles = category_tiles(ctx).await;
        if tiles.is_empty() {
            return Err(ApiError::Internal("分类列表拿不到，无法生成推荐".to_string()));
        }

        let mut items: Vec<Value> = Vec::new();
        let start = ((seed.wrapping_add(page.wrapping_mul(7))) % tiles.len() as u64) as usize;
        let order = sweep_order(&tiles, start, &prefer);
        for step in 0..MAX_SWEEP.min(order.len()) {
            let category_id = order[step].0;
            let sort = SORTS[((seed as usize) + step) % SORTS.len()];
            let batch = match sample(ctx, category_id, book_status, sort).await {
                Ok(batch) => batch,
                Err(_) => continue,
            };
            for book in batch {
                let id = book
                    .get("book_id")
                    .and_then(|v| match v {
                        Value::String(s) => Some(s.clone()),
                        Value::Number(n) => Some(n.to_string()),
                        _ => None,
                    })
                    .unwrap_or_default();
                if id.is_empty() || !seen.insert(id) {
                    continue;
                }
                // 服务端按 book_status 过滤过了，这里再兜一层，防止上游偶发混入。
                if book_status != "2" {
                    let actual = book
                        .get("creation_status")
                        .map(|v| match v {
                            Value::String(s) => s.clone(),
                            Value::Number(n) => n.to_string(),
                            _ => String::new(),
                        })
                        .unwrap_or_default();
                    if !actual.is_empty() && actual != book_status {
                        continue;
                    }
                }
                items.push(book);
                if items.len() >= limit {
                    break;
                }
            }
            if items.len() >= limit {
                break;
            }
        }

        Ok(json!({
            "items": items,
            "hasMore": !items.is_empty(),
            "page": page,
        }))
    })
}

pub fn register(s: &mut Server) {
    s.add_route("book_feed", handle);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tiles() -> Vec<(i64, String)> {
        vec![
            (1, "都市".to_string()),
            (2, "玄幻脑洞".to_string()),
            (3, "悬疑".to_string()),
            (4, "东方仙侠".to_string()),
            (5, "历史".to_string()),
        ]
    }

    #[test]
    fn preferred_tiles_lead_the_sweep() {
        let order = sweep_order(&tiles(), 0, &["玄幻".to_string()]);
        assert_eq!(order[0], (2, "玄幻脑洞".to_string()));
        assert_eq!(order.len(), tiles().len());
    }

    #[test]
    fn preference_is_capped_so_exploration_survives() {
        // 三个偏好命中三个分类，第四个命中项也得让位给探索位。
        let prefer = vec!["都市".to_string(), "玄幻".to_string(), "悬疑".to_string()];
        let order = sweep_order(&tiles(), 0, &prefer);
        let leading = order
            .iter()
            .take(MAX_PREFERRED_SWEEP)
            .filter(|(_, name)| prefer.iter().any(|p| name.contains(p) || p.contains(name.as_str())))
            .count();
        assert_eq!(leading, MAX_PREFERRED_SWEEP);
        let exploring = order[MAX_PREFERRED_SWEEP..]
            .iter()
            .filter(|(_, name)| !prefer.iter().any(|p| name.contains(p) || p.contains(name.as_str())))
            .count();
        assert_eq!(exploring, 2);
    }

    #[test]
    fn no_preference_keeps_rotation_order() {
        let plain = sweep_order(&tiles(), 2, &[]);
        assert_eq!(plain[0].0, 3);
        assert_eq!(plain[0].1, "悬疑");
    }
}
