use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sqlx::FromRow;
use uuid::Uuid;

use crate::errors::DatabaseError;

/// Kind of activity observation. Maps to CHECK constraint in 0032.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActivityEventType {
    AppForeground,
    WebVisit,
}

impl ActivityEventType {
    pub fn as_str(&self) -> &'static str {
        match self {
            ActivityEventType::AppForeground => "app_foreground",
            ActivityEventType::WebVisit => "web_visit",
        }
    }
    pub fn from_str(s: &str) -> Result<Self, DatabaseError> {
        match s {
            "app_foreground" => Ok(ActivityEventType::AppForeground),
            "web_visit" => Ok(ActivityEventType::WebVisit),
            other => Err(DatabaseError::InvalidInput(format!(
                "unknown activity event type '{other}'"
            ))),
        }
    }
}

/// One row in activity_events. Append-only, local-only.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityEvent {
    pub id: Uuid,
    pub workspace_id: Option<Uuid>,
    pub app_name: String,
    pub bundle_id: Option<String>,
    pub window_title: Option<String>,
    pub url_domain: Option<String>,
    pub url_title: Option<String>,
    pub event_type: ActivityEventType,
    pub started_at: DateTime<Utc>,
    pub ended_at: Option<DateTime<Utc>>,
    pub duration_seconds: Option<i64>,
    pub metadata: Option<serde_json::Value>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, FromRow)]
pub(crate) struct ActivityEventRow {
    pub id: Uuid,
    pub workspace_id: Option<Uuid>,
    pub app_name: String,
    pub bundle_id: Option<String>,
    pub window_title: Option<String>,
    pub url_domain: Option<String>,
    pub url_title: Option<String>,
    pub event_type: String,
    pub started_at: DateTime<Utc>,
    pub ended_at: Option<DateTime<Utc>>,
    pub duration_seconds: Option<i64>,
    pub metadata: Option<String>,
    pub created_at: DateTime<Utc>,
}

impl TryFrom<ActivityEventRow> for ActivityEvent {
    type Error = DatabaseError;
    fn try_from(row: ActivityEventRow) -> Result<Self, Self::Error> {
        let metadata = row
            .metadata
            .map(|raw| serde_json::from_str(&raw).map_err(|e| DatabaseError::InvalidInput(format!("corrupt activity metadata: {e}"))))
            .transpose()?;
        Ok(ActivityEvent {
            id: row.id,
            workspace_id: row.workspace_id,
            app_name: row.app_name,
            bundle_id: row.bundle_id,
            window_title: row.window_title,
            url_domain: row.url_domain,
            url_title: row.url_title,
            event_type: ActivityEventType::from_str(&row.event_type)?,
            started_at: row.started_at,
            ended_at: row.ended_at,
            duration_seconds: row.duration_seconds,
            metadata,
            created_at: row.created_at,
        })
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NewActivityEvent {
    pub workspace_id: Option<Uuid>,
    pub app_name: String,
    pub bundle_id: Option<String>,
    pub window_title: Option<String>,
    pub url_domain: Option<String>,
    pub url_title: Option<String>,
    pub event_type: ActivityEventType,
    pub started_at: DateTime<Utc>,
    pub ended_at: Option<DateTime<Utc>>,
    pub duration_seconds: Option<i64>,
    pub metadata: Option<serde_json::Value>,
}

// ── Aggregates returned to the frontend ──────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityDaySummary {
    pub date: String,
    pub active_seconds: i64,
    pub focus_sessions: i64,
    pub applications: i64,
    pub websites: i64,
    /// Whether there was any underlying activity at all.
    pub has_data: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityTimelineEventDto {
    pub id: String,
    pub time: String, // "09:12"
    pub app: String,
    pub app_symbol: String,
    pub title: String,
    pub subtitle: String,
    pub duration_minutes: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivitySessionDto {
    pub id: String,
    pub title: String,
    pub time_range: String, // "09:12 — 11:21"
    pub apps_description: String,
    pub detail: String,
    pub events: Vec<ActivityTimelineEventDto>,
    pub apps: i64,
    pub files: i64,
    pub web_pages: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityAppUsageDto {
    pub id: String,
    pub app: String,
    pub display_name: String,
    pub minutes: i64,
    pub percent: f64,
    pub files: Vec<ActivityFileUsageDto>,
    pub sessions: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityFileUsageDto {
    pub id: String,
    pub name: String,
    pub minutes: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityWebUsageDto {
    pub id: String,
    pub domain: String,
    pub title: String,
    pub minutes: i64,
    pub pages: i64,
    pub favicon: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityDonutSegment {
    pub id: String,
    pub label: String,
    pub percent: f64,
    pub minutes: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceCorrelationDto {
    pub workspace_name: String,
    pub project: String,
    pub active_minutes: i64,
    pub apps: Vec<(String, i64)>, // (appName, minutes)
    pub files_modified: i64,
    pub files_opened: i64,
    pub web_pages: i64,
    pub has_data: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WhatHappenedDto {
    pub id: String,
    pub date_label: String,
    pub workspace: String,
    pub title: String,
    pub summary: String,
    pub detail: Option<String>,
    pub apps: Vec<(String, String)>, // (name, durationStr)
    pub files: i64,
    pub sessions: i64,
    pub web_pages: i64,
    pub outcome: Option<String>,
    pub has_sufficient_evidence: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecentMemoryDto {
    pub id: String,
    pub date_label: String,
    pub title: String,
    pub subtitle: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityOverviewDto {
    pub day: ActivityDaySummary,
    pub sessions: Vec<ActivitySessionDto>,
    pub app_usages: Vec<ActivityAppUsageDto>,
    pub web_usages: Vec<ActivityWebUsageDto>,
    pub donut: Vec<ActivityDonutSegment>,
    pub correlation: WorkspaceCorrelationDto,
    pub what_happened: Option<WhatHappenedDto>,
    pub recent_memory: Vec<RecentMemoryDto>,
    /// If no real activity exists, the UI should show an empty-state, not zeros.
    pub is_empty: bool,
    pub empty_reason: Option<String>,
}
