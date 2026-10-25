use anyhow::{Context, Result, bail};
use std::{
    fs,
    io::{self, Read},
    path::Path,
};
use workbench_service::{Request, Service, fixtures, ipc, load_workspace, registration};

fn main() {
    if let Err(error) = run() {
        eprintln!(
            "{}",
            serde_json::json!({"schema_version":1,"error":{"code":workbench_domain::fail_code(&error),"message":error.to_string()}})
        );
        std::process::exit(1);
    }
}
fn run() -> Result<()> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("clone") if args.len() == 3 => {
            let path = workbench_git::remotes::clone_repository(&args[1], Path::new(&args[2]))?;
            println!("{}", serde_json::json!({"path":path}));
        }
        Some("inspect") if args.len() == 2 => {
            println!(
                "{}",
                serde_json::to_string(&registration::inspect(Path::new(&args[1]))?)?
            );
        }
        Some("workspace") if args.len() == 3 => {
            let workspace = registration::create(Path::new(&args[1]), Path::new(&args[2]))?;
            println!(
                "{}",
                serde_json::json!({"workspace":workspace,"config":args[2]})
            );
        }
        Some("fixture") if args.len() == 2 => {
            let workspace = fixtures::create(Path::new(&args[1]))?;
            println!(
                "{}",
                serde_json::json!({"workspace":workspace,"config":Path::new(&args[1]).join("workspace.json"),"next":"Explicitly trust each generated recipe, then serve."})
            );
        }
        Some("trust") if args.len() == 3 => {
            let pin = fixtures::trust(Path::new(&args[1]), &args[2])?;
            println!(
                "{}",
                serde_json::json!({"recipe_id":args[2],"trusted_hash":pin})
            );
        }
        Some("serve") if args.len() == 4 => {
            let workspace = load_workspace(Path::new(&args[1]))?;
            let service = Service::open(workspace, Path::new(&args[2]))?;
            eprintln!("operation service: {}", args[3]);
            ipc::serve(service, Path::new(&args[3]))?;
        }
        Some("rpc") if args.len() == 2 || args.len() == 3 => {
            let mut text = String::new();
            if let Some(file) = args.get(2) {
                text = fs::read_to_string(file)?;
            } else {
                io::stdin().read_to_string(&mut text)?;
            }
            let request: Request = serde_json::from_str(&text).context("invalid_request_json")?;
            let response = ipc::call(Path::new(&args[1]), &request)?;
            println!("{}", serde_json::to_string(&response)?);
            if response.error.is_some() {
                std::process::exit(2);
            }
        }
        Some("schemas") if args.len() == 2 => {
            fs::create_dir_all(&args[1])?;
            macro_rules! schema {
                ($name:literal,$ty:ty) => {
                    fs::write(
                        Path::new(&args[1]).join(concat!($name, ".json")),
                        serde_json::to_vec_pretty(&schemars::schema_for!($ty))?,
                    )?;
                };
            }
            schema!("workspace", workbench_domain::Workspace);
            schema!("task-request", workbench_domain::TaskRequest);
            schema!(
                "task",
                workbench_domain::Task<workbench_domain::SnapshotSummary>
            );
            schema!(
                "plan",
                workbench_domain::Plan<workbench_domain::SnapshotSummary>
            );
            schema!(
                "operation",
                workbench_domain::Operation<workbench_domain::SnapshotSummary>
            );
            schema!("ios-version-inputs", workbench_domain::IosInputs);
            schema!("task-context", workbench_domain::TaskContextBundle);
            schema!("task-workflow", workbench_domain::TaskWorkflowBundle);
            schema!(
                "verification-guide",
                workbench_domain::VerificationGuideContents
            );
            schema!("remote-state", workbench_domain::RemoteState);
            schema!(
                "remote-mutation-result",
                workbench_domain::RemoteMutationResult
            );
        }
        Some("help") | Some("--help") | None => println!(
            "workbench inspect REPOSITORY\nworkbench clone URL NEW_DIRECTORY\nworkbench workspace REPOSITORY NEW_CONFIG\nworkbench fixture NEW_DIRECTORY\nworkbench trust CONFIG RECIPE_ID\nworkbench serve CONFIG JOURNAL SOCKET\nworkbench rpc SOCKET [REQUEST_FILE]  # otherwise stdin\nworkbench schemas DIRECTORY"
        ),
        _ => bail!("invalid_arguments: run workbench --help"),
    }
    Ok(())
}
