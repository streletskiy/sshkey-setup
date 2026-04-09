#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SSHD_CONFIG_PATH="${SSHD_CONFIG_PATH:-/etc/ssh/sshd_config}"
SSHD_BIN="${SSHD_BIN:-$(command -v sshd 2>/dev/null || true)}"
if [[ -z "$SSHD_BIN" && -x /usr/sbin/sshd ]]; then
  SSHD_BIN="/usr/sbin/sshd"
fi
readonly SSHD_BIN
readonly SSH_SERVICE_PRIMARY="${SSH_SERVICE_PRIMARY:-ssh}"
readonly SSH_SERVICE_FALLBACK="${SSH_SERVICE_FALLBACK:-sshd}"
readonly BLOCK_BEGIN="# BEGIN tnnl-key managed block"
readonly BLOCK_END="# END tnnl-key managed block"

TMP_FILES=()

die() {
  printf 'Ошибка: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '%s\n' "$*" >&4
}

warn() {
  printf 'Предупреждение: %s\n' "$*" >&4
}

track_temp() {
  TMP_FILES+=("$1")
}

cleanup() {
  local file
  for file in "${TMP_FILES[@]:-}"; do
    [[ -n "$file" ]] && rm -f -- "$file"
  done
}

on_error() {
  local line="$1"
  local cmd="$2"
  printf 'Ошибка на строке %s: %s\n' "$line" "$cmd" >&2
  exit 1
}

trap cleanup EXIT
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запусти скрипт через sudo или от root."
}

require_tty() {
  [[ -r /dev/tty && -w /dev/tty ]] || die "Нужен интерактивный терминал (/dev/tty)."
  exec 3</dev/tty 4>/dev/tty
}

require_commands() {
  command -v ssh-keygen >/dev/null 2>&1 || die "Не найден ssh-keygen. Установи OpenSSH client."
  [[ -n "$SSHD_BIN" && -x "$SSHD_BIN" ]] || die "Не найден sshd. Установи OpenSSH server."
}

trim_value() {
  local value="$1"

  value="${value//$'\r'/}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"

  printf '%s' "$value"
}

prompt_line() {
  local __var_name="$1"
  local prompt_text="$2"
  local input_value

  printf '%s' "$prompt_text" >&4
  if ! IFS= read -r -u 3 input_value; then
    printf '\n' >&4
    die "Ввод прерван."
  fi
  printf '\n' >&4

  printf -v "$__var_name" '%s' "$input_value"
}

prompt_non_empty() {
  local __var_name="$1"
  local prompt_text="$2"
  local response

  while true; do
    prompt_line response "$prompt_text"
    response="$(trim_value "$response")"
    if [[ -n "$response" ]]; then
      printf -v "$__var_name" '%s' "$response"
      return 0
    fi
    warn "Значение не должно быть пустым."
  done
}

get_user_home() {
  local user="$1"
  getent passwd "$user" | awk -F: 'NR == 1 { print $6 }'
}

get_user_group() {
  local user="$1"
  id -gn "$user"
}

key_fingerprint() {
  local key="$1"
  local temp

  temp="$(mktemp)"
  track_temp "$temp"
  printf '%s\n' "$key" >"$temp"

  ssh-keygen -E sha256 -lf "$temp" 2>/dev/null | awk 'NR == 1 { print $2 }'
}

authorized_keys_has_key() {
  local authorized_keys="$1"
  local key="$2"
  local wanted_fp=""
  local existing_fp_list=""

  if [[ -f "$authorized_keys" ]]; then
    if grep -Fqx -- "$key" "$authorized_keys"; then
      return 0
    fi
    wanted_fp="$(key_fingerprint "$key")"
    existing_fp_list="$(ssh-keygen -E sha256 -lf "$authorized_keys" 2>/dev/null | awk '{ print $2 }' || true)"
    if [[ -n "$wanted_fp" ]] && grep -Fqx -- "$wanted_fp" <<<"$existing_fp_list"; then
      return 0
    fi
  fi

  return 1
}

reload_ssh_service() {
  local service

  if command -v systemctl >/dev/null 2>&1; then
    for service in "$SSH_SERVICE_PRIMARY" "$SSH_SERVICE_FALLBACK"; do
      if systemctl reload "$service" >/dev/null 2>&1; then
        return 0
      fi
    done
  fi

  if command -v service >/dev/null 2>&1; then
    for service in "$SSH_SERVICE_PRIMARY" "$SSH_SERVICE_FALLBACK"; do
      if service "$service" reload >/dev/null 2>&1; then
        return 0
      fi
    done
  fi

  return 1
}

