#!/bin/zsh

eval $(go env)

command=('go')
targets=()

while [[ -n "$*" ]]; do
  if [[ ${#command[@]} -gt 1 && ! "${1}" =~ '^-.*' ]]; then
    targets+=("${1}")
  fi
  command+=("${1}")
  shift
done

typeset -A colormap
colormap=(
  -blue   "$( echoti setaf  69 )"
  -green  "$( echoti setaf  34 )"
  -grey   "$( echoti setaf 240 )"
  -red    "$( echoti setaf 160 )"
  -tan    "$( echoti setaf 144 )"
  -yellow "$( echoti setaf 148 )"
  _OFF_   "$( echoti sgr0)"
)

colorize() {
  local on="${colormap[$1]}"
  local off=''

  if [[ -n "${on}" ]]; then
    shift
    off="${colormap[_OFF_]}"
  fi

  local str="$( builtin echo "${@}${off}" )"

  builtin echo "${on}${str}"
}

echo() {
  local str=$(colorize "${@}")
  local pfx="${colormap[-grey]}[$(current-time)]${colormap[_OFF_]} "

  builtin echo "${pfx}${str}"
}

current-time() {
  local t
  local IFS='|'
  t=( $( date +'%m/%d|%H:%M:%S|%N' ) )
  t[3]=$(( t[3] / 1000000 ))
  printf '%s-%s.%03d' ${t[@]}
}

colorize-output() {
  local IFS=''
  while read line; do
    case "${line}" in
      *\[build\ failed\]*)
        echo ''
        echo -yellow "${line}" ;;
      \=\=\=\ RUN*)
        echo -tan    "${line}" ;;
      *PASS* | ok*)
        echo -green  "${line}" ;;
      *FAIL*)
        echo -red    "${line}" ;;
      *)
        if [[ "${line}" =~ '(.*\.go):([0-9]+):(.*)' ]]; then
          fn="${match[1]}"
          ln="${match[2]}"
          ms="${match[3]}"
          echo $(printf "%s:%s: %s\n" $(colorize -tan "${fn}") $(colorize -red $(printf '%3d' "${ln}")) "${ms}")
        else
          echo "${line}"
        fi
        ;;
    esac
  done

  return 0
}

run-tests() {
  echo "Executing: ${command[@]}"
  "${command[@]}" 2>&1 | ( colorize-output )
  psc=( ${pipestatus[@]} )
  if [[ ${psc[1]} -eq 0 ]]; then
    echo -green -e "\n\n          ----------  Success  -----------------------------------\n"
  else
    echo -red -e "\n\n          **********  FAILURE  ***********************************\n"
  fi
}

get-target-files() {
  local line dir file
  local -a lines files toks

  files=()
  lines=( ${(o)${(f)"$(go build -a -n "${@}" 2>&1 | \
      egrep "^${GOTOOLDIR}/compile" | egrep -v -- "-D _${GOROOT}/src/")"}} )

  for line in "${lines[@]}"; do
    dir=''
    toks=( ${(s: :)line} )

    for t in {1..$#toks}; do
      case "${toks[${t}]}" in
        '-D')
          dir="${toks[${t}+1]}"
          dir="${dir[2,$#dir]}"
          if [[ "${dir[1,$#PWD]}" == "${PWD}" ]]; then
            dir=".${dir[$#PWD+1,$#dir]}"
          fi
        ;;  
        ./*.go)
          file="${toks[${t}]}"
          file="${file[3,$#file]}"
          files+=( "${dir}/${file}" )
        ;;  
      esac
    done
  done

  builtin echo "${files[@]}"
}

wait-for-changes() {
  echo -en "\n"
  echo -blue "${targets[@]}"
  echo -blue -e "Waiting for further changes.... "
  files=( $(get-target-files "${targets[@]}") )
  echo -grey "Watching: ${(D)files[@]}"
  inotifywait -qq -e 'close_write' "${files[@]}"
  echo -blue "Changes detected."
  echo -blue -e "${(l:78::-:):-}\n\n\n"
}

echo -blue "TARGETS: ${targets[@]}"

run-tests

while :
do
  wait-for-changes
  run-tests
done
