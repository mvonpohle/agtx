//! Orchestrator MCP registration for file-based agents.
//!
//! The task path writes each agent's project-scoped MCP config into its
//! worktree (`tui::app::write_mcp_config`). The orchestrator runs in the
//! **project root**, with no worktree, so this module registers the same
//! entry there — merging into whatever config file is already present,
//! because a root file is the user's, not a throwaway worktree's — and hands
//! back the shell fragment that puts the file back the way it was once the
//! orchestrator exits.
//!
//! Claude is not covered: it registers via `claude mcp add-json` inside its
//! own command string (`operations.rs`), which also carries its cleanup.

use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};

use super::McpConfigKind;

/// The shape in which a file-based agent's config file carries the `agtx`
/// entry. The variants mirror the per-agent shapes in
/// `tui::app::write_mcp_config`, so the root entry and the worktree entry
/// for the same project are identical.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum OrchestratorMcpFormat {
    /// `mcpServers: { agtx: { command, args } }`
    JsonMcpServers,
    /// `mcpServers: { agtx: { command, args, trust: true } }`
    JsonMcpServersTrust,
    /// `mcp: { agtx: { type: "local", command: [command, "mcp-serve", project] } }`
    JsonMcpLocal,
    /// `[mcp_servers.agtx]` TOML table
    TomlMcpServers,
}

/// Where a file-based agent's orchestrator config lives, relative to the
/// launch directory (the project root).
///
/// `ClaudeJson` → `None`: it registers via CLI inside its command string.
pub(crate) fn orchestrator_mcp_target(
    kind: McpConfigKind,
) -> Option<(&'static str, OrchestratorMcpFormat)> {
    match kind {
        McpConfigKind::ClaudeJson => None,
        McpConfigKind::OpenCode => Some(("opencode.json", OrchestratorMcpFormat::JsonMcpLocal)),
        McpConfigKind::CodexToml => {
            Some((".codex/config.toml", OrchestratorMcpFormat::TomlMcpServers))
        }
        McpConfigKind::GeminiJson => {
            Some((".gemini/settings.json", OrchestratorMcpFormat::JsonMcpServersTrust))
        }
        McpConfigKind::CursorJson => {
            Some((".cursor/mcp.json", OrchestratorMcpFormat::JsonMcpServers))
        }
        McpConfigKind::GrokTomlMerge => {
            Some((".grok/config.toml", OrchestratorMcpFormat::TomlMcpServers))
        }
        McpConfigKind::AntigravityJsonMerge => {
            Some((".agents/mcp_config.json", OrchestratorMcpFormat::JsonMcpServers))
        }
        McpConfigKind::PiJsonMerge => Some((".pi/mcp.json", OrchestratorMcpFormat::JsonMcpServers)),
    }
}

/// Merge the agtx MCP server entry into the agent config file inside `dir`
/// (the orchestrator's launch directory — the project root) and return the
/// shell fragment that restores the file to its pre-launch state after the
/// orchestrator exits.
///
/// `None` → nothing was registered (a pre-existing TOML table we must not
/// touch, or a write failure) → the caller launches bare.
///
/// Never overwrites user content: JSON files are parsed and the `agtx` entry
/// is inserted (sibling keys and servers survive); a pre-existing file is
/// backed up first so the cleanup fragment can restore it byte-for-byte.
pub(crate) fn register(
    dir: &Path,
    rel_path: &str,
    format: OrchestratorMcpFormat,
    agtx_bin: &str,
    project_path: &str,
) -> Option<String> {
    let file = dir.join(rel_path);
    let pre_existed = file.exists();
    let backup_path = pre_existed.then(|| backup(&file)).flatten();

    let content = match format {
        OrchestratorMcpFormat::JsonMcpServers
        | OrchestratorMcpFormat::JsonMcpServersTrust
        | OrchestratorMcpFormat::JsonMcpLocal => {
            let (key, entry) = match format {
                OrchestratorMcpFormat::JsonMcpLocal => (
                    "mcp",
                    json!({
                        "type": "local",
                        "command": [agtx_bin, "mcp-serve", project_path]
                    }),
                ),
                OrchestratorMcpFormat::JsonMcpServersTrust => (
                    "mcpServers",
                    json!({
                        "command": agtx_bin,
                        "args": ["mcp-serve", project_path],
                        "trust": true
                    }),
                ),
                _ => (
                    "mcpServers",
                    json!({
                        "command": agtx_bin,
                        "args": ["mcp-serve", project_path]
                    }),
                ),
            };
            let mut root = read_json_object(&file);
            let mut servers = root
                .get(key)
                .and_then(|v| v.as_object().cloned())
                .unwrap_or_default();
            servers.insert("agtx".to_string(), entry);
            root.insert(key.to_string(), Value::Object(servers));
            serde_json::to_string_pretty(&Value::Object(root)).unwrap_or_default()
        }
        OrchestratorMcpFormat::TomlMcpServers => {
            let existing = if pre_existed {
                std::fs::read_to_string(&file).unwrap_or_default()
            } else {
                String::new()
            };
            if existing.contains("[mcp_servers.agtx]") {
                // Already registered; the entry is deterministic per project,
                // so leave the user's file alone — and there is nothing to
                // clean up.
                return None;
            }
            // Escape for the double-quoted TOML string (same rule as the Grok
            // task-path arm in `write_mcp_config`).
            let esc = |v: &str| v.replace('\\', "\\\\").replace('"', "\\\"");
            let table = format!(
                "[mcp_servers.agtx]\ncommand = \"{}\"\nargs = [\"mcp-serve\", \"{}\"]\n",
                esc(agtx_bin),
                esc(project_path)
            );
            if existing.trim().is_empty() {
                table
            } else {
                format!("{}\n\n{}", existing.trim_end(), table)
            }
        }
    };

    if let Some(parent) = file.parent() {
        if std::fs::create_dir_all(parent).is_err() {
            tracing::warn!("orchestrator MCP: cannot create {}", parent.display());
            return None;
        }
    }
    if std::fs::write(&file, &content).is_err() {
        tracing::warn!("orchestrator MCP: cannot write {}", file.display());
        return None;
    }

    Some(cleanup_fragment(&file, backup_path.as_deref()))
}

