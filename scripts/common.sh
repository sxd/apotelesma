#!/usr/bin/env bash

trim()
{
	local value=$1

	value=${value#"${value%%[![:space:]]*}"}
	value=${value%"${value##*[![:space:]]}"}

	printf '%s' "$value"
}

branch_suffix()
{
	local input=${1:-head}
	local output=""
	local i
	local ch

	for ((i = 0; i < ${#input} && ${#output} < 40; i++)); do
		ch=${input:i:1}
		case "$ch" in
			[a-z0-9])
				output+=$ch
				;;
			[A-Z])
				output+=${ch,,}
				;;
			*)
				output+="_"
				;;
		esac
	done

	if [[ -z "$output" ]]; then
		output="head"
	fi

	printf '%s' "$output"
}

append_unique_branch()
{
	local candidate=$1
	local existing

	for existing in "${NORMALIZED_BRANCHES[@]:-}"; do
		if [[ "$existing" == "$candidate" ]]; then
			return
		fi
	done

	NORMALIZED_BRANCHES+=("$candidate")
}

normalize_branches()
{
	local branches_csv=$1
	local root_branch=$2
	local raw_item

	NORMALIZED_BRANCHES=()

	append_unique_branch "$(trim "$root_branch")"

	IFS=',' read -r -a RAW_BRANCHES <<< "$branches_csv"
	for raw_item in "${RAW_BRANCHES[@]}"; do
		raw_item=$(trim "$raw_item")
		if [[ -n "$raw_item" ]]; then
			append_unique_branch "$raw_item"
		fi
	done
}

join_branches_csv()
{
	local branch
	local output=""

	for branch in "${NORMALIZED_BRANCHES[@]}"; do
		if [[ -n "$output" ]]; then
			output+=", "
		fi
		output+=$branch
	done

	printf '%s' "$output"
}

sql_literal()
{
	local value=${1//\'/\'\'}
	printf "'%s'" "$value"
}

json_escape()
{
	local value=${1//\\/\\\\}

	value=${value//\"/\\\"}
	value=${value//$'\n'/\\n}
	value=${value//$'\r'/\\r}
	value=${value//$'\t'/\\t}

	printf '%s' "$value"
}

json_string()
{
	printf '"%s"' "$(json_escape "$1")"
}
