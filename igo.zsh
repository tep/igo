#!/bin/zsh

zmodload zsh/datetime
zmodload -F zsh/stat b:zstat

fpath+=( "$HOME/.zsh/plugins/COMPILED-${ZSH_VERSION}.zwc" )
autoload -Uz prjdirsinit; prjdirsinit

eval $(go env)

me="$(basename $0)"
testing=''

command=('go')
targets=()
targetRoots=()

# TODO(tep): Work better with Go modules
#            Currently, we gather inotify watch information by running one,
#            big `go list` command across all targets. This doesn't work with
#            multiple targets if one or more of them has a `go.mod` file.
#
#            In that situation each target's dependency info must be collected
#            separately by:
#
#              a) Changing directory into the target's root
#              b) Running `go list` prefaced by `GO111MODULE=on`
#
#            `targetMods` should be populated as a map of `target` to boolean
#            indicating which targets support modules. All non-module targets
#            can be collected together then each module target can be added
#            in kind.
#
typeset -gA targetMods=()


die() {
  if [[ -n "${1}" ]]; then
    echo -e "Error: \"${1}\"\n" 1>&2
  fi

  echo "USAGE: ${me} (build|test) [options] [target...]" 1>&2
  exit 1
}

#####  Command Line Processing  ##############################################

case "${1}" in
  'test')
    testing=1
    command+=("${1}")
    shift
    ;;

  'build')
    command+=("${1}")
    shift
    ;;

  *)
    die "Invalid command: \"${1}\""
    ;;
esac

no_watch=()

# TODO: Add option to exec (and restart) a process when a binary gets rebuilt.
#       This will require careful job control and proper signal handling.
while [[ $# -gt 0 ]]; do
  case "${1}" in
    --no-watch)
      no_watch+=( "${2}" )
      shift
      ;;
    -*)
      [[ "${#targets[@]}" -eq 0 ]] || die "Invalid target: \"${1}\""
      command+=("${1}")
      ;;

    *)
      targets+=("${1}")
      ;;
  esac
  shift
done

if [[ "${#targets[@]}" -ne 0 ]]; then
  command+=( "${targets[@]}" )
fi

if [[ "${#targets[@]}" -eq 0 ]]; then
  targets=( $( go list -f '{{.ImportPath}}' ) )
fi

targetRoots=( $(
  go list -e -json -compiled -export=false ${targets[@]} 2>/dev/null \
    | jq -rs '[.[] | .Root // .Dir ] | unique | .[]'
))

#####  -----------------------  ##############################################

clr_eol="$(echoti el)"

typeset -A colormap
colormap=(
  -green  "$( echoti setaf  34 )"
  -blue   "$( echoti setaf  69 )"
  -pale   "$( echoti setaf 102 )"
  -tan    "$( echoti setaf 144 )"
  -yellow "$( echoti setaf 148 )"
  -red    "$( echoti setaf 160 )"
  -grey   "$( echoti setaf 240 )"
  _OFF_   "$( echoti sgr0)"
)

colorize() {
  local on="${colormap[$1]}"
  local off=''

  if [[ -n "${on}" ]]; then
    shift
    off="${colormap[_OFF_]}"
  fi

  print "${on}${@}${off}"
}

# A wrapper around the builtin echo that allows for colorization and
# prepends a timestamp prefix.
echo() {
  local pfx="${colormap[-grey]}$(current-time)]${colormap[_OFF_]} "
  local color=''

  if [[ -n "${colormap[$1]}" ]]; then
    color="$1"
    shift
  fi

  local -a opts=()
  while [[ "$1" =~ '^-.*' ]]; do
    opts+=( "$1" )
    shift
  done

  local -a args
  if [[ -n "${color}" ]]; then
    args=( "${color}" )
  fi
  args+=( ${@} )

  builtin echo ${opts[@]} "${pfx}$(colorize ${args[@]})"
}

