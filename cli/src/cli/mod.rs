use std::path::{Path, PathBuf};

use clap::{Args, Parser, Subcommand};

use crate::backend::{execute, resolve_target_for};
use crate::config::repo_root;
use crate::errors::Result;
use crate::manifest::Verb;

pub mod doctor;

#[derive(Debug, Parser)]
#[command(
    name = "voln-vp",
    version,
    about = "Virtual Platform for axiomOS Development"
)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Command,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    /// Verify required simulators and toolchains are installed
    Doctor,
    /// Run a board under a backend
    Run(RunArgs),
    /// Run test suites for a board under a backend
    Test(RunArgs),
}

#[derive(Args, Clone, Debug)]
pub struct RunArgs {
    #[arg(long)]
    pub board: String,

    #[arg(long)]
    pub backend: Option<String>,

    /// Consume a producer-generated prebuilt artifact manifest
    #[arg(long)]
    pub artifact_manifest: Option<PathBuf>,

    #[arg(long)]
    pub dry_run: bool,

    #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
    pub extra: Vec<String>,
}

pub fn run() {
    let cli = Cli::parse();
    let root = repo_root();
    let result = match cli.command {
        Command::Doctor => doctor::run(&root),
        Command::Run(args) => run_adapter(&root, &args, Verb::Run),
        Command::Test(args) => run_adapter(&root, &args, Verb::Test),
    };

    if let Err(error) = result {
        eprintln!("error: {error}");
        std::process::exit(error.exit_code());
    }
}

fn run_adapter(root: &Path, args: &RunArgs, verb: Verb) -> Result<()> {
    let spec = resolve_target_for(root, &args.board, args.backend.as_deref(), verb)?;
    execute(
        &spec,
        &args.extra,
        args.dry_run,
        args.artifact_manifest.as_deref(),
    )
}
