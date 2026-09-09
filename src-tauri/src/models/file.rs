use std::fmt;
use std::str::FromStr;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sqlx::FromRow;
use uuid::Uuid;

use crate::errors::DatabaseError;

/// The kind of artifact a [`FileArtifact`] represents (blueprint §2.1,
/// §7.2). Mirrors the `CHECK` constraint on `files.artifact_type` in
/// `migrations/0001_initial_schema.sql`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ArtifactType {
    File,
    Tab,
    Note,
    Commit,
    Screenshot,
    TerminalSession,
}

impl ArtifactType {
    pub fn as_str(&self) -> &'static str {
        match self {
            ArtifactType::File => "file",
            ArtifactType::Tab => "tab",
            ArtifactType::Note => "note",
            ArtifactType::Commit => "commit",
            ArtifactType::Screenshot => "screenshot",
            ArtifactType::TerminalSession => "terminal_session",
        }
    }
}

impl fmt::Display for ArtifactType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for ArtifactType {
    type Err = DatabaseError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "file" => Ok(ArtifactType::File),
            "tab" => Ok(ArtifactType::Tab),
            "note" => Ok(ArtifactType::Note),
            "commit" => Ok(ArtifactType::Commit),
            "screenshot" => Ok(ArtifactType::Screenshot),
            "terminal_session" => Ok(ArtifactType::TerminalSession),
            other => Err(DatabaseError::InvalidInput(format!(
                "unknown artifact type '{other}'"
            ))),
        }
    }
}

/// An artifact belonging to a workspace: a file, browser tab, note, git
/// commit, screenshot, or terminal session (blueprint §2.1).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileArtifact {
    pub id: Uuid,
    pub workspace_id: Uuid,
    pub artifact_type: ArtifactType,
    pub path_or_url: String,
    /// Content hash used for duplicate/near-duplicate detection
    /// (blueprint §6, "Duplicate & near-duplicate detection"). `None`
    /// until the (Phase 5) ML layer computes it.
    pub content_hash: Option<String>,
    /// Stable filesystem identifier (device:inode on Unix, fileResourceIdentifier on macOS)
    /// used to correlate renames/moves as an UPDATE rather than DELETE+INSERT.
    /// `None` for non-file artifacts (tab, note) or for rows created before Phase F.
    pub file_identifier: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// Raw shape of a `files` row; see [`crate::models::workspace::WorkspaceRow`]
/// for why enum columns are decoded as `String` first.
#[derive(Debug, FromRow)]
pub(crate) struct FileRow {
    pub id: Uuid,
    pub workspace_id: Uuid,
    pub artifact_type: String,
    pub path_or_url: String,
    pub content_hash: Option<String>,
    pub file_identifier: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl TryFrom<FileRow> for FileArtifact {
    type Error = DatabaseError;

    fn try_from(row: FileRow) -> Result<Self, Self::Error> {
        Ok(FileArtifact {
            id: row.id,
            workspace_id: row.workspace_id,
            artifact_type: ArtifactType::from_str(&row.artifact_type)?,
            path_or_url: row.path_or_url,
            content_hash: row.content_hash,
            file_identifier: row.file_identifier,
            created_at: row.created_at,
            updated_at: row.updated_at,
        })
    }
}

/// Input for [`FileRepository::create`](crate::repositories::file_repository::FileRepository::create).
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NewFile {
    pub workspace_id: Uuid,
    pub artifact_type: ArtifactType,
    pub path_or_url: String,
    #[serde(default)]
    pub content_hash: Option<String>,
    #[serde(default)]
    pub file_identifier: Option<String>,
}
