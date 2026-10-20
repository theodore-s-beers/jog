# Put this file in ~/.config/fish/completions/jog.fish.
complete -c jog -f
complete -c jog -n __fish_use_subcommand -a '(command jog --list-names 2>/dev/null)'
