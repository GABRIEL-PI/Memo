#!/bin/sh
input=$(cat)

cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
model=$(echo "$input" | jq -r '.model.display_name // empty')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

# 📂 Current dir basename
dir=$(basename "$cwd")

# ⭐ Git branch (skip optional locks)
branch=""
if git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
  branch=$(git -C "$cwd" -c core.fsmonitor=false symbolic-ref --short HEAD 2>/dev/null || git -C "$cwd" -c core.fsmonitor=false rev-parse --short HEAD 2>/dev/null)
fi

# Build output
output=""

# 📂 dir (cyan)
output="$(printf '📂 \033[36m%s\033[0m' "$dir")"

# ⭐ Git branch
if [ -n "$branch" ]; then
  output="$output  $(printf '⭐ \033[34m(\033[31m%s\033[34m)\033[0m' "$branch")"
fi

# 🤖 Model (dimmed)
if [ -n "$model" ]; then
  output="$output  $(printf '🤖 \033[2m%s\033[0m' "$model")"
fi

# 📊 Context usage + bar
if [ -n "$used" ]; then
  used_int=$(printf '%.0f' "$used")

  # Build a 10-char bar
  filled=$(( used_int / 10 ))
  empty=$(( 10 - filled ))
  bar=""
  i=0
  while [ $i -lt $filled ]; do bar="${bar}█"; i=$(( i + 1 )); done
  i=0
  while [ $i -lt $empty ];  do bar="${bar}░"; i=$(( i + 1 )); done

  # Pick bar color: green < 60, yellow < 85, red >= 85
  if [ "$used_int" -ge 85 ]; then
    bar_color='\033[31m'
  elif [ "$used_int" -ge 60 ]; then
    bar_color='\033[33m'
  else
    bar_color='\033[32m'
  fi

  output="$output  $(printf '📊 \033[33m%s%%\033[0m' "$used_int") $(printf "${bar_color}%s\033[0m" "$bar")"
fi

printf '%s' "$output"