update_sshd_config_block() {
  local block_content="$1"
  local sshd_config="$SSHD_CONFIG_PATH"
  local backup_path
  local temp_path

  [[ -f "$sshd_config" ]] || die "Не найден конфиг sshd: $sshd_config"
  [[ -L "$sshd_config" ]] && die "Символическая ссылка не допускается: $sshd_config"

  backup_path="${sshd_config}.bak.$(date +%Y%m%d%H%M%S).$$"
  cp -a -- "$sshd_config" "$backup_path"

  temp_path="$(mktemp "${sshd_config}.XXXXXX")"
  track_temp "$temp_path"

  awk -v begin="$BLOCK_BEGIN" -v end="$BLOCK_END" '
    function emit_block(    prefix) {
      if (inserted) {
        return
      }
      if (printed_any) {
        print ""
      }
      print begin
      print block
      print end
      inserted = 1
      printed_any = 1
    }

    $0 == begin { in_block = 1; next }
    $0 == end { in_block = 0; next }
    in_block { next }

    {
      if (!inserted && $0 ~ /^[[:space:]]*[Mm][Aa][Tt][Cc][Hh]([[:space:]]|$)/) {
        emit_block()
      }
      print
      printed_any = 1
    }

    END {
      if (!inserted) {
        if (printed_any) {
          print ""
        }
        print begin
        print block
        print end
      }
    }
  ' block="$block_content" "$sshd_config" >"$temp_path"

  chmod --reference="$sshd_config" "$temp_path"

  if ! "$SSHD_BIN" -t -f "$temp_path" >/dev/null 2>&1; then
    die "Проверка временного конфига sshd не прошла. Оригинал не изменён."
  fi

  mv -f -- "$temp_path" "$sshd_config"

  if ! "$SSHD_BIN" -t -f "$sshd_config" >/dev/null 2>&1; then
    cp -a -- "$backup_path" "$sshd_config"
    die "Проверка sshd_config не прошла. Восстановлена резервная копия: $backup_path"
  fi

  if ! reload_ssh_service; then
    warn "Конфиг обновлён, но ssh не удалось перезагрузить автоматически. Выполни вручную: systemctl reload ssh"
  else
    info "Служба ssh перезагружена."
  fi

  info "Резервная копия: $backup_path"
}

ensure_user_key() {
  local user="$1"
  local key="$2"
  local home_dir
  local group_name
  local ssh_dir
  local authorized_keys
  local fingerprint

  home_dir="$(get_user_home "$user")"
  [[ -n "$home_dir" ]] || die "Не удалось определить домашний каталог пользователя $user."
  [[ -d "$home_dir" ]] || die "Домашний каталог не найден: $home_dir"

  group_name="$(get_user_group "$user")"
  ssh_dir="$home_dir/.ssh"
  authorized_keys="$ssh_dir/authorized_keys"

  if [[ -e "$ssh_dir" && ! -d "$ssh_dir" ]]; then
    die "Путь существует, но это не каталог: $ssh_dir"
  fi
  if [[ -L "$ssh_dir" ]]; then
    die "Символическая ссылка не допускается: $ssh_dir"
  fi
  if [[ -e "$authorized_keys" && ! -f "$authorized_keys" ]]; then
    die "Путь существует, но это не файл: $authorized_keys"
  fi
  if [[ -L "$authorized_keys" ]]; then
    die "Символическая ссылка не допускается: $authorized_keys"
  fi

  install -d -m 700 -o "$user" -g "$group_name" "$ssh_dir"
  touch "$authorized_keys"
  chown "$user:$group_name" "$authorized_keys"
  chmod 600 "$authorized_keys"

  if authorized_keys_has_key "$authorized_keys" "$key"; then
    info "Ключ уже есть в $authorized_keys"
  else
    printf '%s\n' "$key" >>"$authorized_keys"
    info "Ключ добавлен в $authorized_keys"
  fi

  chown "$user:$group_name" "$authorized_keys"
  chmod 600 "$authorized_keys"

  fingerprint="$(key_fingerprint "$key")"
  [[ -n "$fingerprint" ]] || die "Не удалось вычислить fingerprint ключа."
  info "Fingerprint: $fingerprint"
}

add_key_flow() {
  local default_user
  local user
  local key

  default_user="${SSH_USER:-${SUDO_USER:-root}}"
  prompt_line user "Пользователь для authorized_keys [$default_user]: "
  user="$(trim_value "${user:-$default_user}")"
  [[ -n "$user" ]] || die "Имя пользователя не задано."
  id -u "$user" >/dev/null 2>&1 || die "Пользователь не найден: $user"

  prompt_non_empty key "Вставь публичный SSH-ключ одной строкой и нажми Enter: "
  key="$(trim_value "$key")"
  [[ -n "$key" ]] || die "Пустой ключ."

  if [[ "$key" == *$'\n'* ]]; then
    die "Ключ должен быть одной строкой."
  fi

  ensure_user_key "$user" "$key"

  update_sshd_config_block $'PubkeyAuthentication yes'

  info "SSH-ключ для пользователя $user добавлен."
  info "Теперь проверь вход по ключу в новой сессии, прежде чем отключать пароль."
}

disable_password_flow() {
  local confirmation

  warn "Это отключит вход по паролю для SSH глобально."
  warn "Перед продолжением убедись, что ключевой вход уже работает и текущая сессия не потеряется."
  prompt_line confirmation "Введите DISABLE для подтверждения: "
  confirmation="$(trim_value "$confirmation")"
  [[ "$confirmation" == "DISABLE" ]] || die "Операция отменена."

  update_sshd_config_block $'PubkeyAuthentication yes\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nChallengeResponseAuthentication no'

  info "Вход по паролю отключён."
}

show_menu() {
  info "Выбери действие:"
  info "1) Добавить публичный SSH-ключ"
  info "2) Отключить вход по паролю"
}

main() {
  require_root
  require_tty
  require_commands

  if [[ $# -ne 0 ]]; then
    die "Скрипт интерактивный и не принимает аргументы."
  fi

  show_menu

  while true; do
    local choice
    prompt_line choice "Введите 1 или 2: "
    choice="$(trim_value "$choice")"
    case "$choice" in
      1)
        add_key_flow
        break
        ;;
      2)
        disable_password_flow
        break
        ;;
      *)
        warn "Нужно выбрать 1 или 2."
        ;;
    esac
  done
}

main "$@"
