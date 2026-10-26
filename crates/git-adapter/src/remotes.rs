//! Provider-neutral, noninteractive remote operations. Network commands never use
//! imported refspecs, shell credential helpers, SSH commands, or raw diagnostics.
use anyhow::{Context, Result, bail, ensure};
use std::{
    collections::BTreeMap,
    fs,
    io::Write,
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    process::{Command, Output},
    time::Duration,
};
use workbench_domain::{RemoteBranch, RemoteInfo, RemoteState, digest};

#[derive(Clone, Copy)]
enum Policy {
    Network,
    #[cfg(test)]
    Fixture,
}

fn config(path: &Path) -> Result<Vec<(String, String)>> {
    config_scope(path, false)
}
fn config_scope(path: &Path, local_only: bool) -> Result<Vec<(String, String)>> {
    let args: &[&str] = if local_only {
        &["config", "--local", "--no-includes", "--null", "--list"]
    } else {
        &["config", "--null", "--list"]
    };
    let out = run_local(path, args, false)?;
    let mut values = Vec::new();
    for item in out.stdout.split(|b| *b == 0).filter(|b| !b.is_empty()) {
        let text = std::str::from_utf8(item).context("unsupported_remote_config")?;
        let (key, value) = text.split_once('\n').unwrap_or((text, ""));
        // Sections and variable names are case-insensitive; subsection names
        // (remote and branch names) are case-sensitive.
        let key = if let Some((section, rest)) = key.split_once('.') {
            if let Some((subsection, field)) = rest.rsplit_once('.') {
                format!(
                    "{}.{subsection}.{}",
                    section.to_ascii_lowercase(),
                    field.to_ascii_lowercase()
                )
            } else {
                key.to_ascii_lowercase()
            }
        } else {
            key.to_ascii_lowercase()
        };
        values.push((key, value.to_string()));
    }
    Ok(values)
}
fn run_local(path: &Path, args: &[&str], write: bool) -> Result<Output> {
    run_local_command(super::git_command(path, args), write)
}
fn run_local_command(command: Command, write: bool) -> Result<Output> {
    let out = super::process::run(
        command,
        None,
        Duration::from_secs(if write { 120 } else { 15 }),
        8 * 1024 * 1024,
    )
    .map_err(|_| {
        anyhow::anyhow!(if write {
            "remote_outcome_unknown"
        } else {
            "remote_read_failed"
        })
    })?;
    ensure!(
        out.status.success(),
        "{}",
        if write {
            "remote_outcome_unknown"
        } else {
            "remote_configuration_failed"
        }
    );
    Ok(out)
}

