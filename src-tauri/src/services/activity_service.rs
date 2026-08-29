use std::collections::{HashMap, HashSet};

use chrono::{DateTime, Datelike, TimeZone, Utc};
use uuid::Uuid;

use crate::errors::DatabaseError;
use crate::models::activity::{
    ActivityAppUsageDto, ActivityDaySummary, ActivityDonutSegment, ActivityEvent,
    ActivityOverviewDto, ActivitySessionDto, ActivityTimelineEventDto, ActivityWebUsageDto,
    NewActivityEvent, RecentMemoryDto, WhatHappenedDto, WorkspaceCorrelationDto,
};
use crate::repositories::{ActivityRepository, FileRepository, TimelineRepository, WorkspaceRepository};
use crate::session::detector::{detect_sessions, DEFAULT_INACTIVITY_THRESHOLD_SECONDS};

#[derive(Debug, Clone)]
pub struct ActivityService {
    activity_repository: ActivityRepository,
    timeline_repository: TimelineRepository,
    file_repository: FileRepository,
    workspace_repository: WorkspaceRepository,
}

impl ActivityService {
    pub fn new(
        activity_repository: ActivityRepository,
        timeline_repository: TimelineRepository,
        file_repository: FileRepository,
        workspace_repository: WorkspaceRepository,
    ) -> Self {
        Self {
            activity_repository,
            timeline_repository,
            file_repository,
            workspace_repository,
        }
    }

    pub async fn record(&self, input: NewActivityEvent) -> Result<ActivityEvent, DatabaseError> {
        self.activity_repository.create(input).await
    }

    pub async fn get_overview(
        &self,
        workspace_id: Option<Uuid>,
        date_filter: Option<String>,
        search_query: Option<String>,
    ) -> Result<ActivityOverviewDto, DatabaseError> {
        // Resolve date window
        let (since, until, date_label) = Self::resolve_date_window(date_filter.as_deref());

        // Fetch timeline events in window (for session reconstruction)
        // We need a windowed query; if not available fallback to list_by_workspace + filter
        let timeline_events = self.fetch_timeline_window(workspace_id, since, until).await?;

        // Fetch activity events in window
        let activity_events = self
            .activity_repository
            .list_by_workspace_window(workspace_id, since, until, Some(500))
            .await?;

        // Filter by search if provided
        let filtered_timeline = if let Some(q) = search_query.as_ref().map(|s| s.to_lowercase()).filter(|s| !s.trim().is_empty()) {
            Self::filter_events(&timeline_events, &q)
        } else {
            timeline_events.clone()
        };
        let filtered_activity = if let Some(q) = search_query.as_ref().map(|s| s.to_lowercase()).filter(|s| !s.trim().is_empty()) {
            activity_events
                .into_iter()
                .filter(|a| {
                    a.app_name.to_lowercase().contains(&q)
                        || a.window_title.as_deref().unwrap_or("").to_lowercase().contains(&q)
                        || a.url_domain.as_deref().unwrap_or("").to_lowercase().contains(&q)
                        || a.url_title.as_deref().unwrap_or("").to_lowercase().contains(&q)
                })
                .collect()
        } else {
            activity_events
        };

        // Detect sessions from timeline events (source of truth for focus sessions)
        // If no timeline events, sessions will be empty — that's honest.
        let sessions_raw = detect_sessions(filtered_timeline.clone(), DEFAULT_INACTIVITY_THRESHOLD_SECONDS);

        // Build hero summary
        let day_summary = Self::build_day_summary(
            &sessions_raw,
            &filtered_activity,
            &date_label,
            since,
        );

        // Build timeline DTOs from sessions
        let sessions = self.build_session_dtos(sessions_raw.clone()).await?;

        // Build app usages from activity_events
        let app_usages = Self::build_app_usages(&filtered_activity);
        let web_usages = Self::build_web_usages(&filtered_activity);
        let donut = Self::build_donut(&app_usages, &filtered_activity);

        // Workspace correlation
        let correlation = self.build_correlation(workspace_id, since, until, &filtered_activity, &filtered_timeline).await?;

        // What happened — pick most recent session that has meaningful activity
        // For overview, use sessions from last 7 days window for "Yesterday" context
        let what_happened = self.build_what_happened(workspace_id, &sessions).await?;

        // Recent memory — last 4 sessions across any workspace, mapped to memory-like DTOs
        let recent_memory = self.build_recent_memory(workspace_id).await?;

        let is_empty = day_summary.active_seconds == 0 && sessions.is_empty() && app_usages.is_empty() && web_usages.is_empty();
        let empty_reason = if is_empty {
            Some("Not enough activity yet — work in a workspace and ContextSphere will reconstruct your sessions here.".to_string())
        } else {
            None
        };

        Ok(ActivityOverviewDto {
            day: day_summary,
            sessions,
            app_usages,
            web_usages,
            donut,
            correlation,
            what_happened,
            recent_memory,
            is_empty,
            empty_reason,
        })
    }