current-time() {
  local -F v=${EPOCHREALTIME}
  local -i ms s=${v}

  ms=$(( 1000 * (v - s) + 0.5 ))
  strftime "I%m%d %H:%M:%S.$(printf '%03d' ${ms})" ${s}
  # local t
  # local IFS='|'
  # t=( $( date +'%m/%d|%H:%M:%S|%N' ) )
  # t[3]=$(( t[3] / 1000000 ))
  # printf '%s-%s.%03d' ${t[@]}
}

colorize-output() {
  local IFS='' top=1
  while read line; do
    if (( top == 1 )); then
      echo -grey -e "${(l:78::-:):-}\n"
      top=0
    fi

    case "${line}" in
      \#\ *)
        echo -blue "${line}" ;;
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

#####  -----------------------  ##############################################

is-mod-pkg() { go list -m > /dev/null 2>&1 }

run-go-command() {
  echo "Executing: ${command[@]}"
  "${command[@]}" 2>&1 | ( colorize-output )
  psc=( ${pipestatus[@]} )
  if [[ ${psc[1]} -eq 0 ]]; then
    echo -green -e "\n\n          ----------  Success  -----------------------------------\n"
  else
    echo -red -e "\n\n          **********  FAILURE  ***********************************\n"
  fi
}

# Prints a JSON object for all target files plus files from all of their
# dependents sharing the same $GOPATH root. The JSON object contains the
# following fields:
#
#   dir:        Full path to the package directory
#   file:       Full path to the source file
#   importPath: The import path for the associated package
#   dep:        A boolean; 0 if this is a target file, 1 if it's a dependent
#
get-watch-json() {
  local jq_tests gl_tests cmd=(go list -e -json -compiled -export=false -deps=true -find=false)

  if [[ -n "${testing}" ]]; then
    jq_tests="+ .TestGoFiles"
    cmd+=( "-test=true" )
  fi

  cmd+=( ${targets[@]} )
  
  local tr="${(j:, :)${(qqq)targetRoots[@]}}"

  local jqFilter="
    select(
      .Root as \$root
      | [${tr}]
      | map(. == \$root)
      | any
    )
    | {Dir, ImportPath, isdep: (if .DepOnly then 1 else 0 end)} as \$info
    | .GoFiles ${jq_tests}
    | .[] | {
      dir:        \$info.Dir,
      file:       \"\(\$info.Dir)/\(.)\",
      importPath: \$info.ImportPath,
      dep:        \$info.isdep
    }
  "

  $cmd | jq -r "${jqFilter}"
}

# Prints the filename of all target files plus all of their dependents that
# share the same $GOPATH root.
get-watch-files() {
  print "${1}" | jq -r '.file' | egrep -v '/.cache/go-build/' | sort | uniq
}

# Prints all non-dependent target filenames
get-target-files() {
  local -a files=( $( print "${1}" | jq -r 'select(.dep == 0) | .file' | egrep -v '/.cache/go-build/' | sort | uniq) )
  print "${(D)files[@]}"
}

# Prints the .ImportPath for all dependent packages that share the same $GOPATH
# root as their associated target. Packages that are descendents of a target
# are listed first.
get-dep-packages() {
  print "${1}" | jq -rs '
    [
      (
        [
          .[]
          | select(.dep == 0)
          | .dir
        ]
        | unique
        | .[]
      ) as $troot

      | (
        $troot
        | length
      ) as $trlen

      | .[]
      |  select(.dep == 1)
      | . + {
        extern: (if "\(.file[:$trlen])/" == "\($troot)/" then 0 else 1 end)
      }
    ]

    | .[]
    |= "\(.extern):\(.importPath)"
    | sort
    | unique
    | .[]
    | .[2:]
  '
}

indent-extra() {
  local i="${1}"
  local spaces="${(l:${i}:: :): }"

  sed -r "2,\$s/^/${spaces}/" | sed -re 's/ *$//'
}

columnize-watchlist() {
  local -a files=( $@ )

  local -a shortnd=( ${(oD)files[@]} )
  local -a combind=( ${(oD)$(realpath --relative-base=${PWD} ${files[@]})} )

  print -c $(comm -23 =(print ${(F)combind[@]}) =(print ${(F)shortnd[@]}))
  print
  print -c $(comm -12 =(print ${(F)combind[@]}) =(print ${(F)shortnd[@]}))
}

exclude-no-watch() {
  comm -23 - =(print ${(F)${(o)no_watch[@]}})
}

wait-for-files() {
  echo -blue -ne "Waiting for further changes.... "
  inotifywait -qq -e 'close_write' "${@}"
  echo -ne "\r${clr_eol}"

  echo -blue -e "Changes detected."
  echo -blue -e "${(l:78::-:):-}\n\n\n"
}

if is-mod-pkg; then
  wait-for-changes() {
    local -i i=30
    local -i w=$(( COLUMNS - i ))

    local -a modules=(
      $(
        go list -e      \
          -json         \
          -compiled     \
          -export=false \
          -deps=true    \
          -find=false   \
          "${targets[@]}" | jq -r '
            .Module
            | select(
              .Main or .Replace != null and (.Replace.Path | startswith("/"))
            )
            | {Path} | .[] ' | sort | uniq | exclude-no-watch)
    )

    echo -e "\n"
    echo -blue "Targets: $(COLUMNS="${w}" print -ac ${targets[@]} | indent-extra ${i} )"
    echo -blue "Modules: $(COLUMNS="${w}" print -ac ${modules[@]} | indent-extra ${i} )"

    echo -blue -n "Calculating watch list... "

    local mods="${(j:, :)${(qqq)modules[@]}}"

    local -a args=( '-e' '-json' '-compiled' '-export=false' '-deps=true' '-find=false' )

    if [[ -n "${testing}" ]]; then
      args+=( '-test=true' )
    fi

    local -a files=(
      $(go list "${args[@]}" | jq -r "
        select(.Module.Path as \$path
          | [${mods}]
          | map(. == \$path)
          | any
        )
        | .Dir as \$dir
        | .GoFiles
        | .[]
        | \"\(\$dir)/\(.)\"")
    )

    echo -ne "\r${clr_eol}"

    echo -pale "Watching: $(COLUMNS="${w}" columnize-watchlist ${files[@]} | indent-extra ${i} )"
    print

    wait-for-files "${files[@]}"
  }
else
  wait-for-changes() {
    local -i i=30
    local -i w=$(( COLUMNS - i ))

    echo -e "\n"
    echo -blue "Targets:  $(COLUMNS="${w}" print -ac ${targets[@]} | indent-extra ${i} )"

    echo -blue -n "Calculating watch list... "

    local watchJS="$(get-watch-json)"
    # local -a files=( print "${watchJS}" | jq -r '.file' | egrep -v '/.cache/go-build/' | sort | uniq )
    local -a files=(    $(get-watch-files "${watchJS}")  )
    local -a tgtFiles=( $(get-target-files "${watchJS}") )
    local -a depPkgs=(  $(get-dep-packages "${watchJS}") )

    echo -ne "\r${clr_eol}"

    echo -pale "Watching: $(COLUMNS="${w}" print -ac ${tgtFiles[@]} | indent-extra ${i} )"
    if [[ ${#depPkgs} -gt 0 ]]; then
      echo -pale -e "   +Pkgs: $(COLUMNS="${w}" print -ac ${depPkgs[@]} | indent-extra ${i} )\n"
    fi

    wait-for-files "${files[@]}"
  }
fi

#####  -----------------------  ##############################################

() {
  local -i i=30
  local -i w=$(( COLUMNS - i ))

  echo -blue "TARGETS: $(COLUMNS="${w}" print -ac ${(qq)targets[@]} | indent-extra ${i} )"
  if [[ ${#targetRoots} -gt 1 ]]; then
    echo -blue "  Roots: ${(qq)targetRoots[@]}"
  fi

  while :
  do
    run-go-command
    wait-for-changes
  done
}
