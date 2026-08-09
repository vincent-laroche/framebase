# Headless Development Workflow

Automated work in this checkout must not manipulate the active macOS desktop.

- Build: `./script/build_and_run.sh --build`
- Package tests: `./script/build_and_run.sh --test`
- Full local headless gate: `./script/build_and_run.sh --verify`
- Read recent process logs without launching the app: `./script/build_and_run.sh --logs`
- Read recent Framebase telemetry without launching the app: `./script/build_and_run.sh --telemetry`

The entrypoint never calls `open`, `pkill`, `lldb`, AppleScript, or GUI
automation. Native macOS XCUITests interact with the host desktop and are not
run locally by this workflow. They remain appropriate only for an isolated CI
or dedicated macOS test user/session.
