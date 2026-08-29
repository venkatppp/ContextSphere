//! Strongly typed domain models for the storage layer.
//!
//! Each module owns one aggregate (`Workspace`, `FileArtifact`,
//! `TimelineEvent`) plus its enums and the DTOs used to create/update it.
//! Models never derive `sqlx::FromRow` directly when they contain an
//! enum column — SQLite has no native enum type, so a private `*Row`
//! struct (matching the raw TEXT/REAL columns) is decoded first and then
//! fallibly converted into the public model via `TryFrom`. This keeps the
//! public API strongly typed without relying on hand-written
//! `sqlx::Decode`/`Encode` impls for the enums themselves.

pub mod backup;
pub mod duplicates;
pub mod file;
pub mod graph;
pub mod kg;
pub mod kg_context;
pub mod kg_live;
pub mod kg_opt;
pub mod ml;
pub mod activity;
pub mod performance;
pub mod recovery;
pub mod search;
pub mod security;
pub mod timeline;
pub mod workspace;

pub use duplicates::{DuplicateFile, DuplicateGroup, ScanProgress};
pub use file::{ArtifactType, FileArtifact, NewFile};
pub use graph::{GraphEdge, GraphEdgeType, GraphNode, GraphStats, GraphView, NodeDetails};
pub use ml::{Embedding, FileClassification, MLMetadata, NewEmbedding, NewMLMetadata};
pub use search::{ReindexFileBody, SavedSearch, SearchEntityType, SearchResult, SearchStats};
pub use activity::{
    ActivityAppUsageDto, ActivityDaySummary, ActivityDonutSegment, ActivityEvent,
    ActivityEventType, ActivityFileUsageDto, ActivityOverviewDto, ActivitySessionDto,
    ActivityTimelineEventDto, ActivityWebUsageDto, NewActivityEvent, RecentMemoryDto,
    WhatHappenedDto, WorkspaceCorrelationDto,
};
pub use timeline::{NewTimelineEvent, TimelineEvent, TimelineEventType};
pub use workspace::{
    CreateWorkspaceInput, UpdateWorkspaceInput, Workspace, WorkspaceStats, WorkspaceStatus,
};