/// Edit a copy under Git's real config lock, then publish all related keys at
/// once. Git itself still parses and writes the file, preserving its format.
fn edit_local_config(path: &Path, edit: impl FnOnce(&Path) -> Result<()>) -> Result<()> {
    let config = super::common_dir(path)?.join("config");
    let lock_path = config.with_extension("lock");
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&lock_path)
        .context("remote_configuration_failed")?;
    struct Lock(Option<PathBuf>);
    impl Drop for Lock {
        fn drop(&mut self) {
            if let Some(path) = &self.0 {
                let _ = fs::remove_file(path);
            }
        }
    }
    let mut lock = Lock(Some(lock_path.clone()));
    let meta = fs::symlink_metadata(&config)?;
    ensure!(
        meta.is_file() && !meta.file_type().is_symlink(),
        "remote_configuration_failed"
    );
    let original = fs::read(&config)?;
    file.write_all(&original)?;
    file.set_permissions(meta.permissions())?;
    file.sync_all()?;
    drop(file);
    edit(&lock_path)?;
    // Respect even an editor which does not honor Git's lock convention.
    ensure!(fs::read(&config)? == original, "stale_remote_state");
    // A config writer may replace the staged inode; preserve the original
    // access mode on the final inode as well as on the initial copy.
    fs::set_permissions(&lock_path, meta.permissions())?;
    fs::File::open(&lock_path)?.sync_all()?;
    fs::rename(&lock_path, &config)?;
    lock.0 = None;
    Ok(())
}
fn config_value(path: &Path, file: &Path, key: &str, value: Option<&str>) -> Result<()> {
    let file = file.to_str().context("unsupported_remote_config")?;
    let args = if let Some(value) = value {
        vec!["config", "--file", file, "--replace-all", key, value]
    } else {
        vec!["config", "--file", file, "--unset-all", key]
    };
    let out = super::process::run(
        super::git_command(path, &args),
        None,
        Duration::from_secs(15),
        1024,
    )?;
    ensure!(
        out.status.success() || (value.is_none() && out.status.code() == Some(5)),
        "remote_configuration_failed"
    );
    Ok(())
}
fn scalar<'a>(cfg: &'a [(String, String)], key: &str) -> Option<&'a str> {
    cfg.iter()
        .rev()
        .find(|(k, _)| k == key)
        .map(|(_, v)| v.as_str())
}
fn values<'a>(cfg: &'a [(String, String)], key: &str) -> Vec<&'a str> {
    cfg.iter()
        .filter(|(k, _)| k == key)
        .map(|(_, v)| v.as_str())
        .collect()
}
fn transport_config(cfg: &[(String, String)]) -> Result<()> {
    for (key, value) in cfg {
        ensure!(
            key != "core.alternaterefscommand",
            "unsupported_alternate_command"
        );
        ensure!(
            !(key.starts_with("url.")
                && (key.ends_with(".insteadof") || key.ends_with(".pushinsteadof"))),
            "unsupported_url_rewrite"
        );
        ensure!(
            !(key == "extensions.partialclone"
                || (key.starts_with("remote.")
                    && (key.ends_with(".promisor") || key.ends_with(".partialclonefilter")))),
            "unsupported_partial_clone"
        );
        ensure!(
            !(key.starts_with("remote.")
                && (key.ends_with(".vcs")
                    || key.ends_with(".uploadpack")
                    || key.ends_with(".receivepack"))),
            "unsupported_remote_command"
        );
        // HTTP settings can redirect credentials or weaken transport. The first
        // version deliberately accepts only settings we replace with fixed values.
        if key.starts_with("http.") {
            ensure!(
                matches!(
                    key.as_str(),
                    "http.postbuffer" | "http.version" | "http.lowspeedlimit" | "http.lowspeedtime"
                ),
                "unsupported_http_configuration"
            );
        }
        ensure!(
            !(key == "core.repositoryformatversion" && value.parse::<u64>().unwrap_or(0) > 1),
            "unsupported_repository_format"
        );
    }
    Ok(())
}
fn remote_name(name: &str) -> Result<()> {
    ensure!(
        !name.is_empty()
            && name.len() <= 64
            && name.as_bytes()[0].is_ascii_alphanumeric()
            && name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.'))
            && !name.ends_with('.')
            && !name.contains(".."),
        "invalid_remote_name"
    );
    Ok(())
}
fn host(authority: &str, ssh: bool) -> Result<()> {
    let server = if let Some((user, rest)) = authority.rsplit_once('@') {
        ensure!(
            ssh && !user.is_empty()
                && user
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.')),
            "invalid_remote_url"
        );
        rest
    } else {
        authority
    };
    ensure!(
        !server.is_empty() && !server.starts_with('-'),
        "invalid_remote_url"
    );
    let (hostname, port) = if server.starts_with('[') {
        let end = server.find(']').context("invalid_remote_url")?;
        ensure!(
            end > 1
                && server[1..end]
                    .bytes()
                    .all(|b| b.is_ascii_hexdigit() || b == b':'),
            "invalid_remote_url"
        );
        let suffix = &server[end + 1..];
        ensure!(
            suffix.is_empty() || suffix.starts_with(':'),
            "invalid_remote_url"
        );
        (&server[..=end], suffix.strip_prefix(':'))
    } else {
        let (h, p) = server
            .split_once(':')
            .map_or((server, None), |(h, p)| (h, Some(p)));
        ensure!(
            h.bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.')),
            "invalid_remote_url"
        );
        (h, p)
    };
    ensure!(
        !hostname.is_empty() && hostname != "." && !hostname.ends_with(".."),
        "invalid_remote_url"
    );
    if let Some(port) = port {
        ensure!(
            !port.is_empty()
                && port.bytes().all(|b| b.is_ascii_digit())
                && port.parse::<u16>().unwrap_or(0) > 0,
            "invalid_remote_url"
        );
    }
    Ok(())
}
fn validate_url(url: &str, policy: Policy) -> Result<()> {
    ensure!(
        !url.is_empty()
            && url.len() <= 4096
            && !url.starts_with('-')
            && url
                .bytes()
                .all(|b| b.is_ascii_graphic() && !matches!(b, b'\\' | b'?' | b'#' | b'%')),
        "invalid_remote_url"
    );
    #[cfg(test)]
    if matches!(policy, Policy::Fixture) && url.starts_with("file:///") {
        return Ok(());
    }
    let _ = policy;
    if let Some(rest) = url.strip_prefix("https://") {
        let (authority, path) = rest.split_once('/').context("invalid_remote_url")?;
        host(authority, false)?;
        ensure!(!path.is_empty(), "invalid_remote_url");
    } else if let Some(rest) = url.strip_prefix("ssh://") {
        let (authority, path) = rest.split_once('/').context("invalid_remote_url")?;
        host(authority, true)?;
        ensure!(!path.is_empty(), "invalid_remote_url");
    } else {
        ensure!(
            !url.contains("://") && !url.starts_with('/') && !url.starts_with('.'),
            "unsupported_remote_transport"
        );
        let (authority, path) = url
            .split_once(':')
            .context("unsupported_remote_transport")?;
        host(authority, true)?;
        ensure!(
            !path.is_empty() && !path.starts_with(['-', ':']),
            "invalid_remote_url"
        );
    }
    Ok(())
}
/// Public validation does not probe a network endpoint or save credentials.
pub fn validate_remote_url(url: &str) -> Result<()> {
    validate_url(url, Policy::Network)
}
fn display_url(url: &str, policy: Policy) -> String {
    if validate_url(url, policy).is_ok() {
        url.to_string()
    } else {
        "[unsupported or credential-bearing URL]".to_string()
    }
}
fn endpoints(cfg: &[(String, String)], name: &str, policy: Policy) -> Result<(String, String)> {
    remote_name(name)?;
    transport_config(cfg)?;
    let fetch = values(cfg, &format!("remote.{name}.url"));
    let push = values(cfg, &format!("remote.{name}.pushurl"));
    ensure!(
        fetch.len() == 1 && push.len() <= 1,
        "unsupported_remote_endpoints"
    );
    validate_url(fetch[0], policy)?;
    let push = push.first().copied().unwrap_or(fetch[0]);
    validate_url(push, policy)?;
    Ok((fetch[0].into(), push.into()))
}
fn credential_helper() -> Option<&'static str> {
    ["/Applications/Xcode.app/Contents/Developer/usr/libexec/git-core/git-credential-osxkeychain", "/Library/Developer/CommandLineTools/usr/libexec/git-core/git-credential-osxkeychain"]
        .into_iter().find(|path| Path::new(path).is_file())
}
fn network_command(path: &Path, args: &[&str], policy: Policy) -> Command {
    let mut command = super::git_command(path, &[]);
    command.env_clear();
    for key in ["HOME", "XDG_CONFIG_HOME", "SSH_AUTH_SOCK", "LANG"] {
        if let Some(value) = std::env::var_os(key) {
            command.env(key, value);
        }
    }
    command.env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_LITERAL_PATHSPECS", "1")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_NO_LAZY_FETCH", "1")
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .env("GIT_ALLOW_PROTOCOL", match policy { Policy::Network => "https:ssh", #[cfg(test)] Policy::Fixture => "file:https:ssh" })
        .env("GIT_PROTOCOL_FROM_USER", "0")
        .env("GIT_ASKPASS", "/usr/bin/false")
        .env("SSH_ASKPASS", "/usr/bin/false")
        .env("SSH_ASKPASS_REQUIRE", "never")
        .env("GIT_SSH_COMMAND", "/usr/bin/ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=2")
        .args(["-c", "core.alternateRefsCommand=/usr/bin/false", "-c", "credential.helper=", "-c", "credential.interactive=false", "-c", "core.askPass=/usr/bin/false", "-c", "http.sslVerify=true", "-c", "http.followRedirects=false", "-c", "http.postBuffer=1048576", "-c", "http.lowSpeedLimit=1", "-c", "http.lowSpeedTime=30", "-c", "push.pushOption=", "-c", "push.followTags=false", "-c", "push.gpgSign=false"]);
    if let Some(helper) = credential_helper() {
        command.args(["-c", &format!("credential.helper={helper}")]);
    }
    command.args(args);
    command
}
fn network(path: &Path, args: &[&str], policy: Policy, push: bool) -> Result<Vec<u8>> {
    require_git_version(path)?;
    let out = super::process::run(
        network_command(path, args, policy),
        None,
        Duration::from_secs(180),
        8 * 1024 * 1024,
    )
    .map_err(|_| anyhow::anyhow!("remote_outcome_unknown"))?;
    if !out.status.success() {
        // Only structured porcelain rejection lines prove that a push was
        // rejected. Raw server diagnostics may contain credentials and are never
        // included in errors, logs, or RPC responses.
        if push {
            let text = String::from_utf8_lossy(&out.stdout);
            if text.lines().any(|line| {
                line.starts_with("!\t")
                    && (line.contains("[rejected]") || line.contains("[remote rejected]"))
            }) {
                bail!("remote_push_rejected");
            }
            bail!("remote_outcome_unknown");
        }
        bail!("remote_connection_failed");
    }
    Ok(out.stdout)
}
fn supported_git_version(text: &str) -> bool {
    let Some(version) = text
        .strip_prefix("git version ")
        .and_then(|v| v.split_whitespace().next())
    else {
        return false;
    };
    let fields: Vec<_> = version.split('.').collect();
    if fields.len() != 3 {
        return false;
    }
    let parsed: Option<Vec<u32>> = fields
        .into_iter()
        .map(|field| {
            if !field.is_empty() && field.bytes().all(|b| b.is_ascii_digit()) {
                field.parse().ok()
            } else {
                None
            }
        })
        .collect();
    parsed.is_some_and(|parts| parts[0] > 2 || (parts[0] == 2 && parts[1] >= 41))
}
fn require_git_version(path: &Path) -> Result<()> {
    static SUPPORTED: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    let supported = if let Some(supported) = SUPPORTED.get() {
        *supported
    } else {
        let output = run_local(path, &["--version"], false)?;
        let value = std::str::from_utf8(&output.stdout).is_ok_and(supported_git_version);
        let _ = SUPPORTED.set(value);
        value
    };
    ensure!(supported, "unsupported_git_version");
    Ok(())
}
fn remote_refs(path: &Path) -> Result<Vec<(String, String)>> {
    let output = run_local(
        path,
        &[
            "for-each-ref",
            "--format=%(refname)%00%(objectname)%00%(symref)",
            "refs/remotes/",
        ],
        false,
    )?;
    let text = std::str::from_utf8(&output.stdout).context("unsupported_remote_refs")?;
    text.lines()
        .map(|line| {
            let items: Vec<_> = line.split('\0').collect();
            ensure!(items.len() == 3, "unsupported_remote_refs");
            Ok((
                items[0].to_string(),
                if items[2].is_empty() {
                    items[1].into()
                } else {
                    String::new()
                },
            ))
        })
        .collect()
}
pub fn state(path: &Path) -> Result<RemoteState> {
    state_policy(path, Policy::Network)
}
fn state_policy(path: &Path, policy: Policy) -> Result<RemoteState> {
    let cfg = config(path)?;
    let snapshot = super::snapshot(path)?;
    let refs = remote_refs(path)?;
    let mut names = BTreeMap::<String, ()>::new();
    for (key, _) in &cfg {
        if let Some(rest) = key.strip_prefix("remote.")
            && let Some((name, _)) = rest.rsplit_once('.')
        {
            names.insert(name.to_string(), ());
        }
    }
    let mut remotes = Vec::new();
    for name in names.keys() {
        let prefix = format!("refs/remotes/{name}/");
        let validation = endpoints(&cfg, name, policy);
        let branches = refs
            .iter()
            .filter_map(|(r, oid)| {
                r.strip_prefix(&prefix)
                    .filter(|_| !oid.is_empty())
                    .map(|short| RemoteBranch {
                        name: short.into(),
                        oid: oid.clone(),
                    })
            })
            .collect();
        remotes.push(RemoteInfo {
            name: name.clone(),
            fetch_url: display_url(
                scalar(&cfg, &format!("remote.{name}.url")).unwrap_or(""),
                policy,
            ),
            push_url: display_url(
                scalar(&cfg, &format!("remote.{name}.pushurl"))
                    .or_else(|| scalar(&cfg, &format!("remote.{name}.url")))
                    .unwrap_or(""),
                policy,
            ),
            supported: validation.is_ok(),
            problem: validation.err().map(|e| e.to_string()),
            branches,
        });
    }
    let branch_short = snapshot.branch.strip_prefix("refs/heads/");
    let upstream_remote = branch_short
        .and_then(|branch| scalar(&cfg, &format!("branch.{branch}.remote")))
        .filter(|s| *s != ".")
        .map(str::to_string);
    let upstream_branch = branch_short
        .and_then(|branch| scalar(&cfg, &format!("branch.{branch}.merge")))
        .and_then(|s| s.strip_prefix("refs/heads/"))
        .map(str::to_string);
    let mut ahead = None;
    let mut behind = None;
    if !snapshot.head.is_empty()
        && let (Some(remote), Some(branch)) = (&upstream_remote, &upstream_branch)
    {
        let reference = format!("refs/remotes/{remote}/{branch}");
        if let Some((_, oid)) = refs
            .iter()
            .find(|(r, oid)| r == &reference && !oid.is_empty())
        {
            let range = format!("{}...{oid}", snapshot.head);
            let out = run_local(
                path,
                &["rev-list", "--left-right", "--count", &range, "--"],
                false,
            )?;
            let numbers: Vec<_> = std::str::from_utf8(&out.stdout)?
                .split_whitespace()
                .collect();
            if numbers.len() == 2 {
                ahead = numbers[0].parse().ok();
                behind = numbers[1].parse().ok();
            }
        }
    }
    let clean = super::status_bytes(path)?.is_empty() && super::no_conflicts(path).is_ok();
    let repository_path = fs::canonicalize(path)?
        .to_str()
        .context("unsupported_repo_path_encoding")?
        .to_string();
    Ok(RemoteState {
        state_hash: digest(&(&repository_path, &cfg, &snapshot, &refs))?,
        repository_path,
        branch: (!snapshot.branch.is_empty()).then_some(snapshot.branch),
        head: (!snapshot.head.is_empty()).then_some(snapshot.head),
        clean,
        remotes,
        upstream_remote,
        upstream_branch,
        ahead,
        behind,
    })
}
fn expected(path: &Path, hash: &str, policy: Policy) -> Result<RemoteState> {
    let current = state_policy(path, policy)?;
    ensure!(current.state_hash == hash, "stale_remote_state");
    Ok(current)
}
fn reviewed_endpoints(
    current: &RemoteState,
    cfg: &[(String, String)],
    name: &str,
    policy: Policy,
) -> Result<(String, String)> {
    let (fetch, push) = endpoints(cfg, name, policy)?;
    let reviewed = current
        .remotes
        .iter()
        .find(|r| r.name == name)
        .context("remote_not_found")?;
    ensure!(
        reviewed.supported && reviewed.fetch_url == fetch && reviewed.push_url == push,
        "stale_remote_state"
    );
    Ok((fetch, push))
}
pub fn configure(
    path: &Path,
    hash: &str,
    action: &str,
    name: &str,
    url: Option<&str>,
    push_url: Option<&str>,
) -> Result<()> {
    remote_name(name)?;
    ensure!(
        matches!(action, "add" | "update" | "remove"),
        "invalid_remote_action"
    );
    if action != "remove" {
        validate_remote_url(url.context("invalid_remote_url")?)?;
    }
    if let Some(push) = push_url {
        validate_remote_url(push)?;
    }
    ensure!(
        action != "remove" || (url.is_none() && push_url.is_none()),
        "invalid_remote_action"
    );
    let current = expected(path, hash, Policy::Network)?;
    let exists = current.remotes.iter().any(|r| r.name == name);
    ensure!(
        if action == "add" { !exists } else { exists },
        "remote_name_conflict"
    );
    // Restrict edits to local config; imported/global remotes must not be
    // silently shadowed. Git's own remove also updates upstream/ref metadata.
    if action != "add" {
        let section = format!("remote.{name}");
        let selected = |cfg: Vec<(String, String)>| {
            cfg.into_iter()
                .filter(|(key, _)| key.rsplit_once('.').is_some_and(|(s, _)| s == section))
                .collect::<Vec<_>>()
        };
        let effective = selected(config(path)?);
        let local = selected(config_scope(path, true)?);
        // Owning one local property is insufficient: inherited values would
        // survive the edit and could add a second effective endpoint.
        ensure!(!local.is_empty() && local == effective, "remote_not_local");
    }
    match action {
        "remove" => {
            run_local(path, &["remote", "remove", name], true)?;
        }
        "add" => {
            edit_local_config(path, |file| {
                expected(path, hash, Policy::Network)?;
                config_value(path, file, &format!("remote.{name}.url"), url)?;
                config_value(
                    path,
                    file,
                    &format!("remote.{name}.fetch"),
                    Some(&format!("+refs/heads/*:refs/remotes/{name}/*")),
                )?;
                if let Some(push) = push_url {
                    config_value(path, file, &format!("remote.{name}.pushurl"), Some(push))?;
                }
                Ok(())
            })?;
        }
        _ => {
            edit_local_config(path, |file| {
                expected(path, hash, Policy::Network)?;
                config_value(path, file, &format!("remote.{name}.url"), url)?;
                config_value(path, file, &format!("remote.{name}.pushurl"), push_url)
            })?;
        }
    }
    Ok(())
}
pub fn fetch(path: &Path, hash: &str, name: &str) -> Result<()> {
    fetch_policy(path, hash, name, Policy::Network)
}
fn fetch_policy(path: &Path, hash: &str, name: &str, policy: Policy) -> Result<()> {
    let initial = expected(path, hash, policy)?;
    let cfg = config(path)?;
    let (url, _) = reviewed_endpoints(&initial, &cfg, name, policy)?;
    expected(path, hash, policy)?;
    fetch_url(path, &url, name, policy).map(|_| ())
}
fn fetch_url(
    path: &Path,
    url: &str,
    name: &str,
    policy: Policy,
) -> Result<BTreeMap<String, Option<String>>> {
    let mapping = format!("+refs/heads/*:refs/remotes/{name}/*");
    let output = network(
        path,
        &[
            "fetch",
            "--porcelain",
            "--verbose",
            "--atomic",
            "--prune",
            "--no-prune-tags",
            "--no-tags",
            "--show-forced-updates",
            "--no-recurse-submodules",
            "--no-auto-maintenance",
            "--refmap=",
            "--",
            url,
            &mapping,
        ],
        policy,
        false,
    )?;
    parse_fetch(&output, name)
}
fn parse_fetch(output: &[u8], name: &str) -> Result<BTreeMap<String, Option<String>>> {
    let text = std::str::from_utf8(output).context("invalid_remote_fetch_result")?;
    let mut updates = BTreeMap::new();
    let prefix = format!("refs/remotes/{name}/");
    for line in text.lines() {
        let bytes = line.as_bytes();
        ensure!(
            bytes.len() > 2 && bytes[1] == b' ',
            "invalid_remote_fetch_result"
        );
        let flag = bytes[0];
        ensure!(
            matches!(flag, b' ' | b'+' | b'*' | b'=' | b'-'),
            "invalid_remote_fetch_result"
        );
        // Git's porcelain separators are ASCII spaces. A valid UTF-8 ref may
        // contain Unicode whitespace (for example U+00A0) as name data.
        let fields: Vec<_> = line[2..].split_ascii_whitespace().collect();
        ensure!(
            fields.len() == 3 && fields[2].starts_with(&prefix) && fields[2].len() > prefix.len(),
            "invalid_remote_fetch_result"
        );
        let valid_oid =
            |oid: &str| matches!(oid.len(), 40 | 64) && oid.bytes().all(|b| b.is_ascii_hexdigit());
        ensure!(
            valid_oid(fields[0]) && valid_oid(fields[1]) && fields[0].len() == fields[1].len(),
            "invalid_remote_fetch_result"
        );
        let new_oid = if flag == b'-' {
            ensure!(
                fields[1].bytes().all(|b| b == b'0'),
                "invalid_remote_fetch_result"
            );
            None
        } else {
            ensure!(
                !fields[1].bytes().all(|b| b == b'0'),
                "invalid_remote_fetch_result"
            );
            Some(fields[1].to_ascii_lowercase())
        };
        ensure!(
            updates.insert(fields[2].to_string(), new_oid).is_none(),
            "invalid_remote_fetch_result"
        );
    }
    Ok(updates)
}
pub fn pull(path: &Path, hash: &str, name: &str, branch: &str) -> Result<bool> {
    pull_policy(path, hash, name, branch, Policy::Network)
}
fn pull_policy(path: &Path, hash: &str, name: &str, branch: &str, policy: Policy) -> Result<bool> {
    validate_branch(path, branch)?;
    let initial = expected(path, hash, policy)?;
    ensure!(
        initial.branch.is_some() && initial.head.is_some(),
        "remote_branch_required"
    );
    ensure!(initial.clean, "remote_worktree_dirty");
    super::no_conflicts(path)?;
    super::no_external_filters(path)?;
    let local_snapshot = super::snapshot(path)?;
    let cfg = config(path)?;
    let (url, _) = reviewed_endpoints(&initial, &cfg, name, policy)?;
    expected(path, hash, policy)?;
    let fetched = fetch_url(path, &url, name, policy)?;
    let target = fetched
        .get(&format!("refs/remotes/{name}/{branch}"))
        .and_then(Option::as_deref)
        .context("remote_branch_missing")?;
    integrate_fetched(path, initial, &local_snapshot, &cfg, name, branch, target)
}
fn integrate_fetched(
    path: &Path,
    initial: RemoteState,
    local_snapshot: &workbench_domain::Snapshot,
    cfg: &[(String, String)],
    name: &str,
    branch: &str,
    target: &str,
) -> Result<bool> {
    ensure!(
        &super::snapshot(path)? == local_snapshot && config(path)? == cfg,
        "stale_remote_state"
    );
    super::no_conflicts(path)?;
    super::no_external_filters(path)?;
    // Pin the OID reported by our own fetch process. Shared remote-tracking
    // refs and FETCH_HEAD may be replaced by an ordinary external Git fetch.
    ensure!(
        super::oid(path, target)? == target,
        "invalid_remote_fetch_result"
    );
    let ancestor = super::process::run(
        super::git_command(
            path,
            &[
                "merge-base",
                "--is-ancestor",
                initial.head.as_ref().unwrap(),
                target,
            ],
        ),
        None,
        Duration::from_secs(15),
        1024,
    )?;
    ensure!(ancestor.status.success(), "remote_pull_not_fast_forward");
    let local_branch = initial.branch.unwrap();
    let branch_config = format!(
        "branch.{}.mergeOptions",
        local_branch
            .strip_prefix("refs/heads/")
            .context("remote_branch_required")?
    );
    // The fetched OID is immutable. FF-only integration cannot create commits.
    let mut command = super::git_command(
        path,
        &[
            "-c",
            "merge.verifySignatures=false",
            "-c",
            "merge.autoStash=false",
            "merge",
            "--ff-only",
            "--no-overwrite-ignore",
            "--no-edit",
            "--no-verify-signatures",
            target,
        ],
    );
    // A legal branch name can contain '='. Config environment entries keep the
    // key separate from its value instead of splitting `-c key=value` early.
    command
        .env("GIT_CONFIG_COUNT", "1")
        .env("GIT_CONFIG_KEY_0", branch_config)
        .env("GIT_CONFIG_VALUE_0", "");
    // An unchanged tracked snapshot cannot prove a failed checkout made no
    // writes: interrupted integration may have left ignored paths behind.
    // Keep every unsuccessful integration conservative about its outcome.
    run_local_command(command, true)?;
    ensure!(
        super::oid(path, "HEAD").is_ok_and(|head| head == target),
        "remote_outcome_unknown"
    );
    // Integration is confirmed. Preserve choices made by another Git process
    // while checkout ran; optional tracking failures cannot undo that success.
    Ok(finish_pull(path, cfg, &local_branch, name, branch, target))
}
fn finish_pull(
    path: &Path,
    cfg: &[(String, String)],
    local_branch: &str,
    remote: &str,
    branch: &str,
    target: &str,
) -> bool {
    if run_local(path, &["symbolic-ref", "--quiet", "HEAD"], false)
        .is_ok_and(|current| current.stdout == format!("{local_branch}\n").as_bytes())
        && super::oid(path, "HEAD").is_ok_and(|current| current == target)
        && config(path).is_ok_and(|current| current == cfg)
    {
        return set_upstream(path, cfg, local_branch, remote, branch).is_ok();
    }
    false
}
fn validate_branch(path: &Path, branch: &str) -> Result<()> {
    ensure!(
        !branch.is_empty() && branch.len() <= 1024 && !branch.starts_with('-'),
        "invalid_remote_branch"
    );
    super::validate_branch(path, &format!("refs/heads/{branch}"))
        .map_err(|_| anyhow::anyhow!("invalid_remote_branch"))
}
pub fn push(path: &Path, hash: &str, name: &str, branch: &str) -> Result<bool> {
    push_policy(path, hash, name, branch, Policy::Network)
}
fn push_policy(path: &Path, hash: &str, name: &str, branch: &str, policy: Policy) -> Result<bool> {
    validate_branch(path, branch)?;
    let initial = expected(path, hash, policy)?;
    let local_branch = initial.branch.clone().context("remote_branch_required")?;
    let oid = initial.head.clone().context("remote_branch_required")?;
    let cfg = config(path)?;
    let (_, url) = reviewed_endpoints(&initial, &cfg, name, policy)?;
    let local_snapshot = super::snapshot(path)?;
    expected(path, hash, policy)?;
    let refspec = format!("{oid}:refs/heads/{branch}");
    network(
        path,
        &[
            "push",
            "--porcelain",
            "--no-follow-tags",
            "--recurse-submodules=no",
            "--signed=false",
            "--",
            &url,
            &refspec,
        ],
        policy,
        true,
    )?;
    // The remote acknowledged the reviewed OID. Optional metadata failures
    // must not turn that confirmed push into an ambiguous/retryable failure.
    Ok(finish_push(
        path,
        &local_snapshot,
        &cfg,
        &local_branch,
        name,
        branch,
    ))
}
fn finish_push(
    path: &Path,
    initial: &workbench_domain::Snapshot,
    cfg: &[(String, String)],
    local_branch: &str,
    remote: &str,
    target: &str,
) -> bool {
    if super::snapshot(path).is_ok_and(|current| &current == initial)
        && config(path).is_ok_and(|current| current == cfg)
    {
        return set_upstream(path, cfg, local_branch, remote, target).is_ok();
    }
    false
}
fn set_upstream(
    path: &Path,
    cfg: &[(String, String)],
    branch: &str,
    remote: &str,
    target: &str,
) -> Result<()> {
    let branch = branch
        .strip_prefix("refs/heads/")
        .context("remote_branch_required")?;
    edit_local_config(path, |file| {
        ensure!(config(path)? == cfg, "stale_remote_state");
        config_value(path, file, &format!("branch.{branch}.remote"), Some(remote))?;
        config_value(
            path,
            file,
            &format!("branch.{branch}.merge"),
            Some(&format!("refs/heads/{target}")),
        )
    })
}
pub fn clone_repository(url: &str, destination: &Path) -> Result<PathBuf> {
    // Leave the native helper time to receive the terminal result before its
    // 360-second deadline; all Git children remain under this tighter budget.
    super::with_deadline(Duration::from_secs(330), || {
        clone_policy(url, destination, Policy::Network)
    })
}
fn clone_policy(url: &str, destination: &Path, policy: Policy) -> Result<PathBuf> {
    validate_url(url, policy)?;
    ensure!(destination.is_absolute(), "invalid_clone_destination");
    let name = destination
        .file_name()
        .context("invalid_clone_destination")?;
    ensure!(name != "." && name != "..", "invalid_clone_destination");
    let parent = fs::canonicalize(destination.parent().context("invalid_clone_destination")?)
        .context("invalid_clone_destination")?;
    let destination = parent.join(name);
    ensure!(
        fs::symlink_metadata(&destination).is_err_and(|e| e.kind() == std::io::ErrorKind::NotFound),
        "clone_destination_exists"
    );
    transport_config(&config(&parent)?)?;
    let mut stage = None;
    for counter in 0..100u32 {
        let candidate = parent.join(format!(
            ".river-clone-{}-{}-{counter}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)?
                .as_nanos()
        ));
        use std::os::unix::fs::DirBuilderExt;
        match fs::DirBuilder::new().mode(0o700).create(&candidate) {
            Ok(()) => {
                stage = Some(candidate);
                break;
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(_) => bail!("clone_staging_failed"),
        }
    }
    let stage = stage.context("clone_staging_failed")?;
    struct OwnedStage(PathBuf);
    impl Drop for OwnedStage {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let owned = OwnedStage(stage.clone());
    let stage_text = stage.to_str().context("unsupported_repo_path_encoding")?;
    network(
        &parent,
        &[
            "clone",
            "--no-checkout",
            "--no-recurse-submodules",
            "--template=",
            "--",
            url,
            stage_text,
        ],
        policy,
        false,
    )?;
    super::root(&stage)?;
    transport_config(&config(&stage)?)?;
    super::no_external_filters(&stage)?;
    let snapshot = super::snapshot(&stage)?;
    if !snapshot.head.is_empty() {
        run_local(
            &stage,
            &[
                "checkout",
                "--force",
                "--no-recurse-submodules",
                "HEAD",
                "--",
            ],
            true,
        )?;
    }
    publish(&stage, &destination)?;
    drop(owned);
    Ok(destination)
}
fn publish(stage: &Path, destination: &Path) -> Result<()> {
    use std::os::unix::ffi::OsStrExt;
    let source = std::ffi::CString::new(stage.as_os_str().as_bytes())
        .context("invalid_clone_destination")?;
    let target = std::ffi::CString::new(destination.as_os_str().as_bytes())
        .context("invalid_clone_destination")?;
    #[cfg(target_os = "macos")]
    let result = unsafe { libc::renamex_np(source.as_ptr(), target.as_ptr(), libc::RENAME_EXCL) };
    #[cfg(target_os = "linux")]
    let result = unsafe {
        libc::renameat2(
            libc::AT_FDCWD,
            source.as_ptr(),
            libc::AT_FDCWD,
            target.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    compile_error!("atomic no-replace directory publication needs a platform implementation");
    ensure!(result == 0, "clone_destination_exists");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;
    fn git(path: &Path, args: &[&str]) -> String {
        let out = Command::new("/usr/bin/git")
            .current_dir(path)
            .args([
                "-c",
                "core.hooksPath=/dev/null",
                "-c",
                "commit.gpgSign=false",
            ])
            .args(args)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "Git fixture failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8(out.stdout).unwrap().trim().into()
    }
    struct Fixture {
        _dir: TempDir,
        source: PathBuf,
        bare: PathBuf,
        client: PathBuf,
        url: String,
    }
    impl Fixture {
        fn new() -> Self {
            let dir = TempDir::new().unwrap();
            let source = dir.path().join("source");
            let bare = dir.path().join("server.git");
            let client = dir.path().join("client");
            fs::create_dir(&source).unwrap();
            git(&source, &["init", "-b", "main"]);
            git(&source, &["config", "user.name", "Fixture"]);
            git(&source, &["config", "user.email", "fixture@example.test"]);
            fs::write(source.join("hello.txt"), "one\n").unwrap();
            git(&source, &["add", "."]);
            git(&source, &["commit", "-m", "one"]);
            git(
                dir.path(),
                &[
                    "clone",
                    "--bare",
                    source.to_str().unwrap(),
                    bare.to_str().unwrap(),
                ],
            );
            let url = format!("file://{}", bare.display());
            clone_policy(&url, &client, Policy::Fixture).unwrap();
            git(&client, &["config", "user.name", "Fixture"]);
            git(&client, &["config", "user.email", "fixture@example.test"]);
            Self {
                _dir: dir,
                source,
                bare,
                client,
                url,
            }
        }
        fn state(&self) -> RemoteState {
            state_policy(&self.client, Policy::Fixture).unwrap()
        }
        fn advance(&self) {
            fs::write(self.source.join("hello.txt"), "two\n").unwrap();
            git(&self.source, &["add", "."]);
            git(&self.source, &["commit", "-m", "two"]);
            git(&self.source, &["push", self.bare.to_str().unwrap(), "main"]);
        }
    }
    #[test]
    fn production_urls_and_display_never_accept_credentials_helpers_or_paths() {
        for url in [
            "https://gitlab.com/group/project.git",
            "ssh://git@git.example:2222/group/project.git",
            "git@github.com:owner/repo.git",
            "ssh://git@[::1]:22/a.git",
        ] {
            validate_remote_url(url).unwrap();
        }
        for url in [
            "",
            "/tmp/server.git",
            "../server",
            "file:///tmp/a",
            "ext::sh -c id",
            "ext::sh",
            "ext::/usr/bin/id",
            "fd::3",
            "git@host::project",
            "https://alice:secret@example.test/a",
            "https://token@example.test/a",
            "ssh://git:secret@host/a",
            "-host:a",
            "git@-host:a",
            "https://host/a?token=secret",
            "git@host:a\n-b",
            "https://host/a#token",
            "https://host/%0afoo",
            "ssh://host:0/a",
            "https://host:/a",
        ] {
            assert!(validate_remote_url(url).is_err(), "accepted {url}");
            assert_eq!(
                display_url(url, Policy::Network),
                "[unsupported or credential-bearing URL]"
            );
        }
    }
    #[test]
    fn helper_urls_are_never_stored_or_reported_supported() {
        let f = Fixture::new();
        for url in ["ext::sh", "ext::/usr/bin/id", "fd::3", "git@host::project"] {
            assert!(configure(&f.client, "unused", "add", "unsafe", Some(url), None).is_err());
            assert_eq!(git(&f.client, &["remote"]), "origin");
            git(&f.client, &["config", "remote.unsafe.url", url]);
            let state = state(&f.client).unwrap();
            let remote = state.remotes.iter().find(|r| r.name == "unsafe").unwrap();
            assert!(!remote.supported);
            assert_eq!(remote.fetch_url, "[unsupported or credential-bearing URL]");
            git(&f.client, &["config", "--remove-section", "remote.unsafe"]);
        }
    }
    #[test]
    fn remote_git_version_requires_supported_porcelain_format() {
        for version in [
            "git version 2.41.0",
            "git version 2.54.0 (Apple Git-157)\n",
            "git version 3.0.0",
            "git version 12.1.8",
        ] {
            assert!(supported_git_version(version), "rejected {version}");
        }
        for version in [
            "git version 1.99.0",
            "git version 2.40.9 (Apple Git-150)",
            "git version 2.41",
            "git version 2.41.x",
            "git version 2.41.0-rc1",
            "git version 99999999999999.0.0",
            "2.54.0",
            "git version ",
            "",
        ] {
            assert!(!supported_git_version(version), "accepted {version}");
        }
    }
    #[test]
    fn unsafe_config_is_rejected_before_any_helper_or_hook_executes() {
        let f = Fixture::new();
        let marker = f._dir.path().join("executed");
        let shell = format!("!touch {}", marker.display());
        git(&f.client, &["config", "credential.helper", &shell]);
        git(
            &f.client,
            &[
                "config",
                "core.sshCommand",
                &format!("touch {}", marker.display()),
            ],
        );
        let command = network_command(&f.client, &["fetch"], Policy::Network);
        let env: BTreeMap<_, _> = command
            .get_envs()
            .map(|(k, v)| {
                (
                    k.to_string_lossy().into_owned(),
                    v.map(|v| v.to_string_lossy().into_owned()),
                )
            })
            .collect();
        assert!(
            env["GIT_SSH_COMMAND"]
                .as_ref()
                .unwrap()
                .starts_with("/usr/bin/ssh -F /dev/null")
        );
        assert_eq!(env["GIT_ASKPASS"].as_deref(), Some("/usr/bin/false"));
        assert!(
            !command
                .get_args()
                .any(|a| a.to_string_lossy().contains("touch"))
        );
        for (key, value) in [
            ("url.https://evil.test/.insteadOf", "https://github.com/"),
            ("remote.origin.vcs", "ext"),
            ("remote.origin.uploadpack", "touch marker"),
            ("remote.origin.receivepack", "touch marker"),
            ("remote.origin.promisor", "true"),
            ("http.sslVerify", "false"),
            ("http.https://host.extraHeader", "Authorization: secret"),
        ] {
            git(&f.client, &["config", key, value]);
            assert!(
                transport_config(&config(&f.client).unwrap()).is_err(),
                "accepted {key}"
            );
            git(&f.client, &["config", "--unset-all", key]);
        }
        assert!(!marker.exists());
        assert!(fetch(&f.client, &state(&f.client).unwrap().state_hash, "origin").is_err());
        assert!(!marker.exists());
        // Exercise a real SSH child: a repository SSH override must never run.
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);
        let endpoint = format!("ssh://git@127.0.0.1:{port}/fixture.git");
        let error = network(
            &f.client,
            &["ls-remote", "--", &endpoint],
            Policy::Network,
            false,
        )
        .unwrap_err();
        assert_eq!(error.to_string(), "remote_connection_failed");
        assert!(!marker.exists());
        // Verify Git's helper-reset semantics, including URL-specific helpers,
        // without reading the user's keychain in a unit test.
        git(
            &f.client,
            &[
                "config",
                "credential.https://example.invalid.helper",
                &shell,
            ],
        );
        let mut command = network_command(&f.client, &[], Policy::Network);
        command.args([
            "-c",
            "credential.helper=",
            "-c",
            "credential.helper=/usr/bin/false",
            "credential",
            "fill",
        ]);
        let result = super::super::process::run(
            command,
            Some(b"protocol=https\nhost=example.invalid\n\n"),
            Duration::from_secs(5),
            1024,
        )
        .unwrap();
        assert!(!result.status.success());
        assert!(!marker.exists());
    }
    #[test]
    fn alternates_shell_command_is_rejected_and_disabled_at_network_boundary() {
        let f = Fixture::new();
        let marker = f._dir.path().join("alternate-command-executed");
        let alternate = f.source.join(".git/objects");
        fs::create_dir_all(f.client.join(".git/objects/info")).unwrap();
        fs::write(
            f.client.join(".git/objects/info/alternates"),
            format!("{}\n", alternate.display()),
        )
        .unwrap();
        git(
            &f.client,
            &[
                "config",
                "core.alternateRefsCommand",
                &format!("touch '{}'", marker.display()),
            ],
        );
        git(
            &f.client,
            &[
                "config",
                "remote.origin.url",
                "https://example.invalid/repo.git",
            ],
        );
        let current = state(&f.client).unwrap();
        assert!(!current.remotes[0].supported);
        assert_eq!(
            fetch(&f.client, &current.state_hash, "origin")
                .unwrap_err()
                .to_string(),
            "unsupported_alternate_command"
        );
        assert!(!marker.exists());
        f.advance();
        // Even if the execution boundary encounters a command configured after
        // preflight, its fixed override prevents the shell from being invoked.
        let result = network(
            &f.client,
            &[
                "fetch",
                "--no-tags",
                "--",
                &f.url,
                "+refs/heads/*:refs/remotes/origin/*",
            ],
            Policy::Fixture,
            false,
        );
        assert!(result.is_ok());
        assert!(!marker.exists());
    }
    #[test]
    fn porcelain_fetch_reports_each_ref_state_and_never_prunes_local_tags() {
        let f = Fixture::new();
        let original = git(&f.client, &["rev-parse", "HEAD"]);
        git(&f.client, &["tag", "local-only"]);
        git(&f.client, &["config", "fetch.pruneTags", "true"]);
        let unchanged = fetch_url(&f.client, &f.url, "origin", Policy::Fixture).unwrap();
        assert_eq!(
            unchanged["refs/remotes/origin/main"].as_deref(),
            Some(original.as_str())
        );
        git(&f.source, &["branch", "topic"]);
        git(&f.source, &["push", f.bare.to_str().unwrap(), "topic"]);
        let added = fetch_url(&f.client, &f.url, "origin", Policy::Fixture).unwrap();
        assert_eq!(
            added["refs/remotes/origin/topic"].as_deref(),
            Some(original.as_str())
        );
        f.advance();
        let advanced = git(&f.source, &["rev-parse", "HEAD"]);
        let updated = fetch_url(&f.client, &f.url, "origin", Policy::Fixture).unwrap();
        assert_eq!(
            updated["refs/remotes/origin/main"].as_deref(),
            Some(advanced.as_str())
        );
        git(&f.bare, &["update-ref", "refs/heads/main", &original]);
        let forced = fetch_url(&f.client, &f.url, "origin", Policy::Fixture).unwrap();
        assert_eq!(
            forced["refs/remotes/origin/main"].as_deref(),
            Some(original.as_str())
        );
        git(&f.bare, &["update-ref", "-d", "refs/heads/topic"]);
        let pruned = fetch_url(&f.client, &f.url, "origin", Policy::Fixture).unwrap();
        assert_eq!(pruned["refs/remotes/origin/topic"], None);
        assert!(!pruned.contains_key("refs/remotes/origin/missing"));
        assert!(super::super::ref_exists(&f.client, "refs/tags/local-only").unwrap());
        let zero = "0".repeat(40);
        for flag in [' ', '+', '*', '='] {
            let text = format!("{flag} {zero} {original} refs/remotes/origin/main\n");
            assert_eq!(
                parse_fetch(text.as_bytes(), "origin").unwrap()["refs/remotes/origin/main"]
                    .as_deref(),
                Some(original.as_str())
            );
        }
        for invalid in [
            format!("! {zero} {original} refs/remotes/origin/main\n"),
            format!("* {zero} {original} refs/heads/main\n"),
            format!("* {zero} not-an-oid refs/remotes/origin/main\n"),
            format!(
                "* {zero} {original} refs/remotes/origin/main\n* {zero} {original} refs/remotes/origin/main\n"
            ),
        ] {
            assert!(parse_fetch(invalid.as_bytes(), "origin").is_err());
        }
    }
    #[test]
    fn fetch_preserves_unicode_and_nbsp_refs_while_pulling_ascii_main() {
        let f = Fixture::new();
        let names = ["기능/강줄기", "feature/a\u{00a0}b"];
        for name in names {
            git(&f.source, &["branch", name]);
            git(&f.source, &["push", f.bare.to_str().unwrap(), name]);
        }
        let original = git(&f.client, &["rev-parse", "HEAD"]);
        let fetched = fetch_url(&f.client, &f.url, "origin", Policy::Fixture).unwrap();
        for name in names {
            assert_eq!(
                fetched[&format!("refs/remotes/origin/{name}")].as_deref(),
                Some(original.as_str())
            );
        }
        f.advance();
        assert!(
            pull_policy(
                &f.client,
                &f.state().state_hash,
                "origin",
                "main",
                Policy::Fixture
            )
            .unwrap()
        );
        assert_eq!(
            fs::read_to_string(f.client.join("hello.txt")).unwrap(),
            "two\n"
        );
        let refs = f.state().remotes.remove(0).branches;
        for name in names {
            assert!(refs.iter().any(|branch| branch.name == name));
        }
        for (index, name) in names.into_iter().enumerate() {
            let before = git(&f.client, &["rev-parse", "HEAD"]);
            fs::write(f.client.join(format!("unicode-pull-{index}")), "incoming\n").unwrap();
            git(&f.client, &["add", "."]);
            git(
                &f.client,
                &["commit", "-m", "prepare Unicode target advance"],
            );
            let incoming = git(&f.client, &["rev-parse", "HEAD"]);
            git(
                &f.client,
                &[
                    "push",
                    f.bare.to_str().unwrap(),
                    &format!("HEAD:refs/heads/{name}"),
                ],
            );
            git(&f.client, &["reset", "--hard", &before]);
            assert!(
                pull_policy(
                    &f.client,
                    &f.state().state_hash,
                    "origin",
                    name,
                    Policy::Fixture
                )
                .unwrap()
            );
            assert_eq!(git(&f.client, &["rev-parse", "HEAD"]), incoming);
            assert_eq!(
                git(&f.client, &["config", "branch.main.merge"]),
                format!("refs/heads/{name}")
            );
            fs::write(f.client.join(format!("unicode-push-{index}")), "outgoing\n").unwrap();
            git(&f.client, &["add", "."]);
            git(&f.client, &["commit", "-m", "push Unicode target"]);
            assert!(
                push_policy(
                    &f.client,
                    &f.state().state_hash,
                    "origin",
                    name,
                    Policy::Fixture
                )
                .unwrap()
            );
            assert_eq!(
                git(&f.bare, &["rev-parse", &format!("refs/heads/{name}")]),
                git(&f.client, &["rev-parse", "HEAD"])
            );
            assert_eq!(
                git(&f.client, &["config", "branch.main.merge"]),
                format!("refs/heads/{name}")
            );
        }
        let state = f.state();
        let snapshot = super::super::snapshot(&f.client).unwrap();
        let cfg = config(&f.client).unwrap();
        let server_refs = git(
            &f.bare,
            &[
                "for-each-ref",
                "--format=%(refname) %(objectname)",
                "refs/heads/",
            ],
        );
        for invalid in ["bad branch", "bad\nbranch", "-invalid"] {
            assert_eq!(
                pull_policy(
                    &f.client,
                    &state.state_hash,
                    "origin",
                    invalid,
                    Policy::Fixture
                )
                .unwrap_err()
                .to_string(),
                "invalid_remote_branch"
            );
            assert_eq!(
                push_policy(
                    &f.client,
                    &state.state_hash,
                    "origin",
                    invalid,
                    Policy::Fixture
                )
                .unwrap_err()
                .to_string(),
                "invalid_remote_branch"
            );
        }
        assert_eq!(super::super::snapshot(&f.client).unwrap(), snapshot);
        assert_eq!(config(&f.client).unwrap(), cfg);
        assert_eq!(
            git(
                &f.bare,
                &[
                    "for-each-ref",
                    "--format=%(refname) %(objectname)",
                    "refs/heads/"
                ]
            ),
            server_refs
        );
        assert_eq!(f.state().state_hash, state.state_hash);
    }
    #[test]
    fn fetch_prunes_only_reviewed_remote_and_state_pins_config_and_source() {
        let f = Fixture::new();
        git(&f.source, &["branch", "gone"]);
        git(&f.source, &["push", f.bare.to_str().unwrap(), "gone"]);
        fetch_policy(&f.client, &f.state().state_hash, "origin", Policy::Fixture).unwrap();
        let oid = git(&f.client, &["rev-parse", "HEAD"]);
        git(&f.client, &["update-ref", "refs/remotes/other/keep", &oid]);
        git(
            &f.client,
            &[
                "config",
                "remote.origin.fetch",
                "+refs/heads/*:refs/heads/*",
            ],
        );
        git(&f.bare, &["update-ref", "-d", "refs/heads/gone"]);
        fetch_policy(&f.client, &f.state().state_hash, "origin", Policy::Fixture).unwrap();
        assert!(!super::super::ref_exists(&f.client, "refs/remotes/origin/gone").unwrap());
        assert!(super::super::ref_exists(&f.client, "refs/remotes/other/keep").unwrap());
        let stale = f.state().state_hash;
        git(
            &f.client,
            &[
                "config",
                "remote.origin.pushurl",
                "ssh://git@example.test/changed.git",
            ],
        );
        assert_eq!(
            fetch_policy(&f.client, &stale, "origin", Policy::Fixture)
                .unwrap_err()
                .to_string(),
            "stale_remote_state"
        );
        let stale = f.state().state_hash;
        fs::write(f.client.join("untracked"), "external edit").unwrap();
        assert_eq!(
            fetch_policy(&f.client, &stale, "origin", Policy::Fixture)
                .unwrap_err()
                .to_string(),
            "stale_remote_state"
        );
    }
    #[test]
    fn pull_fast_forwards_but_preserves_dirty_or_diverged_work() {
        let f = Fixture::new();
        use std::os::unix::fs::PermissionsExt;
        let hook_marker = f._dir.path().join("hook-executed");
        fs::create_dir_all(f.client.join(".git/hooks")).unwrap();
        for hook in ["post-merge", "reference-transaction", "post-checkout"] {
            let path = f.client.join(".git/hooks").join(hook);
            fs::write(
                &path,
                format!("#!/bin/sh\ntouch '{}'\n", hook_marker.display()),
            )
            .unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        }
        f.advance();
        fs::write(f.client.join("untracked"), "draft").unwrap();
        assert_eq!(
            pull_policy(
                &f.client,
                &f.state().state_hash,
                "origin",
                "main",
                Policy::Fixture
            )
            .unwrap_err()
            .to_string(),
            "remote_worktree_dirty"
        );
        fs::remove_file(f.client.join("untracked")).unwrap();
        assert!(
            pull_policy(
                &f.client,
                &f.state().state_hash,
                "origin",
                "main",
                Policy::Fixture,
            )
            .unwrap()
        );
        assert_eq!(
            fs::read_to_string(f.client.join("hello.txt")).unwrap(),
            "two\n"
        );
        assert!(f.state().clean);
        fs::write(f.client.join("local"), "local").unwrap();
        git(&f.client, &["add", "."]);
        git(&f.client, &["commit", "-m", "local"]);
        fs::write(f.source.join("remote"), "remote").unwrap();
        git(&f.source, &["add", "."]);
        git(&f.source, &["commit", "-m", "remote"]);
        git(&f.source, &["push", f.bare.to_str().unwrap(), "main"]);
        let head = git(&f.client, &["rev-parse", "HEAD"]);
        assert_eq!(
            pull_policy(
                &f.client,
                &f.state().state_hash,
                "origin",
                "main",
                Policy::Fixture
            )
            .unwrap_err()
            .to_string(),
            "remote_pull_not_fast_forward"
        );
        assert_eq!(git(&f.client, &["rev-parse", "HEAD"]), head);
        assert!(!hook_marker.exists());
    }
    #[test]
    fn pull_ignores_merge_options_even_when_branch_contains_equals() {
        let f = Fixture::new();
        git(&f.client, &["branch", "-m", "a=b"]);
        git(
            &f.client,
            &["config", "branch.a=b.mergeOptions", "--squash"],
        );
        f.advance();
        assert!(
            pull_policy(
                &f.client,
                &f.state().state_hash,
                "origin",
                "main",
                Policy::Fixture
            )
            .unwrap()
        );
        assert_eq!(
            git(&f.client, &["rev-parse", "HEAD"]),
            git(&f.source, &["rev-parse", "HEAD"])
        );
        assert!(f.state().clean);
    }
    #[test]
    fn related_config_edits_publish_together_and_preserve_mode() {
        use std::os::unix::fs::PermissionsExt;
        let f = Fixture::new();
        let config_path = f.client.join(".git/config");
        fs::set_permissions(&config_path, fs::Permissions::from_mode(0o640)).unwrap();
        let original = fs::read(&config_path).unwrap();
        let failed = edit_local_config(&f.client, |file| {
            config_value(&f.client, file, "branch.main.remote", Some("replacement"))?;
            config_value(&f.client, file, "invalid", Some("fails after first edit"))
        });
        assert!(failed.is_err());
        assert_eq!(fs::read(&config_path).unwrap(), original);
        assert!(!config_path.with_extension("lock").exists());
        let cfg = config(&f.client).unwrap();
        set_upstream(
            &f.client,
            &cfg,
            "refs/heads/main",
            "replacement",
            "reviewed",
        )
        .unwrap();
        assert_eq!(
            git(&f.client, &["config", "branch.main.remote"]),
            "replacement"
        );
        assert_eq!(
            git(&f.client, &["config", "branch.main.merge"]),
            "refs/heads/reviewed"
        );
        assert_eq!(
            fs::metadata(&config_path).unwrap().permissions().mode() & 0o777,
            0o640
        );
        edit_local_config(&f.client, |file| {
            // Model an atomic config writer replacing its input's inode.
            let replacement = file.with_extension("replacement");
            fs::write(&replacement, fs::read(file)?)?;
            fs::set_permissions(&replacement, fs::Permissions::from_mode(0o644))?;
            fs::rename(replacement, file)?;
            Ok(())
        })
        .unwrap();
        assert_eq!(
            fs::metadata(&config_path).unwrap().permissions().mode() & 0o777,
            0o640
        );
    }
    #[test]
    fn config_transaction_respects_external_locks_and_uncooperative_edits() {
        let f = Fixture::new();
        let config_path = f.client.join(".git/config");
        let lock = config_path.with_extension("lock");
        let original = fs::read(&config_path).unwrap();
        fs::write(&lock, "another Git process").unwrap();
        assert!(edit_local_config(&f.client, |_| panic!("must not edit without lock")).is_err());
        assert_eq!(fs::read_to_string(&lock).unwrap(), "another Git process");
        fs::remove_file(&lock).unwrap();
        let mut edited = original.clone();
        edited.extend_from_slice(b"\n# manual edit outside Git\n");
        let failed = edit_local_config(&f.client, |file| {
            config_value(&f.client, file, "branch.main.remote", Some("replacement"))?;
            fs::write(&config_path, &edited)?;
            Ok(())
        })
        .unwrap_err();
        assert_eq!(failed.to_string(), "stale_remote_state");
        assert_eq!(fs::read(&config_path).unwrap(), edited);
        assert!(!lock.exists());
    }
    #[test]
    fn pull_rejects_source_and_endpoint_drift_after_fetch() {
        let f = Fixture::new();
        f.advance();
        let initial = f.state();
        let snapshot = super::super::snapshot(&f.client).unwrap();
        let cfg = config(&f.client).unwrap();
        let fetched = fetch_url(&f.client, &f.url, "origin", Policy::Fixture).unwrap();
        let target = fetched["refs/remotes/origin/main"].as_deref().unwrap();
        fs::write(f.client.join("hello.txt"), "external edit\n").unwrap();
        assert_eq!(
            integrate_fetched(
                &f.client,
                initial.clone(),
                &snapshot,
                &cfg,
                "origin",
                "main",
                target
            )
            .unwrap_err()
            .to_string(),
            "stale_remote_state"
        );
        assert_eq!(
            fs::read_to_string(f.client.join("hello.txt")).unwrap(),
            "external edit\n"
        );
        fs::write(f.client.join("hello.txt"), "one\n").unwrap();
        git(
            &f.client,
            &["config", "remote.origin.url", "https://host/changed.git"],
        );
        assert_eq!(
            integrate_fetched(
                &f.client, initial, &snapshot, &cfg, "origin", "main", target
            )
            .unwrap_err()
            .to_string(),
            "stale_remote_state"
        );
        assert_eq!(
            fs::read_to_string(f.client.join("hello.txt")).unwrap(),
            "one\n"
        );
    }
    #[test]
    fn pull_never_overwrites_ignored_local_content() {
        let f = Fixture::new();
        fs::write(f.source.join(".gitignore"), "local.env\n").unwrap();
        git(&f.source, &["add", ".gitignore"]);
        git(&f.source, &["commit", "-m", "ignore local environment"]);
        git(&f.source, &["push", f.bare.to_str().unwrap(), "main"]);
        pull_policy(
            &f.client,
            &f.state().state_hash,
            "origin",
            "main",
            Policy::Fixture,
        )
        .unwrap();
        fs::write(f.client.join("local.env"), "my private configuration\n").unwrap();
        assert!(f.state().clean);
        let before = super::super::snapshot(&f.client).unwrap();
        fs::write(f.source.join("local.env"), "incoming tracked content\n").unwrap();
        git(&f.source, &["add", "--force", "local.env"]);
        git(&f.source, &["commit", "-m", "track incoming environment"]);
        git(&f.source, &["push", f.bare.to_str().unwrap(), "main"]);
        assert_eq!(
            pull_policy(
                &f.client,
                &f.state().state_hash,
                "origin",
                "main",
                Policy::Fixture
            )
            .unwrap_err()
            .to_string(),
            "remote_outcome_unknown"
        );
        assert_eq!(
            fs::read_to_string(f.client.join("local.env")).unwrap(),
            "my private configuration\n"
        );
        assert_eq!(super::super::snapshot(&f.client).unwrap(), before);
    }
    #[test]
    fn pull_uses_its_own_fetch_oid_when_shared_remote_ref_is_replaced() {
        let f = Fixture::new();
        f.advance();
        let initial = f.state();
        let snapshot = super::super::snapshot(&f.client).unwrap();
        let cfg = config(&f.client).unwrap();
        let fetched = fetch_url(&f.client, &f.url, "origin", Policy::Fixture).unwrap();
        let target = fetched["refs/remotes/origin/main"].as_deref().unwrap();
        let tree = git(&f.client, &["rev-parse", &format!("{target}^{{tree}}")]);
        let substituted = git(
            &f.client,
            &[
                "commit-tree",
                &tree,
                "-p",
                target,
                "-m",
                "unreviewed external fetch",
            ],
        );
        git(
            &f.client,
            &["update-ref", "refs/remotes/origin/main", &substituted],
        );
        integrate_fetched(
            &f.client, initial, &snapshot, &cfg, "origin", "main", target,
        )
        .unwrap();
        assert_eq!(git(&f.client, &["rev-parse", "HEAD"]), target);
        assert_eq!(
            git(&f.client, &["rev-parse", "refs/remotes/origin/main"]),
            substituted
        );
        assert_eq!(
            pull_policy(
                &f.client,
                &f.state().state_hash,
                "origin",
                "missing",
                Policy::Fixture
            )
            .unwrap_err()
            .to_string(),
            "remote_branch_missing"
        );
    }
    #[test]
    fn confirmed_pull_preserves_external_tracking_choices_after_merge() {
        let f = Fixture::new();
        f.advance();
        let cfg = config(&f.client).unwrap();
        assert!(
            pull_policy(
                &f.client,
                &f.state().state_hash,
                "origin",
                "main",
                Policy::Fixture
            )
            .unwrap()
        );
        let target = git(&f.source, &["rev-parse", "HEAD"]);
        assert_eq!(git(&f.client, &["rev-parse", "HEAD"]), target);
        // Deterministic post-merge seam: another local Git process changes
        // endpoint and tracking choices while checkout has completed.
        git(
            &f.client,
            &[
                "config",
                "remote.origin.url",
                "https://elsewhere.invalid/preserved.git",
            ],
        );
        git(&f.client, &["config", "branch.main.remote", "preserved"]);
        git(
            &f.client,
            &["config", "branch.main.merge", "refs/heads/preserved"],
        );
        assert!(!finish_pull(
            &f.client,
            &cfg,
            "refs/heads/main",
            "origin",
            "main",
            &target
        ));
        assert_eq!(git(&f.client, &["rev-parse", "HEAD"]), target);
        assert_eq!(
            git(&f.client, &["config", "remote.origin.url"]),
            "https://elsewhere.invalid/preserved.git"
        );
        assert_eq!(
            git(&f.client, &["config", "branch.main.remote"]),
            "preserved"
        );
        assert_eq!(
            git(&f.client, &["config", "branch.main.merge"]),
            "refs/heads/preserved"
        );
    }
    #[test]
    fn confirmed_pull_skips_tracking_after_branch_head_or_optional_io_changes() {
        let f = Fixture::new();
        f.advance();
        assert!(
            pull_policy(
                &f.client,
                &f.state().state_hash,
                "origin",
                "main",
                Policy::Fixture
            )
            .unwrap()
        );
        let target = git(&f.client, &["rev-parse", "HEAD"]);
        let cfg = config(&f.client).unwrap();
        fs::write(f.client.join(".git/config.lock"), "external lock").unwrap();
        assert!(!finish_pull(
            &f.client,
            &cfg,
            "refs/heads/main",
            "origin",
            "main",
            &target
        ));
        fs::remove_file(f.client.join(".git/config.lock")).unwrap();
        assert_eq!(git(&f.client, &["rev-parse", "HEAD"]), target);
        assert!(!finish_pull(
            &f._dir.path().join("missing"),
            &cfg,
            "refs/heads/main",
            "origin",
            "main",
            &target
        ));
        git(&f.client, &["branch", "external"]);
        git(&f.client, &["symbolic-ref", "HEAD", "refs/heads/external"]);
        assert!(!finish_pull(
            &f.client,
            &cfg,
            "refs/heads/main",
            "origin",
            "main",
            &target
        ));
        assert_eq!(
            git(&f.client, &["symbolic-ref", "HEAD"]),
            "refs/heads/external"
        );
        git(&f.client, &["symbolic-ref", "HEAD", "refs/heads/main"]);
        let tree = git(&f.client, &["rev-parse", "HEAD^{tree}"]);
        let advanced = git(
            &f.client,
            &[
                "commit-tree",
                &tree,
                "-p",
                &target,
                "-m",
                "external advance after merge",
            ],
        );
        git(&f.client, &["update-ref", "refs/heads/main", &advanced]);
        assert!(!finish_pull(
            &f.client,
            &cfg,
            "refs/heads/main",
            "origin",
            "main",
            &target
        ));
        assert_eq!(git(&f.client, &["rev-parse", "HEAD"]), advanced);
        assert_eq!(config(&f.client).unwrap(), cfg);
    }
    #[test]
    fn acknowledged_push_preserves_external_tracking_edits_and_reports_success() {
        use std::os::unix::fs::PermissionsExt;
        let f = Fixture::new();
        let original_oid = git(&f.client, &["rev-parse", "HEAD"]);
        // A test-only bare-server hook models an external local Git process
        // editing metadata while the original endpoint acknowledges the push.
        let hook = f.bare.join("hooks/post-receive");
        fs::write(&hook, format!("#!/bin/sh\nunset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE\n/usr/bin/git -C '{}' config remote.origin.url https://elsewhere.invalid/changed.git\n/usr/bin/git -C '{}' config branch.main.remote preserved\n/usr/bin/git -C '{}' config branch.main.merge refs/heads/preserved\n", f.client.display(), f.client.display(), f.client.display())).unwrap();
        fs::set_permissions(&hook, fs::Permissions::from_mode(0o755)).unwrap();
        let updated = push_policy(
            &f.client,
            &f.state().state_hash,
            "origin",
            "acknowledged",
            Policy::Fixture,
        )
        .unwrap();
        assert!(!updated);
        assert_eq!(
            git(&f.bare, &["rev-parse", "refs/heads/acknowledged"]),
            original_oid
        );
        assert_eq!(
            git(&f.client, &["config", "remote.origin.url"]),
            "https://elsewhere.invalid/changed.git"
        );
        assert_eq!(
            git(&f.client, &["config", "branch.main.remote"]),
            "preserved"
        );
        assert_eq!(
            git(&f.client, &["config", "branch.main.merge"]),
            "refs/heads/preserved"
        );
    }
    #[test]
    fn acknowledged_push_keeps_success_when_optional_tracking_cannot_be_written() {
        use std::os::unix::fs::PermissionsExt;
        let f = Fixture::new();
        let hook = f.bare.join("hooks/post-receive");
        fs::write(
            &hook,
            format!(
                "#!/bin/sh\nprintf 'external lock' > '{}/.git/config.lock'\n",
                f.client.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&hook, fs::Permissions::from_mode(0o755)).unwrap();
        let updated = push_policy(
            &f.client,
            &f.state().state_hash,
            "origin",
            "confirmed",
            Policy::Fixture,
        )
        .unwrap();
        assert!(!updated);
        assert_eq!(
            git(&f.bare, &["rev-parse", "refs/heads/confirmed"]),
            git(&f.client, &["rev-parse", "HEAD"])
        );
        fs::remove_file(f.client.join(".git/config.lock")).unwrap();
        let snapshot = super::super::snapshot(&f.client).unwrap();
        let cfg = config(&f.client).unwrap();
        assert!(!finish_push(
            &f._dir.path().join("missing"),
            &snapshot,
            &cfg,
            "refs/heads/main",
            "origin",
            "confirmed"
        ));
        let tree = git(&f.client, &["rev-parse", "HEAD^{tree}"]);
        let advanced = git(
            &f.client,
            &[
                "commit-tree",
                &tree,
                "-p",
                &snapshot.head,
                "-m",
                "external local advance",
            ],
        );
        git(&f.client, &["update-ref", "refs/heads/main", &advanced]);
        assert!(!finish_push(
            &f.client,
            &snapshot,
            &cfg,
            "refs/heads/main",
            "origin",
            "confirmed"
        ));
        assert_eq!(
            git(&f.client, &["config", "branch.main.merge"]),
            "refs/heads/main"
        );
    }
    #[test]
    fn push_is_one_exact_branch_and_non_fast_forward_is_explicit_rejection() {
        let f = Fixture::new();
        git(&f.client, &["config", "remote.origin.mirror", "true"]);
        git(&f.client, &["config", "push.default", "matching"]);
        git(&f.client, &["branch", "unselected"]);
        push_policy(
            &f.client,
            &f.state().state_hash,
            "origin",
            "reviewed",
            Policy::Fixture,
        )
        .unwrap();
        assert_eq!(
            git(&f.bare, &["rev-parse", "refs/heads/reviewed"]),
            git(&f.client, &["rev-parse", "HEAD"])
        );
        assert!(!super::super::ref_exists(&f.bare, "refs/heads/unselected").unwrap());
        assert_eq!(f.state().upstream_branch.as_deref(), Some("reviewed"));
        f.advance();
        let error = push_policy(
            &f.client,
            &f.state().state_hash,
            "origin",
            "main",
            Policy::Fixture,
        )
        .unwrap_err();
        assert_eq!(error.to_string(), "remote_push_rejected");
    }
    #[test]
    fn clone_publishes_new_directory_and_preserves_existing_and_empty_repos() {
        let f = Fixture::new();
        assert_eq!(
            clone_policy(&f.url, &f.client, Policy::Fixture)
                .unwrap_err()
                .to_string(),
            "clone_destination_exists"
        );
        let empty = f._dir.path().join("empty.git");
        git(
            f._dir.path(),
            &["init", "--bare", "-b", "main", empty.to_str().unwrap()],
        );
        let empty_url = format!("file://{}", empty.display());
        let dest = f._dir.path().join("empty-client");
        clone_policy(&empty_url, &dest, Policy::Fixture).unwrap();
        let state = state_policy(&dest, Policy::Fixture).unwrap();
        assert!(state.head.is_none());
        assert!(state.clean);
        let stage = f._dir.path().join("publication-stage");
        let existing = f._dir.path().join("existing-destination");
        fs::create_dir(&stage).unwrap();
        fs::write(stage.join("mine"), "mine").unwrap();
        fs::create_dir(&existing).unwrap();
        assert!(publish(&stage, &existing).is_err());
        assert!(stage.join("mine").exists());
        assert!(fs::read_dir(&existing).unwrap().next().is_none());
        let missing = format!("file://{}/missing.git", f._dir.path().display());
        let failed = f._dir.path().join("failed-clone");
        assert!(clone_policy(&missing, &failed, Policy::Fixture).is_err());
        assert!(!failed.exists());
        assert!(!fs::read_dir(f._dir.path()).unwrap().any(|entry| {
            entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with(".river-clone-")
        }));
    }
    #[test]
    fn remote_configuration_retains_case_and_rejects_unreviewed_changes() {
        let f = Fixture::new();
        let initial = state(&f.client).unwrap();
        configure(
            &f.client,
            &initial.state_hash,
            "add",
            "Company",
            Some("https://gitlab.com/Group/Project.git"),
            Some("git@example.test:Group/Project.git"),
        )
        .unwrap();
        let current = state(&f.client).unwrap();
        assert!(
            current
                .remotes
                .iter()
                .any(|r| r.name == "Company" && r.supported)
        );
        assert_eq!(
            configure(
                &f.client,
                &current.state_hash,
                "add",
                "Company",
                Some("https://host/repo"),
                None
            )
            .unwrap_err()
            .to_string(),
            "remote_name_conflict"
        );
        git(&f.client, &["switch", "-c", "Feature/ABC"]);
        git(
            &f.client,
            &["config", "branch.Feature/ABC.remote", "Company"],
        );
        git(
            &f.client,
            &[
                "config",
                "branch.Feature/ABC.merge",
                "refs/heads/Feature/ABC",
            ],
        );
        let current = state(&f.client).unwrap();
        assert_eq!(current.upstream_remote.as_deref(), Some("Company"));
        assert_eq!(current.upstream_branch.as_deref(), Some("Feature/ABC"));
        configure(
            &f.client,
            &current.state_hash,
            "update",
            "Company",
            Some("https://gitlab.com/Group/New.git"),
            None,
        )
        .unwrap();
        let current = state(&f.client).unwrap();
        let company = current
            .remotes
            .iter()
            .find(|r| r.name == "Company")
            .unwrap();
        assert_eq!(company.fetch_url, company.push_url);
        configure(
            &f.client,
            &current.state_hash,
            "remove",
            "Company",
            None,
            None,
        )
        .unwrap();
        assert!(
            !state(&f.client)
                .unwrap()
                .remotes
                .iter()
                .any(|r| r.name == "Company")
        );
    }
    #[test]
    fn fetch_only_remote_is_preserved_on_add_and_can_be_explicitly_repaired() {
        let f = Fixture::new();
        let mapping = "+refs/heads/reviewed/*:refs/remotes/partial/*";
        git(&f.client, &["config", "remote.partial.fetch", mapping]);
        let original = fs::read(f.client.join(".git/config")).unwrap();
        let ordinary_git = Command::new("/usr/bin/git")
            .current_dir(&f.client)
            .args(["remote", "add", "partial", "https://host/repo.git"])
            .output()
            .unwrap();
        assert!(!ordinary_git.status.success());
        assert_eq!(fs::read(f.client.join(".git/config")).unwrap(), original);
        let current = state(&f.client).unwrap();
        assert_eq!(
            configure(
                &f.client,
                &current.state_hash,
                "add",
                "partial",
                Some("https://host/repo.git"),
                None
            )
            .unwrap_err()
            .to_string(),
            "remote_name_conflict"
        );
        assert_eq!(fs::read(f.client.join(".git/config")).unwrap(), original);
        let partial = current
            .remotes
            .iter()
            .find(|remote| remote.name == "partial")
            .unwrap();
        assert!(!partial.supported);
        configure(
            &f.client,
            &current.state_hash,
            "update",
            "partial",
            Some("https://host/repaired.git"),
            None,
        )
        .unwrap();
        assert_eq!(git(&f.client, &["config", "remote.partial.fetch"]), mapping);
        assert!(
            state(&f.client)
                .unwrap()
                .remotes
                .iter()
                .any(|remote| remote.name == "partial" && remote.supported)
        );
        git(&f.client, &["config", "--unset", "remote.partial.url"]);
        configure(
            &f.client,
            &state(&f.client).unwrap().state_hash,
            "remove",
            "partial",
            None,
            None,
        )
        .unwrap();
        assert!(
            !state(&f.client)
                .unwrap()
                .remotes
                .iter()
                .any(|remote| remote.name == "partial")
        );
        let imported = f.client.join(".git/imported.conf");
        fs::write(
            &imported,
            "[remote \"imported\"]\n\tfetch = +refs/heads/*:refs/remotes/imported/*\n",
        )
        .unwrap();
        git(
            &f.client,
            &["config", "include.path", imported.to_str().unwrap()],
        );
        let original = fs::read(f.client.join(".git/config")).unwrap();
        let current = state(&f.client).unwrap();
        assert!(
            current
                .remotes
                .iter()
                .any(|remote| remote.name == "imported" && !remote.supported)
        );
        for action in ["update", "remove"] {
            let url = (action == "update").then_some("https://host/repaired.git");
            assert_eq!(
                configure(
                    &f.client,
                    &current.state_hash,
                    action,
                    "imported",
                    url,
                    None
                )
                .unwrap_err()
                .to_string(),
                "remote_not_local"
            );
        }
        assert_eq!(fs::read(f.client.join(".git/config")).unwrap(), original);
        // A direct local property does not make an inherited endpoint (or an
        // inherited fetch policy beside a local endpoint) locally owned.
        for imported_url in [true, false] {
            let imported_property = if imported_url {
                "url = https://host/imported.git"
            } else {
                "fetch = +refs/heads/*:refs/remotes/mixed/*"
            };
            fs::write(
                &imported,
                format!("[remote \"mixed\"]\n\t{imported_property}\n"),
            )
            .unwrap();
            let local_key = if imported_url {
                "remote.mixed.fetch"
            } else {
                "remote.mixed.url"
            };
            let local_value = if imported_url {
                "+refs/heads/*:refs/remotes/mixed/*"
            } else {
                "https://host/local.git"
            };
            git(&f.client, &["config", "--local", local_key, local_value]);
            let original = fs::read(f.client.join(".git/config")).unwrap();
            let imported_original = fs::read(&imported).unwrap();
            let current = state(&f.client).unwrap();
            assert!(
                current
                    .remotes
                    .iter()
                    .any(|remote| remote.name == "mixed" && remote.supported)
            );
            for action in ["update", "remove"] {
                assert_eq!(
                    configure(
                        &f.client,
                        &current.state_hash,
                        action,
                        "mixed",
                        (action == "update").then_some("https://host/repaired.git"),
                        None
                    )
                    .unwrap_err()
                    .to_string(),
                    "remote_not_local"
                );
                assert_eq!(fs::read(f.client.join(".git/config")).unwrap(), original);
                assert_eq!(fs::read(&imported).unwrap(), imported_original);
            }
            git(
                &f.client,
                &["config", "--local", "--remove-section", "remote.mixed"],
            );
        }
        // A separate remote with a dotted name does not change ownership of
        // its wholly local prefix-named neighbor.
        fs::write(
            &imported,
            "[remote \"partial.backup\"]\n\turl = https://host/backup.git\n",
        )
        .unwrap();
        git(&f.client, &["config", "remote.partial.fetch", mapping]);
        for action in ["update", "remove"] {
            configure(
                &f.client,
                &state(&f.client).unwrap().state_hash,
                action,
                "partial",
                (action == "update").then_some("https://host/repaired.git"),
                None,
            )
            .unwrap();
        }
        assert_eq!(
            git(&f.client, &["config", "remote.partial.backup.url"]),
            "https://host/backup.git"
        );
    }
}
