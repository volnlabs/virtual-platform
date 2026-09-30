use std::path::{Path, PathBuf};
use std::process::Command;

use crate::discovery::{discover_backends, discover_boards};
use crate::errors::{Error, Result};
use crate::manifest::Verb;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LaunchSpec {
    pub backend_name: String,
    pub board_name: String,
    pub verb: Verb,
    pub verb_path: PathBuf,
}

pub fn resolve_target(
    repo_root: &Path,
    board_name: &str,
    backend_override: Option<&str>,
) -> Result<LaunchSpec> {
    resolve_target_for(repo_root, board_name, backend_override, Verb::Run)
}

pub fn resolve_target_for(
    repo_root: &Path,
    board_name: &str,
    backend_override: Option<&str>,
    verb: Verb,
) -> Result<LaunchSpec> {
    let board = discover_boards(repo_root)?
        .into_iter()
        .find(|board| board.name == board_name)
        .ok_or_else(|| Error::BoardNotFound(board_name.into()))?;

    let backend_name = backend_override.unwrap_or(&board.default_backend);
    if !board.supports_backend(backend_name) {
        return Err(Error::BackendUnsupportedForBoard {
            board: board.name,
            backend: backend_name.into(),
        });
    }

    let backend = discover_backends(repo_root)?
        .into_iter()
        .find(|backend| backend.name == backend_name)
        .ok_or_else(|| Error::BackendNotFound(backend_name.into()))?;

    if !backend.boards.iter().any(|name| name == board_name) {
        return Err(Error::BackendUnsupportedForBoard {
            board: board.name,
            backend: backend.name,
        });
    }
    if !backend.supports(verb) {
        return Err(Error::VerbUnsupported {
            backend: backend.name,
            verb: verb.as_str().into(),
        });
    }

    let verb_path = repo_root
        .join("backends")
        .join(&backend.name)
        .join("adapters")
        .join(format!("{}.sh", verb.as_str()));
    if !verb_path.is_file() {
        return Err(Error::VerbUnsupported {
            backend: backend.name,
            verb: verb.as_str().into(),
        });
    }

    Ok(LaunchSpec {
        backend_name: backend.name,
        board_name: board.name,
        verb,
        verb_path,
    })
}

pub fn execute(
    spec: &LaunchSpec,
    args: &[String],
    dry_run: bool,
    artifact_manifest: Option<&Path>,
) -> Result<()> {
    let inherited = std::env::var_os("VOLN_VP_ARTIFACT_MANIFEST").map(PathBuf::from);
    if let (Some(selected), Some(environment)) = (artifact_manifest, inherited.as_deref()) {
        if selected != environment {
            return Err(Error::InvalidArguments(
                "--artifact-manifest conflicts with VOLN_VP_ARTIFACT_MANIFEST".into(),
            ));
        }
    }
    let manifest = artifact_manifest.or(inherited.as_deref());
    if dry_run {
        println!("backend: {}", spec.backend_name);
        println!("board:   {}", spec.board_name);
        println!("adapter: {}", spec.verb_path.display());
        println!("args:    {args:?}");
        if let Some(path) = manifest {
            println!("artifact manifest: {} (not validated)", path.display());
        }
        println!("dry run: adapter not executed");
        return Ok(());
    }

    let mut command = Command::new(&spec.verb_path);
    command
        .args(args)
        .env("VOLN_VP_BOARD", &spec.board_name)
        .env("VOLN_VP_VERB", spec.verb.as_str());
    if let Some(path) = manifest {
        command.env("VOLN_VP_ARTIFACT_MANIFEST", path);
    }
    let status = command.status()?;
    if status.success() {
        return Ok(());
    }

    Err(Error::SimulatorFailed {
        backend: spec.backend_name.clone(),
        code: status.code().unwrap_or(1),
    })
}
