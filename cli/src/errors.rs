use std::path::PathBuf;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum Error {
    #[error("invalid arguments: {0}")]
    InvalidArguments(String),

    #[error("backend not found: {0}")]
    BackendNotFound(String),

    #[error("board not found: {0}")]
    BoardNotFound(String),

    #[error("board `{board}` does not declare support for backend `{backend}`")]
    BackendUnsupportedForBoard { board: String, backend: String },

    #[error("manifest invalid in {path}: {reason}", path = path.display())]
    ManifestInvalid { path: PathBuf, reason: String },

    #[error("verb `{verb}` is not supported by backend `{backend}`")]
    VerbUnsupported { backend: String, verb: String },

    #[error("simulator exited with code {code} for backend `{backend}`")]
    SimulatorFailed { backend: String, code: i32 },

    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    #[error("TOML parse error: {0}")]
    Toml(#[from] toml::de::Error),
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    pub fn exit_code(&self) -> i32 {
        match self {
            Self::SimulatorFailed { code, .. } if *code > 0 => *code,
            _ => 1,
        }
    }
}