    fn resolve_date_window(filter: Option<&str>) -> (DateTime<Utc>, DateTime<Utc>, String) {
        let now = Utc::now();
        let today = now.date_naive();
        match filter.unwrap_or("Today").to_lowercase().as_str() {
            "yesterday" => {
                let d = today - chrono::Duration::days(1);
                (Utc.from_utc_datetime(&d.and_hms_opt(0, 0, 0).unwrap()), Utc.from_utc_datetime(&d.and_hms_opt(23, 59, 59).unwrap()), "Yesterday".into())
            }
            "this week" => {
                let start = today - chrono::Duration::days(today.num_days_from_ce().rem_euclid(7) as i64);
                // approximate: last 7 days
                let since = Utc.from_utc_datetime(&(today - chrono::Duration::days(7)).and_hms_opt(0, 0, 0).unwrap());
                let until = Utc.from_utc_datetime(&today.and_hms_opt(23, 59, 59).unwrap());
                (since, until, "This Week".into())
            }
            "last 7 days" => {
                let since = Utc.from_utc_datetime(&(today - chrono::Duration::days(7)).and_hms_opt(0, 0, 0).unwrap());
                let until = Utc.from_utc_datetime(&today.and_hms_opt(23, 59, 59).unwrap());
                (since, until, "Last 7 Days".into())
            }
            _ => {
                // Today
                let since = Utc.from_utc_datetime(&today.and_hms_opt(0, 0, 0).unwrap());
                let until = Utc.from_utc_datetime(&today.and_hms_opt(23, 59, 59).unwrap());
                (since, until, "Today".into())
            }
        }
    }

    async fn fetch_timeline_window(
        &self,
        workspace_id: Option<Uuid>,
        since: DateTime<Utc>,
        until: DateTime<Utc>,
    ) -> Result<Vec<crate::models::TimelineEvent>, DatabaseError> {
        // Use workspace-specific or global query.
        // TimelineRepository currently lacks window method, so we filter in-memory.
        // This is acceptable for today's data volumes; indexed queries can be added later.
        let raw = if let Some(ws) = workspace_id {
            self.timeline_repository.list_by_workspace(ws, None).await?
        } else {
            self.timeline_repository.list_recent(500).await?
        };
        Ok(raw.into_iter().filter(|e| e.occurred_at >= since && e.occurred_at <= until).collect())
    }

    fn filter_events(events: &[crate::models::TimelineEvent], q: &str) -> Vec<crate::models::TimelineEvent> {
        events.iter().filter(|e| {
            let meta_str = e.metadata.as_ref().map(|v| v.to_string().to_lowercase()).unwrap_or_default();
            e.event_type.as_str().contains(q) || meta_str.contains(q)
        }).cloned().collect()
    }

    fn build_day_summary(
        sessions: &[crate::session::types::Session],
        activity_events: &[ActivityEvent],
        date_label: &str,
        _since: DateTime<Utc>,
    ) -> ActivityDaySummary {
        // Active seconds from sessions (timeline) + activity events durations where available
        let session_seconds: i64 = sessions.iter().map(|s| s.duration_seconds).sum();
        let activity_seconds: i64 = activity_events.iter().filter_map(|a| a.duration_seconds).sum();
        let active_seconds = if activity_seconds > 0 { activity_seconds } else { session_seconds.max(0) };

        let focus_sessions = sessions.len() as i64;
        let applications = activity_events.iter().filter(|a| a.event_type == crate::models::activity::ActivityEventType::AppForeground).map(|a| &a.app_name).collect::<HashSet<_>>().len() as i64;
        let websites = activity_events.iter().filter(|a| a.event_type == crate::models::activity::ActivityEventType::WebVisit).filter_map(|a| a.url_domain.as_ref()).collect::<HashSet<_>>().len() as i64;

        let has_data = active_seconds > 0 || focus_sessions > 0 || applications > 0 || websites > 0;
        ActivityDaySummary {
            date: date_label.to_string(),
            active_seconds,
            focus_sessions,
            applications,
            websites,
            has_data,
        }
    }

