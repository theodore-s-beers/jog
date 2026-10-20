# Source this file from ~/.bashrc.
_jog_complete() {
	COMPREPLY=()
	[[ $COMP_CWORD -eq 1 ]] || return 0
	local name
	while IFS= read -r name; do
		[[ $name == "${COMP_WORDS[COMP_CWORD]}"* ]] && COMPREPLY+=("$name")
	done < <(command jog 2>/dev/null)
	return 0
}
complete -F _jog_complete jog
