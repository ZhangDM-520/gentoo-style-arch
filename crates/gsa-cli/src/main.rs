//! The `gsa` binary entry point: argv in, exit code out.

fn main() {
    // argv is BYTES on Unix, and a path may be any bytes. `std::env::args()`
    // panics on a non-UTF-8 element (rc 101, a Rust backtrace) before a
    // single verb is classified (blind-review 2026-11-11, locale-terminal),
    // so the binary reads OS strings and routes a decode failure through the
    // ordinary usage class.
    let stdout = std::io::stdout();
    let stderr = std::io::stderr();
    let mut err = stderr.lock();
    let code = match gsa_cli::utf8_argv(std::env::args_os().skip(1)) {
        Ok(argv) => gsa_cli::run(&argv, &mut stdout.lock(), &mut err),
        Err(message) => gsa_cli::usage_exit(&message, &mut err),
    };
    std::process::exit(code);
}