    async fn build_session_dtos(
        &self,
        sessions: Vec<crate::session::types::Session>,
    ) -> Result<Vec<ActivitySessionDto>, DatabaseError> {
        let mut out = Vec::new();
        for sess in sessions {
            let start = sess.started_at.format("%H:%M").to_string();
            let end = sess.ended_at.format("%H:%M").to_string();
            let time_range = format!("{start} — {end}");
            // Determine apps/files/web for this session by filtering events that overlap session window
            // For now apps from session's events file types + languages; files = distinct file count; web = 0 (no web timeline events)
            let apps = if sess.languages.is_empty() { 1 } else { sess.languages.len().min(3) } as i64;
            let files = sess.file_count as i64;
            let web_pages = 0; // web visits not in timeline; will be enriched when activity_events present

            let apps_desc = format!("{} applications · {} files · {} web pages", apps, files, web_pages);
            let detail = if apps > 1 { "Mixed work session" } else { "Focused session" }.to_string();
            let title = format!("SESSION {}", start); // placeholder; workspace name enrichment could be added

            // Build timeline events DTOs from sess.events (up to 6)
            let mut event_dtos = Vec::new();
            for e in sess.events.iter().take(6) {
                let time = e.occurred_at.format("%H:%M").to_string();
                let (app, title, subtitle, symbol) = Self::map_timeline_event(e).await;
                // Try to get file name if file_id present
                let subtitle = if let Some(fid) = e.file_id {
                    if let Ok(file) = self.file_repository.get_by_id(fid).await {
                        file.path_or_url.split('/').last().unwrap_or(&subtitle).to_string()
                    } else { subtitle }
                } else { subtitle };
                event_dtos.push(ActivityTimelineEventDto {
                    id: e.id.to_string(),
                    time,
                    app: app.clone(),
                    app_symbol: symbol,
                    title,
                    subtitle,
                    duration_minutes: None,
                });
            }

            out.push(ActivitySessionDto {
                id: sess.started_at.to_rfc3339(),
                title: format!("WORK SESSION {}", time_range),
                time_range,
                apps_description: apps_desc,
                detail,
                events: event_dtos,
                apps,
                files,
                web_pages,
            });
        }
        Ok(out)
    }

    async fn map_timeline_event(e: &crate::models::TimelineEvent) -> (String, String, String, String) {
        match e.event_type {
            crate::models::TimelineEventType::Create => ("Finder".into(), "File created".into(), "Created".into(), "doc.fill".into()),
            crate::models::TimelineEventType::Edit => ("Xcode".into(), "Xcode".into(), "Edited file".into(), "hammer.fill".into()),
            crate::models::TimelineEventType::Open => ("Xcode".into(), "Xcode".into(), "Opened file".into(), "doc".into()),
            crate::models::TimelineEventType::Move => ("Finder".into(), "Finder".into(), "Moved".into(), "folder.fill".into()),
            crate::models::TimelineEventType::Delete => ("Finder".into(), "Finder".into(), "Deleted".into(), "trash".into()),
            crate::models::TimelineEventType::Commit => ("Terminal".into(), "Terminal".into(), "Commit".into(), "terminal.fill".into()),
            crate::models::TimelineEventType::Visit => ("Safari".into(), "Safari".into(), "Visited".into(), "safari.fill".into()),
            crate::models::TimelineEventType::Screenshot => ("Finder".into(), "Finder".into(), "Screenshot".into(), "camera.fill".into()),
            crate::models::TimelineEventType::Close => ("Finder".into(), "Finder".into(), "Closed".into(), "xmark".into()),
            crate::models::TimelineEventType::WorkspaceSwitch => ("System".into(), "Workspace".into(), "Switched workspace".into(), "arrow.swap".into()),
        }
    }

    fn build_app_usages(events: &[ActivityEvent]) -> Vec<ActivityAppUsageDto> {
        let mut map: HashMap<String, (i64, usize)> = HashMap::new(); // app_name -> (total_seconds, count)
        for ev in events.iter().filter(|e| e.event_type == crate::models::activity::ActivityEventType::AppForeground) {
            let entry = map.entry(ev.app_name.clone()).or_insert((0, 0));
            entry.0 += ev.duration_seconds.unwrap_or(0);
            entry.1 += 1;
        }
        if map.is_empty() {
            return Vec::new();
        }
        let total: i64 = map.values().map(|(s, _)| *s).sum();
        let mut usages: Vec<ActivityAppUsageDto> = map
            .into_iter()
            .map(|(app, (secs, _cnt))| {
                let minutes = secs / 60;
                let percent = if total > 0 { secs as f64 / total as f64 } else { 0.0 };
                ActivityAppUsageDto {
                    id: app.to_lowercase(),
                    app: app.clone(),
                    display_name: app.clone(),
                    minutes,
                    percent,
                    files: Vec::new(),
                    sessions: Vec::new(),
                }
            })
            .collect();
        usages.sort_by(|a, b| b.minutes.cmp(&a.minutes));
        usages
    }

