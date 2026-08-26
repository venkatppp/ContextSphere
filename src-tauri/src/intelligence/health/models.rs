//! Health models and metric definitions.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// A workspace health score with component metrics.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceHealth {
    /// Workspace ID this health assessment belongs to.
    #[serde(rename = "workspaceId", alias = "workspace_id")]
    pub workspace_id: String,

    /// Overall health score (0.0 - 1.0, where 1.0 is healthiest).
    #[serde(rename = "overallScore", alias = "overall_score")]
    pub overall_score: f64,

    /// Individual health factors contributing to the overall score.
    pub factors: Vec<HealthFactor>,

    /// When this health assessment was calculated.
    #[serde(rename = "calculatedAt", alias = "calculated_at")]
    pub calculated_at: DateTime<Utc>,

    /// Trend compared to previous assessment (positive = improving).
    pub trend: Option<f64>,
}

/// A single health factor contributing to overall workspace health.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HealthFactor {
    /// Factor identifier (e.g., "activity_level", "organization").
    pub id: String,

    /// Human-readable name.
    pub name: String,

    /// Detailed description of what this factor measures.
    pub description: String,

    /// Current score for this factor (0.0 - 1.0).
    pub score: f64,

    /// Weight of this factor in overall health calculation (0.0 - 1.0).
    pub weight: f64,

    /// Supporting metrics that contributed to this factor's score.
    pub metrics: Vec<HealthMetric>,
}

/// A granular metric used to calculate a health factor.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HealthMetric {
    /// Metric identifier.
    pub id: String,

    /// Human-readable name.
    pub name: String,

    /// Current value.
    pub value: f64,

    /// Expected/ideal value for comparison.
    #[serde(rename = "idealValue", alias = "ideal_value")]
    pub ideal_value: Option<f64>,

    /// Unit of measurement (e.g., "days", "files", "percent").
    pub unit: String,
}

impl HealthFactor {
    /// Creates a new health factor.
    pub fn new(
        id: impl Into<String>,
        name: impl Into<String>,
        description: impl Into<String>,
    ) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            description: description.into(),
            score: 0.0,
            weight: 1.0,
            metrics: Vec::new(),
        }
    }

    /// Sets the score for this factor.
    pub fn with_score(mut self, score: f64) -> Self {
        self.score = score.clamp(0.0, 1.0);
        self
    }

    /// Sets the weight for this factor.
    pub fn with_weight(mut self, weight: f64) -> Self {
        self.weight = weight.clamp(0.0, 1.0);
        self
    }

    /// Adds a metric to this factor.
    pub fn with_metric(mut self, metric: HealthMetric) -> Self {
        self.metrics.push(metric);
        self
    }
}

impl HealthMetric {
    /// Creates a new health metric.
    pub fn new(
        id: impl Into<String>,
        name: impl Into<String>,
        value: f64,
        unit: impl Into<String>,
    ) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            value,
            ideal_value: None,
            unit: unit.into(),
        }
    }

    /// Sets the ideal value for comparison.
    pub fn with_ideal(mut self, ideal_value: f64) -> Self {
        self.ideal_value = Some(ideal_value);
        self
    }
}

impl WorkspaceHealth {
    /// Creates a new health assessment.
    pub fn new(workspace_id: String) -> Self {
        Self {
            workspace_id,
            overall_score: 0.0,
            factors: Vec::new(),
            calculated_at: Utc::now(),
            trend: None,
        }
    }

    /// Calculates overall score from weighted factors.
    pub fn calculate_overall_score(&mut self) {
        if self.factors.is_empty() {
            self.overall_score = 0.0;
            return;
        }

        let total_weight: f64 = self.factors.iter().map(|f| f.weight).sum();

        if total_weight == 0.0 {
            self.overall_score = 0.0;
            return;
        }

        let weighted_sum: f64 = self.factors.iter().map(|f| f.score * f.weight).sum();

        self.overall_score = (weighted_sum / total_weight).clamp(0.0, 1.0);
    }

    /// Adds a health factor.
    pub fn with_factor(mut self, factor: HealthFactor) -> Self {
        self.factors.push(factor);
        self
    }

    /// Sets the trend.
    pub fn with_trend(mut self, trend: f64) -> Self {
        self.trend = Some(trend);
        self
    }
}
