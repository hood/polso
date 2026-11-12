set shell := ["bash", "-euo", "pipefail", "-c"]

app := env_var('HOME') / "Applications/Polso.app"
agent := env_var('HOME') / "Library/LaunchAgents/local.polso.plist"
config := env_var('HOME') / ".config/polso/config.json"
sock := env_var('HOME') / ".config/polso/sock"
dist := "dist"

# list recipes
default:
    @just --list

# compile the release binary
build:
    swift build -c release --build-system native

# build and install the .app into ~/Applications
install:
    ./build.sh

# build dist/Polso.app and zip it for sharing
bundle:
    rm -rf "{{dist}}" && mkdir -p "{{dist}}"
    APP="$PWD/{{dist}}/Polso.app" ./build.sh
    ditto -c -k --keepParent "{{dist}}/Polso.app" "{{dist}}/Polso.zip"
    @echo "zipped $PWD/{{dist}}/Polso.zip ($(du -h "{{dist}}/Polso.zip" | cut -f1))"

# rebuild, install and relaunch
restart: install stop start

# launch the installed app
start:
    open "{{app}}"

# quit the running app
stop:
    pkill -x Polso || true

# run the binary in the foreground (logs to the terminal)
dev: build stop
    .build/release/Polso

# render idle/burst/expanded/settings PNGs with synthetic data into DIR
snapshot dir="snapshots": build
    mkdir -p "{{dir}}"
    .build/release/Polso --snapshot "$(cd "{{dir}}" && pwd)"

# send raw protocol JSON, e.g. just send '{"type":"ping"}'
send json:
    @echo '{{json}}' | nc -U "{{sock}}"

# push a value to a wing
push slot value:
    @echo '{"type":"value","slot":"{{slot}}","value":{{value}}}' | nc -U "{{sock}}"

# ping a wing (left|right) or the whole notch (no arg)
ping slot="":
    @echo '{"type":"ping"{{ if slot != "" { ",\"slot\":\"" + slot + "\"" } else { "" } }}}' | nc -U "{{sock}}"

# drop an alert banner
alert title="Deploy failed" severity="crit" summary="api-gateway rollout stuck":
    @echo '{"type":"alert","title":"{{title}}","severity":"{{severity}}","summary":"{{summary}}"}' | nc -U "{{sock}}"

# start at login via LaunchAgent
login:
    ./build.sh --login

# remove the login LaunchAgent
unlogin:
    launchctl bootout "gui/$(id -u)/local.polso" 2>/dev/null || true
    rm -f "{{agent}}"

# open the settings window (launches the app if needed)
settings:
    open "{{app}}" --args --settings

# reset the config to defaults (regenerated on next launch)
reset-config: stop
    rm -f "{{config}}"

# remove build artifacts
clean:
    swift package clean
    rm -rf .build snapshots "{{dist}}"