    fn build_web_usages(events: &[ActivityEvent]) -> Vec<ActivityWebUsageDto> {
        let mut map: HashMap<String, (i64, usize, String)> = HashMap::new(); // domain -> (secs, count, title)
        for ev in events.iter().filter(|e| e.event_type == crate::models::activity::ActivityEventType::WebVisit) {
            if let Some(domain) = &ev.url_domain {
                let entry = map.entry(domain.clone()).or_insert((0, 0, ev.url_title.clone().unwrap_or_else(|| domain.clone())));
                entry.0 += ev.duration_seconds.unwrap_or(0);
                entry.1 += 1;
                if entry.2.is_empty() {
                    entry.2 = ev.url_title.clone().unwrap_or_else(|| domain.clone());
                }
            }
        }
        let mut usages: Vec<ActivityWebUsageDto> = map
            .into_iter()
            .map(|(domain, (secs, cnt, title))| ActivityWebUsageDto {
                id: domain.clone(),
                domain: domain.clone(),
                title,
                minutes: secs / 60,
                pages: cnt as i64,
                favicon: "globe".into(),
            })
            .collect();
        usages.sort_by(|a, b| b.minutes.cmp(&a.minutes));
        usages
    }

    fn build_donut(usages: &[ActivityAppUsageDto], events: &[ActivityEvent]) -> Vec<ActivityDonutSegment> {
        if usages.is_empty() {
            // If no app events but there were timeline sessions, create a single segment for timeline-derived activity
            if !events.is_empty() {
                return vec![ActivityDonutSegment {
                    id: "timeline".into(),
                    label: "Workspace files".into(),
                    percent: 1.0,
                    minutes: 0,
                }];
            }
            return Vec::new();
        }
        usages.iter().map(|u| ActivityDonutSegment {
            id: u.id.clone(),
            label: u.display_name.clone(),
            percent: u.percent,
            minutes: u.minutes,
        }).collect()
    }

    async fn build_correlation(
        &self,
        workspace_id: Option<Uuid>,
        since: DateTime<Utc>,
        until: DateTime<Utc>,
        activity_events: &[ActivityEvent],
        timeline_events: &[crate::models::TimelineEvent],
    ) -> Result<WorkspaceCorrelationDto, DatabaseError> {
        let ws_name = if let Some(ws_id) = workspace_id {
            self.workspace_repository.get_by_id(ws_id).await.map(|w| w.name).unwrap_or_else(|_| "ContextSphere".into())
        } else {
            // active workspace or first
            let active = self.workspace_repository.list_active_workspaces().await.unwrap_or_default();
            active.first().map(|w| w.name.clone()).unwrap_or_else(|| "No workspace".into())
        };
        let project = "Active context".to_string();
        let active_minutes: i64 = activity_events.iter().filter_map(|a| a.duration_seconds).sum::<i64>() / 60;
        let active_minutes = if active_minutes == 0 {
            // fallback to timeline session durations
            let sess = detect_sessions(timeline_events.to_vec(), DEFAULT_INACTIVITY_THRESHOLD_SECONDS);
            sess.iter().map(|s| s.duration_seconds).sum::<i64>() / 60
        } else { active_minutes };

        // Build apps list from activity events or fallback
        let mut apps: Vec<(String, i64)> = Vec::new();
        if !activity_events.is_empty() {
            let mut map: HashMap<String, i64> = HashMap::new();
            for ev in activity_events.iter().filter(|e| e.event_type == crate::models::activity::ActivityEventType::AppForeground) {
                *map.entry(ev.app_name.clone()).or_insert(0) += ev.duration_seconds.unwrap_or(0) / 60;
            }
            for (k, v) in map { apps.push((k, v)); }
            apps.sort_by(|a,b| b.1.cmp(&a.1));
        } else {
            // No app data yet — honest empty
        }

        let files_modified = timeline_events.iter().filter(|e| e.event_type == crate::models::TimelineEventType::Edit).count() as i64;
        let files_opened = timeline_events.iter().filter(|e| e.event_type == crate::models::TimelineEventType::Open).count() as i64;
        let web_pages = activity_events.iter().filter(|e| e.event_type == crate::models::activity::ActivityEventType::WebVisit).count() as i64;

        let has_data = active_minutes > 0 || !apps.is_empty() || files_modified > 0;
        Ok(WorkspaceCorrelationDto {
            workspace_name: ws_name,
            project,
            active_minutes,
            apps,
            files_modified,
            files_opened,
            web_pages,
            has_data,
        })
    }

