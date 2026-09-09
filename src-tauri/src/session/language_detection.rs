//! Language detection from file artifacts.
//!
//! Infers programming languages from file extensions and artifact types.
//! Multi-source approach: checks extension mappings and could be extended
//! to parse workspace metadata (package.json, Cargo.toml, etc.).

use crate::models::FileArtifact;
use std::collections::HashSet;
use std::path::Path;

/// Detects programming languages from a list of file artifacts.
///
/// Uses file extensions as the primary signal. Returns a deduplicated
/// list of language names sorted alphabetically.
pub fn detect_languages(files: &[FileArtifact]) -> Vec<String> {
    let mut languages = HashSet::new();

    for file in files {
        if let Some(lang) = detect_language_from_path(&file.path_or_url) {
            languages.insert(lang);
        }
    }

    let mut result: Vec<String> = languages.into_iter().collect();
    result.sort();
    result
}

/// Detects a single language from a file path based on extension.
fn detect_language_from_path(path: &str) -> Option<String> {
    let extension = Path::new(path).extension()?.to_str()?.to_lowercase();

    map_extension_to_language(&extension)
}

/// Maps file extensions to language names.
///
/// This mapping can be extended over time. Returns None for unknown
/// extensions rather than falling back to a generic "Unknown" language.
fn map_extension_to_language(ext: &str) -> Option<String> {
    let lang = match ext {
        // Rust
        "rs" => "Rust",

        // JavaScript/TypeScript
        "js" | "mjs" | "cjs" => "JavaScript",
        "ts" | "mts" | "cts" => "TypeScript",
        "jsx" => "JavaScript",
        "tsx" => "TypeScript",

        // Python
        "py" | "pyw" | "pyi" => "Python",

        // Web
        "html" | "htm" => "HTML",
        "css" | "scss" | "sass" | "less" => "CSS",
        "vue" => "Vue",
        "svelte" => "Svelte",

        // C/C++
        "c" | "h" => "C",
        "cpp" | "cc" | "cxx" | "hpp" | "hxx" => "C++",

        // Java/Kotlin
        "java" => "Java",
        "kt" | "kts" => "Kotlin",

        // Go
        "go" => "Go",

        // Ruby
        "rb" | "erb" => "Ruby",

        // PHP
        "php" => "PHP",

        // Shell
        "sh" | "bash" | "zsh" => "Shell",

        // Config/Data
        "json" => "JSON",
        "yaml" | "yml" => "YAML",
        "toml" => "TOML",
        "xml" => "XML",
        "sql" => "SQL",

        // Markdown
        "md" | "markdown" => "Markdown",

        // Swift
        "swift" => "Swift",

        // Dart
        "dart" => "Dart",

        _ => return None,
    };

    Some(lang.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{ArtifactType, FileArtifact};
    use chrono::Utc;
    use uuid::Uuid;

    fn make_file(path: &str) -> FileArtifact {
        FileArtifact {
            id: Uuid::new_v4(),
            workspace_id: Uuid::new_v4(),
            artifact_type: ArtifactType::File,
            path_or_url: path.to_string(),
            content_hash: None,
            file_identifier: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        }
    }

    #[test]
    fn detects_rust_from_extension() {
        let files = vec![make_file("/src/main.rs"), make_file("/src/lib.rs")];
        let languages = detect_languages(&files);
        assert_eq!(languages, vec!["Rust"]);
    }

    #[test]
    fn detects_multiple_languages() {
        let files = vec![
            make_file("/src/main.rs"),
            make_file("/src/app.tsx"),
            make_file("/styles.css"),
        ];
        let languages = detect_languages(&files);
        assert_eq!(languages, vec!["CSS", "Rust", "TypeScript"]);
    }

    #[test]
    fn ignores_unknown_extensions() {
        let files = vec![
            make_file("/README.txt"),
            make_file("/data.dat"),
            make_file("/src/main.rs"),
        ];
        let languages = detect_languages(&files);
        assert_eq!(languages, vec!["Rust"]);
    }

    #[test]
    fn handles_mixed_case_extensions() {
        let files = vec![make_file("/src/Main.RS"), make_file("/src/App.TSX")];
        let languages = detect_languages(&files);
        assert_eq!(languages, vec!["Rust", "TypeScript"]);
    }

    #[test]
    fn deduplicates_languages() {
        let files = vec![
            make_file("/src/main.rs"),
            make_file("/src/lib.rs"),
            make_file("/src/utils.rs"),
        ];
        let languages = detect_languages(&files);
        assert_eq!(languages, vec!["Rust"]);
    }

    #[test]
    fn empty_files_returns_empty_languages() {
        let languages = detect_languages(&[]);
        assert!(languages.is_empty());
    }
}
