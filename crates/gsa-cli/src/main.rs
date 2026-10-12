//! The `gsa` binary entry point: argv in, exit code out.

fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let stdout = std::io::stdout();
    let stderr = std::io::stderr();
    let code = gsa_cli::run(&argv, &mut stdout.lock(), &mut stderr.lock());
    std::process::exit(code);
}