    async fn build_what_happened(
        &self,
        workspace_id: Option<Uuid>,
        _sessions: &[ActivitySessionDto],
    ) -> Result<Option<WhatHappenedDto>, DatabaseError> {
        // Use most recent session across last 7 days as "what happened"
        let since = Utc::now() - chrono::Duration::days(7);
        let until = Utc::now();
        let raw_events = self.fetch_timeline_window(workspace_id, since, until).await?;
        if raw_events.is_empty() {
            return Ok(None);
        }
        let sessions = detect_sessions(raw_events.clone(), DEFAULT_INACTIVITY_THRESHOLD_SECONDS);
        if sessions.is_empty() {
            return Ok(None);
        }
        // Pick the session with longest duration
        let best = sessions.iter().max_by_key(|s| s.duration_seconds).unwrap();
        let ws_name = if let Some(ws) = workspace_id {
            self.workspace_repository.get_by_id(ws).await.map(|w| w.name).unwrap_or_else(|_| "Workspace".into())
        } else {
            self.workspace_repository.list_active_workspaces().await.ok().and_then(|v| v.first().map(|w| w.name.clone())).unwrap_or_else(|| "Workspace".into())
        };
        let duration_m = best.duration_seconds / 60;
        let hours = duration_m / 60;
        let mins = duration_m % 60;
        let duration_str = if hours > 0 { format!("{hours}h {mins}m") } else { format!("{mins}m") };
        let title = format!("You worked primarily on {} for {}.", ws_name, duration_str);
        let summary = format!("You had {} focus sessions with {} files touched, {} events recorded.", sessions.len(), best.file_count, best.event_count);
        // Apps: derive from activity or languages
        let apps: Vec<(String, String)> = if best.languages.is_empty() {
            vec![("Files".into(), format!("{} files", best.file_count))]
        } else {
            best.languages.iter().take(3).map(|l| (l.clone(), "".into())).collect()
        };
        let has_commit = best.events.iter().any(|e| e.event_type == crate::models::TimelineEventType::Commit);
        let outcome = if has_commit {
            Some("Changes were committed.".into())
        } else {
            None // honest: not enough evidence
        };
        let has_sufficient = has_commit || best.file_count >= 3;

        let date_label = best.started_at.format("%Y-%m-%d").to_string();

        Ok(Some(WhatHappenedDto {
            id: best.started_at.to_rfc3339(),
            date_label: format!("{} · {}", date_label, ws_name),
            workspace: ws_name,
            title,
            summary,
            detail: None,
            apps,
            files: best.file_count as i64,
            sessions: sessions.len() as i64,
            web_pages: 0,
            outcome,
            has_sufficient_evidence: has_sufficient,
        }))
    }

    async fn build_recent_memory(
        &self,
        workspace_id: Option<Uuid>,
    ) -> Result<Vec<RecentMemoryDto>, DatabaseError> {
        // Use last 4 sessions as memory items
        let since = Utc::now() - chrono::Duration::days(14);
        let until = Utc::now();
        let raw = self.fetch_timeline_window(workspace_id, since, until).await?;
        let mut sessions = detect_sessions(raw, DEFAULT_INACTIVITY_THRESHOLD_SECONDS);
        sessions.sort_by_key(|s| std::cmp::Reverse(s.started_at));
        let mut out = Vec::new();
        for (idx, sess) in sessions.into_iter().take(4).enumerate() {
            let date_label = match idx {
                0 => "Today",
                1 => "Yesterday",
                2 => "2 days ago",
                _ => "5 days ago",
            }.to_string();
            let duration_m = sess.duration_seconds / 60;
            let title = format!("Workspace session {}", sess.started_at.format("%m-%d"));
            let subtitle = format!("{}m · {} files · {} events", duration_m, sess.file_count, sess.event_count);
            out.push(RecentMemoryDto { id: sess.started_at.to_rfc3339(), date_label, title, subtitle });
        }
        Ok(out)
    }
}
