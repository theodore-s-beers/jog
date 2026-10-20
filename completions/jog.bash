# Source this file from ~/.bashrc.
_jog_complete() {
	COMPREPLY=()
	[[ $COMP_CWORD -ge 1 ]] || return 0
	local name word=${COMP_WORDS[1]} prefix='' i
	# Bash treats ':' as a word break, even inside a single script name.
	for ((i = 2; i <= COMP_CWORD; i++)); do
		[[ ${COMP_WORDS[i]} == : || ${COMP_WORDS[i - 1]} == : ]] || return 0
		word+=${COMP_WORDS[i]}
	done
	if [[ $COMP_WORDBREAKS == *:* && $word == *:* ]]; then
		prefix=${word%:*}:
	fi
	while IFS= read -r name; do
		[[ $name == "$word"* ]] && COMPREPLY+=("${name#"$prefix"}")
	done < <(command jog --list-names 2>/dev/null)
	return 0
}
complete -F _jog_complete jog