/// Copy `file` to a unique name under the system temp dir; the cleanup
/// fragment restores from it after the orchestrator exits.
fn backup(file: &Path) -> Option<PathBuf> {
    let dest = std::env::temp_dir().join(format!("agtx-orch-mcp-{}", uuid::Uuid::new_v4()));
    std::fs::copy(file, &dest).ok()?;
    Some(dest)
}

/// The shell fragment that runs after the orchestrator exits: restore the
/// user's pre-launch file, or remove the one we created.
fn cleanup_fragment(file: &Path, backup_path: Option<&Path>) -> String {
    match backup_path {
        Some(bak) => format!(
            "cp -f {} {} && rm -f {}",
            quote(bak),
            quote(file),
            quote(bak)
        ),
        None => format!("rm -f {}", quote(file)),
    }
}

/// Wrap as one POSIX single-quoted shell word, escaping inner quotes by
/// close-literal-reopen. This fragment lives inside the orchestrator command
/// string, which `create_window` wraps in `sh -c '…'` — so, like the claude
/// JSON, the wrapping quotes must **not** be pre-escaped here.
fn quote(word: &Path) -> String {
    format!(
        "'{}'",
        word.display().to_string().replace('\'', "'\"'\"'")
    )
}

/// Parse a JSON file as an object; missing or non-object content is `{}`
/// (same tolerance as the task-path writers).
fn read_json_object(path: &Path) -> Map<String, Value> {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
        .and_then(|v| v.as_object().cloned())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_file_based_kind_maps_to_a_target() {
        assert!(
            orchestrator_mcp_target(McpConfigKind::ClaudeJson).is_none(),
            "Claude registers via CLI, not a config file"
        );
        for kind in [
            McpConfigKind::OpenCode,
            McpConfigKind::CodexToml,
            McpConfigKind::GeminiJson,
            McpConfigKind::CursorJson,
            McpConfigKind::GrokTomlMerge,
            McpConfigKind::AntigravityJsonMerge,
            McpConfigKind::PiJsonMerge,
        ] {
            let (rel, _format) =
                orchestrator_mcp_target(kind).expect("file-based kind must have a target");
            assert!(
                !rel.contains("..") && !rel.starts_with('/'),
                "{kind:?} target must stay inside the launch dir: {rel}"
            );
        }
    }

    #[test]
    fn gemini_entry_carries_trust() {
        let dir = tempfile::tempdir().unwrap();
        let cleanup = register(
            dir.path(),
            ".gemini/settings.json",
            OrchestratorMcpFormat::JsonMcpServersTrust,
            "/usr/bin/agtx",
            "/tmp/proj",
        )
        .unwrap();
        let cfg: Value = serde_json::from_str(
            &std::fs::read_to_string(dir.path().join(".gemini/settings.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(cfg["mcpServers"]["agtx"]["trust"], true);
        assert_eq!(cfg["mcpServers"]["agtx"]["command"], "/usr/bin/agtx");
        assert_eq!(cfg["mcpServers"]["agtx"]["args"][1], "/tmp/proj");
        // Fresh file → cleanup removes it.
        assert!(cleanup.starts_with("rm -f '"), "{cleanup}");
    }

    #[test]
    fn pre_existing_json_survives_and_cleanup_restores_backup() {
        let dir = tempfile::tempdir().unwrap();
        let cfg_path = dir.path().join("opencode.json");
        std::fs::write(
            &cfg_path,
            serde_json::json!({ "theme": "dark", "mcp": { "other": { "type": "local" } } })
                .to_string(),
        )
        .unwrap();
        let before = std::fs::read_to_string(&cfg_path).unwrap();

        let cleanup = register(
            dir.path(),
            "opencode.json",
            OrchestratorMcpFormat::JsonMcpLocal,
            "/usr/bin/agtx",
            "/tmp/proj",
        )
        .unwrap();

        let merged: Value =
            serde_json::from_str(&std::fs::read_to_string(&cfg_path).unwrap()).unwrap();
        assert_eq!(merged["theme"], "dark", "user keys must survive");
        assert_eq!(
            merged["mcp"]["other"]["type"], "local",
            "other servers must survive"
        );
        assert_eq!(merged["mcp"]["agtx"]["type"], "local");
        assert_eq!(merged["mcp"]["agtx"]["command"][2], "/tmp/proj");

        // Pre-existing file → cleanup restores the backup, then removes it.
        assert!(
            cleanup.contains("cp -f '") && cleanup.contains(" && rm -f '"),
            "{cleanup}"
        );
        assert!(before.contains("dark"), "sanity");
    }

    #[test]
    fn toml_table_appended_after_user_content() {
        let dir = tempfile::tempdir().unwrap();
        let cfg_path = dir.path().join(".codex").join("config.toml");
        std::fs::create_dir_all(cfg_path.parent().unwrap()).unwrap();
        std::fs::write(&cfg_path, "[sandbox]\nmode = \"workspace-write\"\n").unwrap();

        let cleanup = register(
            dir.path(),
            ".codex/config.toml",
            OrchestratorMcpFormat::TomlMcpServers,
            "/usr/bin/agtx",
            "/tmp/proj",
        )
        .unwrap();

        let content = std::fs::read_to_string(&cfg_path).unwrap();
        assert!(content.contains("[sandbox]"), "user table must survive");
        assert!(content.contains("[mcp_servers.agtx]"), "{content}");
        assert!(content.contains(r#"command = "/usr/bin/agtx""#), "{content}");
        assert!(content.contains(r#"args = ["mcp-serve", "/tmp/proj"]"#), "{content}");
        assert!(cleanup.starts_with("cp -f '"), "pre-existing file → restore: {cleanup}");
    }

    #[test]
    fn toml_already_registered_leaves_file_alone() {
        let dir = tempfile::tempdir().unwrap();
        let cfg_path = dir.path().join(".grok").join("config.toml");
        std::fs::create_dir_all(cfg_path.parent().unwrap()).unwrap();
        std::fs::write(&cfg_path, "[mcp_servers.agtx]\ncommand = \"other\"\n").unwrap();
        let before = std::fs::read_to_string(&cfg_path).unwrap();

        let result = register(
            dir.path(),
            ".grok/config.toml",
            OrchestratorMcpFormat::TomlMcpServers,
            "/usr/bin/agtx",
            "/tmp/proj",
        );

        assert!(result.is_none(), "already registered → nothing to do");
        assert_eq!(
            std::fs::read_to_string(&cfg_path).unwrap(),
            before,
            "file must be untouched"
        );
    }

    #[test]
    fn apostrophe_in_project_path_lands_intact_in_file_and_cleanup() {
        let dir = tempfile::tempdir().unwrap();
        let project = "/tmp/it's a repo";
        let cleanup = register(
            dir.path(),
            "opencode.json",
            OrchestratorMcpFormat::JsonMcpLocal,
            "/usr/bin/agtx",
            project,
        )
        .unwrap();
        let cfg: Value =
            serde_json::from_str(&std::fs::read_to_string(dir.path().join("opencode.json"))
                .unwrap())
            .unwrap();
        assert_eq!(
            cfg["mcp"]["agtx"]["command"][2], project,
            "the project path must be intact in the written file"
        );
        assert!(cleanup.starts_with("rm -f '"), "{cleanup}");
    }
}
