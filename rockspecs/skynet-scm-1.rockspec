package = "skynet"
version = "scm-1"

source = {
    url = "git://github.com/darkstalker/skynet.git",
}

description = {
    summary = "Command line utility for the Brain bot engine",
    detailed = [[
        Command line utility for the Brain bot engine.
    ]],
    homepage = "https://github.com/darkstalker/skynet",
    license = "MIT/X11",
}

dependencies = {
    "lua >= 5.1",
    "argparse >= 0.3.2",
    "brain >= 0.1",
    "lpeg >= 0.12.2",
    "luatwit >= 0.3.1",
    "penlight >= 1.3.2",
}

build = {
    type = "none",
    install = {
        bin = { skynet = "skynet.lua" },
    },
}
