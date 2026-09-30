use std::fs;
use std::path::Path;

use assert_cmd::Command;
use tempfile::TempDir;
use voln_vp::backend::{resolve_target, resolve_target_for};
use voln_vp::manifest::Verb;

fn make_repo() -> TempDir {
    let temporary = TempDir::new().unwrap();
    let root = temporary.path();

    fs::create_dir_all(root.join("backends/qemu/adapters")).unwrap();
    fs::write(
        root.join("backends/qemu/manifest.toml"),
        r#"
name = "qemu"
verbs = ["run", "test"]
boards = ["virt"]
"#,
    )
    .unwrap();
    write_executable(&root.join("backends/qemu/adapters/run.sh"), 7);
    write_executable(&root.join("backends/qemu/adapters/test.sh"), 0);

    fs::create_dir_all(root.join("boards/virt")).unwrap();
    fs::write(
        root.join("boards/virt/board.toml"),
        r#"
name = "virt"
memory = "1GB"
default_backend = "qemu"
backends = ["qemu"]
"#,
    )
    .unwrap();

    temporary
}

#[cfg(unix)]
fn write_executable(path: &Path, exit_code: i32) {
    use std::os::unix::fs::PermissionsExt;

    fs::write(path, format!("#!/bin/sh\nexit {exit_code}\n")).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

#[cfg(not(unix))]
fn write_executable(path: &Path, _exit_code: i32) {
    fs::write(path, "").unwrap();
}

#[test]
fn resolves_default_backend_for_board() {
    let temporary = make_repo();

    let spec = resolve_target(temporary.path(), "virt", None).unwrap();

    assert_eq!(spec.backend_name, "qemu");
    assert_eq!(spec.verb_path.file_name().unwrap(), "run.sh");
}

#[test]
fn explicit_backend_overrides_default() {
    let temporary = make_repo();

    let spec = resolve_target(temporary.path(), "virt", Some("qemu")).unwrap();

    assert_eq!(spec.backend_name, "qemu");
}

#[test]
fn test_verb_resolves_test_adapter() {
    let temporary = make_repo();

    let spec = resolve_target_for(temporary.path(), "virt", None, Verb::Test).unwrap();

    assert_eq!(spec.verb_path.file_name().unwrap(), "test.sh");
}

#[test]
fn unknown_board_errors_clearly() {
    let temporary = make_repo();

    let error = resolve_target(temporary.path(), "nope", None).unwrap_err();

    assert_eq!(error.to_string(), "board not found: nope");
}

#[test]
fn backend_unsupported_for_board_errors_clearly() {
    let temporary = make_repo();

    let error = resolve_target(temporary.path(), "virt", Some("renode")).unwrap_err();
    let message = error.to_string();

    assert!(
        message.contains("does not declare support"),
        "got: {message}"
    );
    assert!(message.contains("virt"), "got: {message}");
    assert!(message.contains("renode"), "got: {message}");
}

#[cfg(unix)]
#[test]
fn cli_propagates_adapter_exit_code() {
    let temporary = make_repo();

    Command::cargo_bin("voln-vp")
        .unwrap()
        .env("VOLN_VP_ROOT", temporary.path())
        .args(["run", "--board", "virt"])
        .assert()
        .code(7);
}

#[cfg(unix)]
#[test]
fn dry_run_resolves_without_launching_adapter() {
    let temporary = make_repo();

    Command::cargo_bin("voln-vp")
        .unwrap()
        .env("VOLN_VP_ROOT", temporary.path())
        .args(["run", "--board", "virt", "--dry-run"])
        .assert()
        .success()
        .stdout(predicates::str::contains("backend: qemu"))
        .stdout(predicates::str::contains("board:   virt"))
        .stdout(predicates::str::contains("run.sh"));
}

#[cfg(unix)]
#[test]
fn manifest_and_context_are_forwarded_without_parsing_artifacts() {
    let temporary = make_repo();
    let adapter = temporary.path().join("backends/qemu/adapters/test.sh");
    fs::write(&adapter, "#!/bin/sh\nprintf '%s\\n' \"$VOLN_VP_ARTIFACT_MANIFEST\" \"$VOLN_VP_BOARD\" \"$VOLN_VP_VERB\"\n").unwrap();
    let manifest = temporary.path().join("bundle with spaces/build.json");
    Command::cargo_bin("voln-vp")
        .unwrap()
        .env("VOLN_VP_ROOT", temporary.path())
        .env_remove("VOLN_VP_ARTIFACT_MANIFEST")
        .args(["test", "--board", "virt", "--artifact-manifest"])
        .arg(&manifest)
        .assert()
        .success()
        .stdout(format!("{}\nvirt\ntest\n", manifest.display()));
}

#[cfg(unix)]
#[test]
fn conflicting_manifest_selection_fails_before_launch() {
    let temporary = make_repo();
    Command::cargo_bin("voln-vp")
        .unwrap()
        .env("VOLN_VP_ROOT", temporary.path())
        .env("VOLN_VP_ARTIFACT_MANIFEST", "environment.json")
        .args(["test", "--board", "virt", "--artifact-manifest", "cli.json"])
        .assert()
        .failure()
        .stderr(predicates::str::contains(
            "conflicts with VOLN_VP_ARTIFACT_MANIFEST",
        ));
}

#[cfg(unix)]
#[test]
fn runtime_mode_and_scenario_are_forwarded_and_validated() {
    let temporary = make_repo();
    let adapter = temporary.path().join("backends/qemu/adapters/test.sh");
    fs::write(
        &adapter,
        "#!/bin/sh\nprintf '%s\\n' \"$VOLN_VP_TEST_MODE\" \"$VOLN_VP_SCENARIO\"\n",
    )
    .unwrap();
    Command::cargo_bin("voln-vp")
        .unwrap()
        .env("VOLN_VP_ROOT", temporary.path())
        .env_remove("VOLN_VP_TEST_MODE")
        .env_remove("VOLN_VP_SCENARIO")
        .args([
            "test",
            "--board",
            "virt",
            "--mode",
            "runtime",
            "--scenario",
            "suite with spaces.robot",
        ])
        .assert()
        .success()
        .stdout("runtime\nsuite with spaces.robot\n");
    for args in [
        vec!["test", "--board", "virt", "--mode", "runtime"],
        vec!["test", "--board", "virt", "--scenario", "suite.robot"],
        vec![
            "run",
            "--board",
            "virt",
            "--mode",
            "runtime",
            "--scenario",
            "suite.robot",
        ],
    ] {
        Command::cargo_bin("voln-vp")
            .unwrap()
            .env("VOLN_VP_ROOT", temporary.path())
            .env_remove("VOLN_VP_TEST_MODE")
            .env_remove("VOLN_VP_SCENARIO")
            .args(args)
            .assert()
            .failure();
    }
    Command::cargo_bin("voln-vp")
        .unwrap()
        .env("VOLN_VP_ROOT", temporary.path())
        .env("VOLN_VP_TEST_MODE", "boot")
        .args([
            "test",
            "--board",
            "virt",
            "--mode",
            "runtime",
            "--scenario",
            "suite.robot",
        ])
        .assert()
        .failure()
        .stderr(predicates::str::contains("conflicts"));
    Command::cargo_bin("voln-vp")
        .unwrap()
        .env("VOLN_VP_ROOT", temporary.path())
        .env_remove("VOLN_VP_TEST_MODE")
        .env_remove("VOLN_VP_SCENARIO")
        .args([
            "test",
            "--board",
            "virt",
            "--mode",
            "runtime",
            "--scenario",
            "missing.robot",
            "--dry-run",
        ])
        .assert()
        .success()
        .stdout(predicates::str::contains(
            "scenario: missing.robot (not validated)",
        ));
}

#[cfg(unix)]
#[test]
fn dry_run_shows_manifest_without_running_or_validating_it() {
    let temporary = make_repo();
    Command::cargo_bin("voln-vp")
        .unwrap()
        .env("VOLN_VP_ROOT", temporary.path())
        .env_remove("VOLN_VP_ARTIFACT_MANIFEST")
        .args([
            "run",
            "--board",
            "virt",
            "--dry-run",
            "--artifact-manifest",
            "missing.json",
        ])
        .assert()
        .success()
        .stdout(predicates::str::contains("missing.json"))
        .stdout(predicates::str::contains("not validated"));
}
